# vmagent 自動擴縮與 graceful shutdown：讓 persistent queue PVC 縮容後是空的

> 環境：kind v0.31 / k8s v1.35、VictoriaMetrics v1.155.0、vm-operator v0.75.2、KEDA 2.21.0（實驗當時使用，現已從 lab 移除）。
> 下文所有時間戳都來自本 repo 的實際實驗（UTC）。T0–T4 在 2026-11-05、k8s v1.35 的 lab；T5、T6（§4.1）在 2026-11-07、重建後的 k8s v1.31.14 lab，PVC 保留策略已改為 `Delete`。
> 被測對象為 `manifests/vmagent-lab/vmagent.yaml`（`VMAgent/lab`）。
>
> 下文的試驗是在 KEDA 觸發縮容時量測的（KEDA 已從本 lab 移除；現在沒有任何東西自動擴縮，用 `kubectl scale` 直接設定 shardCount）。結論針對 drain，與是誰觸發縮容無關。

## TL;DR

1. **vmagent 沒有「關機前把 queue 送完」的 flag。** 收到 SIGTERM 時：
   - 磁碟 queue 裡的資料**原地保留**。
   - in-memory 的資料只有約 5 秒的 best-effort 機會送出。
   - 正在 retry backoff 的 block 會被**寫回磁碟**。

   所以「PVC 是空的」必須在 SIGTERM **之前**達成，也就是要靠 `preStop`。
2. 用 `VMAgent` CR 擴縮時（`kubectl scale` 或任何走 `/scale` 的控制器），scale subresource 對應的是 `spec.shardCount`，而**每次改 shardCount 都會讓所有 shard 同時 roll**，因為 `-promscrape.cluster.membersCount` 變了。preStop 必須分辨兩種情況：
   - **被移除的 shard**（`memberNum >= shardCount`）：PVC 之後不會再被掛載 → 必須完整 drain。
   - **存活的 shard**：PVC 會由同一個 ordinal 重新掛上並 replay → 應立刻放行。drain 只會拖慢 rollout；outage 期間還會卡住整個 rollout。
3. 被移除的 shard 要做到 queue 為 0，以下三個條件**都**必須成立：
   1. 先**停止 scrape**（清空 scrape config 再 `/-/reload`）。否則 SIGTERM 時一定有新的 in-memory 尾巴。
   2. `vmagent_remotewrite_pending_data_bytes == 0`（in-memory + 磁碟），而不只是 `vm_persistentqueue_bytes_pending`（只有磁碟）。
   3. retry / error / non-2xx 計數器**連續 `DRAIN_QUIET_SECONDS` 秒不變**，而且這個時間要大於 `-remoteWrite.retryMaxInterval`。正在 backoff 的 block 不會出現在任何 pending metric 裡。
4. PVC 保留策略決定 drain 失敗時的後果。
   - **`Retain`**：drain timeout（例如 remote 長時間不可用）時資料留在 PVC，同一個 ordinal 回來時自動 replay（T0 實測），但會留下孤兒 PVC。
   - **`Delete`（lab 目前的設定）**：縮容後 PVC 跟著刪掉，不留孤兒；代價是 drain 成了唯一的保護，timeout 就是資料遺失。T5、T6 實測了兩種結果（§4.1）。

實作：[`manifests/vmagent-lab/prestop-drain.sh`](../manifests/vmagent-lab/prestop-drain.sh)，`DRAIN_MODE=auto`。

---

## 1. vmagent 關機時 queue 的真實行為（讀 v1.155.0 原始碼）

資料在 vmagent 內可能位於四個位置：

