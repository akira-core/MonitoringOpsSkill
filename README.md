# MonitoringOpsSkill

在 [kind](https://kind.sigs.k8s.io/) 上建立的本機 Kubernetes 監控實驗環境：

- **Metrics**：用 `victoria-metrics-k8s-stack` 部署 VictoriaMetrics **cluster 版**（vminsert / vmselect / vmstorage）。
  stack 內建的 vmagent 負責 scrape kube-state-metrics、node-exporter、kubelet/cAdvisor 與 control plane。
- **Logs**：fluent-bit（DaemonSet）→ OTLP/HTTP → **Vector aggregator**（StatefulSet，disk buffer 存在 PVC，用 `kubectl scale` 調整 replicas）→ [rotel](https://github.com/streamfold/rotel) → **ClickHouse**（`otel.otel_logs`）。
- **Grafana** 有兩個 datasource：
  - `VictoriaMetrics`：Prometheus 類型，指向 vmselect。
  - `ClickHouse`：使用 `grafana-clickhouse-datasource` plugin。
- **vmagent scale-down lab**：sharded、stateful `VMAgent`（用 `kubectl scale` 調整 shardCount），每個 shard 2 個 replica 以做到無停機的 rolling upgrade。用來研究「vmagent 縮容時如何讓 persistent queue PVC 是空的」。
  結論見 [docs/vmagent-graceful-scaledown.md](docs/vmagent-graceful-scaledown.md)。
- **Vector scale-down lab**：Vector aggregator 用 `kubectl scale` 調整 replicas，研究 rolling upgrade 與縮容時 disk buffer 的 drain。
  結論見 [docs/vector-graceful-scaledown.md](docs/vector-graceful-scaledown.md)。

```
                         ┌──────────────── kind cluster "monops"（1 control-plane + 2 workers）────────────────┐
 kube-state-metrics ─┐   │                                                                                      │
 node-exporter ──────┼─► vmagent (vmks) ──► vminsert ──► vmstorage ◄── vmselect ◄──┬── Grafana                   │
 kubelet / CP ───────┘   │                     ▲                                    │     ├ DS: VictoriaMetrics   │
                         │                     │                                    │     └ DS: ClickHouse ──┐    │
 avalanche (load) ─────► VMAgent/lab（2 shards × 2 replicas，每個 pod 一個 PVC queue）                 │    │
                         │                                                                                  │    │
 pod logs ─► fluent-bit (DS) ─OTLP/HTTP─► Vector（2 pods，PVC disk buffer）─► rotel ─► ClickHouse ◄──┘    │
 loggen (load) ─┘        │                                                                                       │
                         └──────────────────────────────────────────────────────────────────────────────────────┘
```

## 需求

需要 `kind`、`kubectl`、`helm`（測試版本為 v4.3.1）、`docker`、`jq`、`openssl`。Docker 需預留約 6 GB RAM。

## 快速開始

```bash
make up          # 建立 cluster 並安裝全部元件（idempotent；首次約 5–6 分鐘）
make grafana     # port-forward 到 http://localhost:3000，會印出 admin 密碼
make status      # 列出各 namespace 的 pods
make down        # 刪除 cluster
```

Grafana 資料夾：

- **Lab / Graceful scale-down verification (read-only)**（uid `scaledown-verify`）：
  - 專為「只能用瀏覽器、唯讀」的驗證設計。verdict 都是 table（DOM 讀得到），各自帶 PASS/FAIL：
    - **V1**：vmagent preStop drain 結果（每個 pod instance 一列）
    - **V2**：每個 avalanche target 在儲存端的最大 sample 間隔
    - **V3**：Vector shutdown 是否 graceful
    - **V4**：loggen seq 端到端是否完整
  - 判讀規則寫在 dashboard 最上方的 text panel。
- **Lab / vmagent scale & graceful drain lab**（uid 仍是 `vmagent-autoscale-lab`；現在沒有任何自動擴縮，shard 數由人用 `kubectl scale` 設定）：包含以下 panel：
  - shards（desired 和 running）
  - 每個 shard 的 samples/s
  - 每個 pod 的磁碟 queue 和 total queue
  - remote write 錯誤
  - preStop drain log（ClickHouse panel）
- **Lab / Kubernetes logs (ClickHouse)**：各 namespace 的 log 量、top pods、log 搜尋。
- **ClickHouse/**：Altinity 提供的 dashboards，ClickHouse metrics 會 scrape 進 VictoriaMetrics。
- k8s-stack 預設 dashboards：Kubernetes、node-exporter、VictoriaMetrics cluster/vmagent/operator。
- 另外從上游複製的 dashboards（來源、授權與修改見 [manifests/dashboards/upstream/SOURCES.md](manifests/dashboards/upstream/SOURCES.md)）：
  VictoriaMetrics alert statistics、Kubernetes autoscaling HPA 與 PDB、ClickHouse OTel logs explorer。
  **HPA dashboard 在沒有 HPA 的 cluster 上沒有資料**：本 lab 已移除 KEDA，所以預期為 No data；PDB dashboard 仍有資料。

## 目錄結構

```
kind/cluster.yaml                     kind cluster；control-plane metrics 綁到 0.0.0.0
helm/versions.env                     固定的 chart 版本
helm/values/vm-k8s-stack.yaml         VMCluster、vmagent、Grafana（含 ClickHouse datasource/plugin）
helm/values/clickhouse-operator.yaml  Altinity operator（含 dashboards）
helm/values/fluent-bit.yaml           tail -> k8s metadata -> OTLP/HTTP -> rotel
manifests/clickhouse/                 ClickHouseInstallation、rotel DDL job、metrics scrape
manifests/logging/                    rotel Deployment/Service、fluent-bit scrape
helm/values/vector.yaml               Vector aggregator（OTLP 原樣轉送、disk buffer、graceful shutdown）
manifests/vector-lab/                 loggen 負載、VMPodScrape
manifests/vmagent-lab/                VMAgent/lab、preStop drain script、RBAC、avalanche
manifests/dashboards/                 lab dashboards（Grafana sidecar ConfigMaps）
scripts/up.sh | down.sh | grafana.sh  生命週期
scripts/lab/*.sh                      vmagent 實驗輔助腳本（見下）
scripts/lab/vector/*.sh               Vector 實驗輔助腳本（見下）
docs/vmagent-graceful-scaledown.md    vmagent 實驗結論
docs/vector-graceful-scaledown.md     Vector 實驗結論
```

## 帳密

`scripts/up.sh` 第一次執行時會產生隨機密碼並存成 Secret，之後重跑會沿用。

| Secret | Namespaces | 用途 |
|---|---|---|
| `grafana-admin` | monitoring | Grafana admin 登入 |
| `clickhouse-otel` | clickhouse、logging | ClickHouse **寫入**帳號 `otel`（rotel、DDL job）：只有 `otel.*` 的 CREATE/INSERT/SELECT |
| `clickhouse-grafana` | clickhouse、monitoring | ClickHouse **唯讀**帳號 `grafana`（Grafana datasource）：`readonly=2` profile，只有 `otel.*` 的 SELECT |

兩個 ClickHouse 帳號的 `networks` 都只允許 pod CIDR `10.244.0.0/16` 和 localhost。

## Logs pipeline 細節

1. fluent-bit tail `/var/log/containers/*.log`，並加上 Kubernetes metadata。
2. metadata 被攤平成 OTel 風格的 key（`k8s.namespace.name`、`k8s.pod.name`、`k8s.container.name`、`k8s.node.name` 等）。
3. 以 `logs_body_key $log` 透過 OTLP/HTTP 送到 `vector.logging:4318`：4 個 worker，keep-alive 連線每 20 個 request 重建一次，讓新的 Vector pod 也分得到流量。
4. Vector 原樣轉送 OTLP（`use_otlp_decoding` + `codec: otlp`），先寫進 disk buffer，再送到 `rotel.logging:4318`。
5. rotel 寫入 `otel.otel_logs`。這張表由 `rotel-clickhouse-ddl` 依 rotel 自己的 schema 建立，TTL 72h。

metadata 會放在 `LogAttributes`：

```sql
SELECT Timestamp, LogAttributes['k8s.pod.name'] AS pod, Body
FROM otel.otel_logs
WHERE LogAttributes['k8s.namespace.name'] = 'vmagent-lab'
ORDER BY Timestamp DESC LIMIT 20;
```

`ServiceName` 和 `ResourceAttributes` 會是空的：fluent-bit classic `opentelemetry` output 會把 record 的 key 對應成 log attributes，而不是 resource attributes。

## vmagent scale-down lab

沒有任何自動擴縮：shard 數由人直接設定，和 production 一樣用 `kubectl scale`。

| 指令 | 作用 |
|---|---|
| `make load N=8` | 設定 avalanche replicas 數。每個約 1000 samples/s，只產生負載，不會觸發擴縮 |
| `make pin N=3`／`make pin N=off` | 直接把 shardCount 設成 N（`kubectl scale vmagent/lab --replicas=N`）；`off` 回到基準值 2。沒有任何東西會自動擴縮 |
| `make outage-start`／`make outage-stop` | 模擬 remote storage 故障（VMCluster paused、vminsert → 0）／恢復 |
| `make queue` | 每個 pod 的 targets 數、磁碟 pending bytes、total pending bytes、是否 terminating |
| `make inspect-pvc` | 掛載沒有 pod 使用的 queue PVC，印出 `WriterOffset - ReaderOffset` 和 drain log。PVC 保留策略是 `Delete`，被移除 shard 的 PVC 會跟著刪掉，改回 `Retain` 才會留下可檢查的 PVC |
| `make scenario DRAIN=auto\|disk\|skip` | 在 60 秒 outage 中把 shard 從 3 縮到 2，確認被移除 shard 的 PVC 已刪除，再印出每個 target 的最大樣本間隔與 drain log（`Retain` 時改為檢查 PVC） |
| `make gaps N=3`／`make gaps N=upgrade` | reshard 或 rolling upgrade 時，從原始 sample 量測每個 target 的最大 scrape 間隔 |

## Vector scale-down lab

同樣沒有自動擴縮，replicas 由人設定。

| 指令 | 作用 |
|---|---|
| `make vload N=6` | 設定 loggen replicas 數。每個約 200 行/秒，只產生負載，不會觸發擴縮 |
| `make vpin N=3`／`make vpin N=off` | 直接把 Vector replicas 設成 N（`kubectl scale statefulset/vector`）；`off` 回到基準值 2。沒有任何東西會自動擴縮 |
| `make voutage-start`／`make voutage-stop` | Vector 的下游（rotel）設為 0／恢復 |
| `make vqueue` | 每個 Vector pod 的 disk buffer records/bytes |
| `make vinspect-pvc` | 讀取沒有 pod 使用的 Vector PVC 的 ledger，算出 `pending_records` |
| `make vscenario` | 在 rotel 中斷期間把 Vector 從 3 縮到 2，檢查被移除 pod 的 PVC，並顯示它的 shutdown log |

機制、證據與建議設定見 [docs/vmagent-graceful-scaledown.md](docs/vmagent-graceful-scaledown.md) 與 [docs/vector-graceful-scaledown.md](docs/vector-graceful-scaledown.md)。

## 只用 Grafana 唯讀驗證（agent skill）

`.claude/skills/monitoring-operator/` 是給 Claude Code 用的 skill。適用情境：

- 只有一個**已登入的 Grafana 瀏覽器分頁**（Playwright 或 Chrome DevTools MCP）。
- 可能只有 Viewer 權限。
- 沒有 shell，也沒有帳密。

內容包括：

- 如何把網頁上的 SOP 轉成檢查表：哪些步驟用 Grafana 觀察，哪些交給人操作（HUMAN），哪些看不到（NOT-OBSERVABLE）。
- `kubectl`／`clickhouse-client`／`curl /metrics` 對應到哪些 Grafana 訊號（`sop-translation.md`）。
- 在已登入的分頁裡呼叫 `/api/ds/query` 的唯讀查詢 helper（`scripts/ds-query.js`）。Viewer 也能用；datasource 可以用名稱或 uid 指定。
- 本 lab 的環境事實（`profiles/monops-lab/profile.md`）：datasource、dashboard、`job` label、log 欄位、資料新鮮度門檻、監控盲區。
- 縮容／drain／rolling upgrade 的驗證流程與失敗特徵（`profiles/monops-lab/scaledown-playbook.md`）。

`SKILL.md`、`scripts/ds-query.js`、`sop-translation.md` 不含任何 lab 專屬的名稱，可以直接搬到其他 Grafana 使用。換環境時，照 `SKILL.md` 的 Profiles 欄位表新增一個 `profiles/<name>/profile.md`；如果沒有對應的 profile，agent 會在 Orient 階段自己補齊這些欄位，並標記為 *interpreted*。

設計理由、實測矩陣（正向與負向對照組）和監控盲區，見 [docs/grafana-readonly-verification.md](docs/grafana-readonly-verification.md)。