| 位置 | 對應 metric | SIGTERM 時的命運 |
|---|---|---|
| `pendingSeries` 寫入緩衝（≤ `-remoteWrite.flushInterval`） | 無 | `mustFlushOnStop()` 推入 fastqueue |
| fastqueue in-memory channel | `vmagent_remotewrite_pending_data_bytes` 減去磁碟部分 | 有約 5 秒機會送出（`drainInMemoryQueue`）；送不完的在 `MustClose()` 時寫入磁碟 |
| 檔案 queue（`-remoteWrite.tmpDataPath`，也就是 PVC） | `vm_persistentqueue_bytes_pending` | **原地保留**。`drainInMemoryQueue` 看到檔案 queue 非空就直接 return |
| worker 已讀出、正在 retry backoff 的 block | **無**（reader offset 已推進） | `bt.Wait(stopCh)` 被中斷 → `MustWriteBlockIgnoreDisabledPQ` 寫回檔案 queue |

shutdown 順序（`app/vmagent/main.go`）：

1. 停止 HTTP server。
2. `promscrape.Stop()`：graceful shutdown **不送** stale markers（`scrapework.go` 的 `globalStopCh` 分支）。
3. `remotewrite.Stop()`：flush pendingSeries → `UnblockAllReaders`（5 秒 deadline）→ `client.MustStop()` → `fastqueue.MustClose()`。

Debug 用的兩個事實：

- 磁碟 queue 是否為空，可以讀 `persistent-queue/<idx>_<hash>/metainfo.json` 的 `WriterOffset - ReaderOffset`。`MustClose()` 時一定會寫回正確的 offset。`scripts/lab/inspect-pvc.sh` 就是用這個方法驗證。
- 檔案大小**不能**當成判斷依據：已經送出的 chunk 在被輪替之前會一直留在檔案裡。

## 2. Operator 擴縮行為（實測；當時由 KEDA 觸發）

| # | 觀察 | 證據 |
|---|---|---|
| O1 | `VMAgent` 的 `/scale` 對應 `.spec.shardCount`（不是 `replicaCount`）。任何走 `/scale` 的控制器（實驗當時是 KEDA，現在是 `kubectl scale`）都可以直接 target `VMAgent`。 | CRD `subresources.scale.specReplicasPath: .spec.shardCount` |
| O2 | **每次 shardCount 變動（擴和縮）都會讓所有 shard 同時 roll。** operator 的 `createOrUpdateApp` 對每個 shard 各開一個 goroutine（`go updateShard()`），沒有選項可以改成依序。單一 replica 時，2→3 的 shard 0、1 在 12:13:50 同時重啟。對策見 §7（每個 shard 2 個 replica）。 | operator v0.75.2 `factory/vmagent/vmagent.go`；pods startTime |
| O3 | 縮容順序：operator **先** roll 存活的 shard，等它們 Ready **之後**才刪掉被移除 shard 的整個 StatefulSet。所以被移除 shard 的 PVC 由 `whenDeleted` 決定，而不是 `whenScaled`。T5、T6 以 `Delete` 實測確認：StatefulSet 被刪的同一秒，pod 與 PVC 都被標記刪除；PVC 等 pod 退出後才消失，PV 再晚 2 至 4 秒。 | 4→3：shard 0–2 在 12:15:30 重啟，shard 3 在 12:15:45 才開始 preStop |
| O4 | 被移除的 shard 在 preStop 期間會用**舊的** membersCount 繼續 scrape，queue 也會繼續增長（outage 期間 2.07MB → 2.14MB → 2.9MB）。 | drain log |
| O5 | target 數量少時，hash 分配會嚴重不均：8 個 target 分到 3 個 shard 是 **0/4/4**。以平均值為依據的 autoscaler（例如 HPA、KEDA）看不到這種偏斜。 | `make queue` 的 TARGETS 欄位 |
| O6 | operator 預設會注入 `preStop.sleep`（`preStopSleepSeconds: 15`）。和自訂的 exec preStop strategic merge 之後會有兩個 handler，被 API 拒絕。需要設 `preStopSleepSeconds: 0`。 | `may not specify more than 1 handler type` |
| O7 | operator 會把 `config-out` emptyDir 以 **read-only** 掛到 vmagent container。要在 preStop 換 scrape config，得把同一個 volume 以可寫方式再掛到另一個路徑（`/drain-config-out`）。**隱含前提**：`config-reloader` sidecar 沒有 preStop，會立刻收到 SIGTERM 並結束，所以在 drain 期間不會把 config 改回去。如果未來 operator 版本給 reloader 加上 preStop，這個做法會無聲失效。 | `touch: Read-only file system`；ClickHouse log 中 reloader 在 preStop 開始的同一秒停止 |
| O8 | 實驗當時 KEDA 的 `minReplicaCount` 設為 2，現在基準值（`make pin N=off`）也是 2：`shardCount` 0/1 是 non-sharded 模式（沒有 `memberNum` flag，物件命名也不同）。本 lab 沒有測試 1↔2 的跨越。 | — |

## 3. Drain 設計的三次迭代

### v1：等磁碟 queue 為 0（`vm_persistentqueue_bytes_pending == 0`），繼續 scrape

- remote 健康時 4 秒就放行 SIGTERM。
- **失敗**（trial 0，outage 後縮容 3→2）：shard 2 的 PVC 殘留 **117,096 bytes**。
- 同樣的條件下另一次是 0 bytes，所以這個失敗不穩定重現。
- 殘留的 117KB 在 shard 2 重新上線時被 replay（reader offset 3275828 → 3392924）→ 證明 `Retain` 有效。

### v2：被移除的 shard 先停 scrape，再等 total pending（memory + disk）為 0；存活的 shard 直接放行

- 判斷方式：讀 `/proc/1/cmdline` 的 `-promscrape.cluster.memberNum`，和 `vmagents/lab/scale` 的 `spec.replicas` 比較。RBAC 在 `rbac.yaml`；用 `SSL_CERT_FILE` 指向 SA CA 做 TLS 驗證，不跳過憑證檢查。
- 存活的 shard：`skip` 模式，0 秒放行；PVC 會 replay，outage 時 rollout 也不會被卡住。
- **仍然失敗**（auto trial 1）：stop scrape → targets=0 → 等 35 秒 → remote 恢復 → total pending 連續 6 秒為 0 → SIGTERM。結果 PVC 殘留 **60,261 bytes**。
- 原因：outage 期間 worker 讀出的 block 正在 backoff。backoff 每次加倍，最長到 `retryMaxInterval`，預設 1 分鐘。這個 block 不在任何 pending metric 裡；SIGTERM 中斷 backoff 後把它寫回了磁碟。

### v3（目前版本）：v2 + quiet window

- `-remoteWrite.retryMaxInterval=10s`。
- drained 的定義：pending 為 0，**且** `retries_count_total + errors_total + non-2xx requests_total` 連續 `DRAIN_QUIET_SECONDS=15` 秒不變。
- 為什麼成立：任何在 backoff 中的 worker，最遲 10 秒內一定會 retry 並讓 counter 增加；只要有 counter 增加，quiet window 就會重置。

## 4. 試驗結果

所有試驗都用 `make scenario`（`scripts/lab/scenario-drain.sh`）：

1. pin 3 shards（現在是 `kubectl scale vmagent/lab --replicas=3`，即 `make pin N=3`）。
2. outage（vminsert → 0），持續 `OUTAGE_SECONDS`。
3. pin 2 shards（移除 shard 2）。
4. 恢復 remote。
5. 等被移除的 pod 消失後，用 `inspect-pvc.sh` 讀 PVC 的 `WriterOffset - ReaderOffset`。

| 試驗 | drain 版本 / 模式 | outage | 被移除 shard 的 targets | 縮容前該 shard 磁碟 queue | preStop 耗時 | **PVC 殘留**（Writer−Reader） |
|---|---|---|---|---|---|---|
| T0 | v1 `disk` | 60s | 4 | 2.7MB（preStop 前已送完） | 4s | **117,096 bytes** ❌ |
| T0' | v1 `disk` | 無 | 4 | 0 | 4s | 0 |
| T1 | v2 `full` | 60s | 1 | 372KB → 576KB | 39s | **60,261 bytes** ❌ |
| T2 | v3 `auto` | 60s | 1 | 351KB → 542KB | 62s | **0** ✅ |
| T3 | v3 `auto` | 90s | 1 | 562KB → 754KB | 77s | **0** ✅ |
| T4 | v3 `auto` | 無 | 1 | 0 | 18s | **0** ✅ |
| C1 對照 | `skip`（不 drain） | 60s | 1 | 372KB | 0s | **613,976 bytes** ❌ |

說明：

- 「576KB」這類箭頭表示被移除的 shard 在 preStop 開始前還在 scrape，queue 持續增長（O4）。
- quiet window 實際攔到的情況：
  - T2：pending 在 12:36:25 歸零，但 failures 到 12:36:35 都還在增加（267 → 276）。v2 會在 12:36:29 就放行 SIGTERM；v3 等到 12:36:53。
  - T3：pending 在 12:40:19 歸零，failures 增加到 12:40:29（359 → 370）。
- T2–T4 中被移除的 shard 只有 1 個 target（hash 分配的結果，見 O5），T0 有 4 個。quiet window 的判斷和 target 數量無關。
- 存活的 shard 在 v2/v3 都走 `skip`，0 秒放行。它們在 outage 期間累積的 queue 會由同一個 ordinal 的新 pod replay，例如 shard 1 新 pod 啟動時的 1.6MB queue 隨後歸零。
- 驗證方式：等被移除的 pod 完全消失（`metainfo.json` 只在 close 時寫入最終 offset）後，`inspect-pvc.sh` 以 read-only 掛載 PVC 讀取 offset。drain log 同時寫在 PVC（`prestop-drain.log`）和 container stdout（經 fluent-bit → rotel 進 ClickHouse，Grafana lab dashboard 最下方的 panel）。

### 4.1 改成 PVC `Delete` 後重驗（2026-11-07，k8s v1.31.14）

PVC 被刪掉之後就讀不到 offset，所以驗證改用兩個留在 PVC 以外的證據：被移除 pod 自己寫到 stdout、進了 ClickHouse 的 drain log，以及 VictoriaMetrics 裡每個 avalanche target 相鄰樣本的最大間隔（`measure-gaps.sh window`）。只有正向試驗不夠：缺口很小也可能只是被移除的 shard 沒有資料要送。所以同樣時序再跑一次 `skip` 當對照。

兩次都用 `OUTAGE_SECONDS=60 HOLD_SECONDS=150`，和 eval 1 相同。3 個 shard 時 shard 2 分到全部 4 個 target，outage 60 秒時兩個 replica 各積了約 1.6 MB。

| 試驗 | 模式 | preStop 開始時的 pending | preStop 結果 | PVC 與 PV | 每個 target 的最大樣本間隔 |
|---|---|---|---|---|---|
| T5 | v3 `auto` | 3,422,141 B、3,443,092 B | `DRAINED after 126s`（outage 結束後 25 秒） | pod 與 PVC 在同一次取樣（每 2 秒）消失，PV 再晚 2 至 4 秒 | **8.2 s** ✅（reshard 的相位差） |
| T6 對照 | `skip` | 未記錄（skip 不輪詢） | `skip drain`，在 outage 中立刻退出 | 同上，未送出的 queue 隨 PVC 一起刪除 | **71–73 s** ❌，4 個 target 都缺，永遠補不回 |

- 時序（T5，UTC）：outage 14:13:29–14:17:16；14:14:30 改成 2 個 shard；14:15:35 operator 刪 StatefulSet，pod 與 PVC 同時被標記刪除；14:17:41 `DRAINED`；14:17:42 pod 與 PVC 消失；14:17:46 PV 消失。
- 存活 shard 0、1 的 PVC uid 前後不變，它們只是被 roll，不會被刪。
- T6 的缺口從 outage 開始（約 14:21:50）到存活 shard 接手這些 target 為止，約 73 秒。存活 shard 接手後自己的 queue 在 outage 結束後 replay，所以後半段沒有缺口。
- 這次重驗也確認 O3：被移除 shard 的 PVC 由 `whenDeleted` 決定。
- 指令：`OUTAGE_SECONDS=60 HOLD_SECONDS=150 DRAIN=auto|skip scripts/lab/scenario-drain.sh`。腳本的 step 5 會依保留策略分支：`Delete` 時等 PVC 消失、印出最大樣本間隔與 drain log；`Retain` 時照舊檢查 PVC。

## 5. 建議設定（sharded + stateful VMAgent）

```yaml
spec:
  statefulMode: true
  persistentVolumeClaimRetentionPolicy:
    whenDeleted: Delete        # 縮容後不留孤兒 PVC；drain timeout = 資料遺失。要安全網就改 Retain
    whenScaled: Delete
  preStopSleepSeconds: 0       # 否則和自訂 preStop 衝突
  terminationGracePeriodSeconds: 300   # > DRAIN_TIMEOUT_SECONDS + ~15s vmagent shutdown
  extraArgs:
    remoteWrite.retryMaxInterval: 10s  # 讓 quiet window 可以短
  extraEnvs:
    - { name: DRAIN_MODE, value: auto }
    - { name: VMAGENT_NAME, value: lab }
    - { name: DRAIN_TIMEOUT_SECONDS, value: "240" }
    - { name: DRAIN_QUIET_SECONDS, value: "15" }   # > retryMaxInterval
    - { name: DRAIN_WRITABLE_CONFIG, value: /drain-config-out }
  volumeMounts:
    - { name: config-out, mountPath: /drain-config-out }   # 可寫的 config-out
  containers:
    - name: vmagent
      lifecycle:
        preStop:
          exec: { command: ["/bin/sh", "/drain/prestop-drain.sh"] }
```

實驗當時的 KEDA 設定是 `minReplicaCount: 2`，`scaleDown` policy 每次只減 1 個 shard、stabilization window 120 秒，以降低全 fleet roll 的頻率（見 O2）。現在 lab 沒有 autoscaler；如果 production 用 autoscaler 縮容，建議沿用這兩個限制。手動縮容時也一樣，一次減 1 個 shard。

## 6. 剩餘風險與取捨

- **drain timeout**：remote 不可用的時間超過 `DRAIN_TIMEOUT_SECONDS` 時，資料會留在被移除 shard 的 PVC（log 會出現 `TIMEOUT`）。
  - 下次擴容到同一個 ordinal 時會自動 replay。
  - 如果需要主動回收，可以做一個「orphan PVC reaper」Job：用臨時 vmagent 掛載該 PVC，`-remoteWrite.url` 必須相同，因為 queue 目錄名稱是 URL 的 hash。不設 scrape config，等 pending 為 0 後再刪除 PVC。本 lab 沒有實作。
- **`Delete` 的代價（lab 目前的設定）**：
  - drain timeout 加上 Delete 等於資料遺失。remote 在縮容時不可用超過 `DRAIN_TIMEOUT_SECONDS`（240 秒），被移除 shard 的 queue 就沒了。縮容前先確認 remote 健康，或在長時間 outage 期間不要縮容。
  - `whenScaled: Delete` 也會在調低 `replicaCount` 時刪掉被移除 replica 的 queue。這個 replica 會被判定為存活的 shard 而不 drain；資料靠同一個 shard 的另一個 replica 保住（HA pair 送的是同一批樣本）。
  - 未驗證：如果 operator 為了改 `volumeClaimTemplates` 這類不可變欄位而刪除重建 StatefulSet，刪除又級聯到 PVC，存活 shard 的 queue 也會被刪。改這類欄位前先切回 Retain。
  - 孤兒 PVC reaper（上一點）只在 Retain 時需要。
- **reload 成空 config 不是 graceful shutdown 路徑**：vmagent 會對被移除 shard 的 targets 送 stale markers。由於存活的 shard 在 O3 已經接手這些 targets，可能在圖上產生不超過一個 scrape interval 的小缺口。不想要的話可以加 `promscrape.noStaleMarkers: "true"`（本 lab 未測）。
- **全 fleet roll（O2）是 operator sharding 的設計限制**：每次擴縮都會讓所有 shard roll。`replicaCount: 2`（§7）能讓它變成無停機的 rolling，但 reshard 的 target 交接仍會出現 ≤1 個 scrape interval 的相位間隔。如果連這個也不可接受，可以改用 push 架構（例如 vmagent 做 ingest tier）：用一般的 StatefulSet 加 HPA 調 replicas，不會 reshard。
- **重新 `kubectl apply` VMAgent manifest 會把 shardCount 改回 2**；如果當時不是 2，這會觸發一次全 fleet roll（實驗當時 KEDA 會在下一輪再調回來，現在要人再 `make pin` 一次）。可以從 manifest 拿掉 `shardCount`，改用 server-side apply 的 field ownership 處理。

## 7. Rolling upgrade：每個 shard 2 個 replica（HA pair）

**為什麼需要。** operator 會同時更新所有 shard（O2），但**在同一個 shard 內**是自己實作的 OnDelete 滾動：`maxUnavailable=1`，等 pod Ready 加上 `minReadySeconds` 才換下一個。所以只要每個 shard 有 2 個 replica，任何時候每個 shard 都至少有一個 pod 在 scrape。

**設定**（`manifests/vmagent-lab/vmagent.yaml`）。以下幾項是**連動的**，要一起改：

| 設定 | 原因 |
|---|---|
| `replicaCount: 2` | 同一個 shard 的兩個 pod scrape 相同的 targets，labels 也完全相同 |
| VMCluster `vmstorage`/`vmselect` `extraArgs.dedup.minScrapeInterval: 5s` | 合併兩個 replica 產生的重複 sample（`helm/values/vm-k8s-stack.yaml`） |
| `minReadySeconds: 15` | vmagent 在 `/health` 回應 Ready 時，可能還沒完成 SD 和第一次 scrape |
| `podDisruptionBudget.maxUnavailable: 1` | operator 會為每個 shard 建一個 PDB，node drain 也只會一次動一個 pod |
| podAntiAffinity，`shard-num: "%SHARD_NUM%"` | 同一個 shard 的兩個 replica 分散到不同節點（placeholder 會依 shard 替換） |

若有 autoscaler 依 vmagent 負載算 shard 數，query 只能計算 `pod=~"vmagent-lab-[0-9]+-0"`，否則兩個 replica 的負載會被算兩次，shard 數也跟著加倍（實驗當時的 KEDA query 就是這樣寫的）。

**量測**（`scripts/lab/measure-gaps.sh`）：匯出原始的 `up{job="avalanche"}` sample，計算每個 target 相鄰兩筆 sample 的最大間隔。scrape interval 是 5s。

| 事件 | replicaCount 1 | replicaCount 2 |
|---|---|---|
| rolling upgrade（只改 pod template，shardCount 不變） | **10.0s**：4 個 target 中有 3 個漏 1 次 scrape | **5.0s**：沒有漏 ✅（每個 shard 同時最多只有 1/2 個 pod not ready） |
| reshard 2→3 | 8.5s | 8.5s |
| reshard 3→2 | 6.5s | 6.5s |

reshard 時的 6.5–8.5 秒間隔，**每次都在相同的 target 上、數值也相同**。這是 target 換到另一個 shard 時 scrape 相位改變造成的，不是停機，HA 消除不了。在 5s 的 dedup 視窗下，最多只會缺一個點。

**代價**：

- 對 target 的 scrape 量加倍。
- 寫入 vminsert 的量加倍，dedup 前的資料也加倍。
- PVC 數量加倍。
- 每次 reshard 會重啟 2×N 個 pod（仍然只是依序 roll，不會免費）。

**drain 回歸測試**：outage 中把 shard 從 3 縮到 2。shard 2 的兩個 replica（`-2-0`、`-2-1`）都走 `full` 模式，各自 drain 18 秒；兩個 PVC 都是 `pending_bytes=0` ✅。
