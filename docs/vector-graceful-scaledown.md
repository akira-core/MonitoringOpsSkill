# Vector aggregator：擴縮、rolling upgrade，以及縮容時讓 disk buffer PVC 是空的

> 環境：Vector 0.61.0（helm chart `vector/vector` 0.61.0，role Aggregator）、kind k8s v1.35、KEDA 2.21.0（實驗當時使用，現已從 lab 移除）。
> 時間戳為 2026-11-05 UTC 的實測。設定在 [`helm/values/vector.yaml`](../helm/values/vector.yaml)、
> [`manifests/vector-lab/`](../manifests/vector-lab)。
>
> 下文的試驗是在 KEDA 觸發擴縮時量測的（KEDA 已從本 lab 移除；現在沒有任何東西自動擴縮，用 `kubectl scale` 或 `make vpin N=<n>` 直接設定 replicas）。結論針對 Vector 的 drain，與是誰觸發擴縮無關。

```
pod logs ─► fluent-bit (DaemonSet) ──OTLP/HTTP──► Service vector:4318 ─► vector-N (StatefulSet)
                                                                          │ disk buffer (PVC data-vector-N)
                                                                          ▼
                                                                 rotel:4318 ─► ClickHouse otel.otel_logs
kubectl scale statefulset/vector（make vpin N=<n>）──► StatefulSet/vector .spec.replicas（基準 2，沒有 autoscaler）
```

## TL;DR

1. **Vector 不需要像 vmagent 那樣自己寫 drain 邏輯。** 收到 SIGTERM 時，Vector 會：
   1. 先停止 source。
   2. 每個 sink 繼續讀自己的 disk buffer。`disk_v2` reader 只有在「writer 已關閉**而且** buffer size 為 0」時才結束。
   3. 所有 sink 都送完後才退出。

   上限是 `VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS`，超過就強制結束，剩下的資料留在 PVC。
2. **buffer 以 ack 為準**：ledger 的 `reader_last_record` 只有在下游確認之後才會前進。所以正在 retry 的 request 不會像 vmagent 那樣「消失在 pending metric 之外」。
3. **擴縮只改 replicas**：每個 pod 的 config 都一樣，沒有 sharding，所以：
   - scale up 不會重啟既有的 pod。
   - scale down 只會移除最大編號的 pod。
   - rolling upgrade 是 StatefulSet 原生的逐一替換（實測順序 vector-2 → vector-1 → vector-0）。
4. 要做到縮容後 buffer 為空，需要四個條件：
   - graceful limit 夠長，必須涵蓋下游可能中斷的時間。
   - `terminationGracePeriodSeconds` 要大於 preStop sleep 加 graceful limit。
   - PVC 設成 `Retain` 作為安全網。
   - 用 alpine image，因為 distroless 沒有 shell，跑不了 preStop。

## 1. 原始碼依據（v0.61.0）

| 位置 | 行為 |
|---|---|
| `src/topology/running.rs` `stop()` | 等所有 task（sources、transforms、sinks）結束；超過 `graceful_shutdown_duration` 時印出 `Failed to gracefully shut down in time. Killing components.` 並強制結束 |
| `lib/vector-buffers/src/variants/disk_v2/reader.rs` `next()` | 「If the writer is closed and there is no more data in the buffer, `None` is returned」：只有 `is_writer_done() && total_buffer_size == 0` 時 sink 的輸入才會結束 |
| `disk_v2/ledger.rs` `LedgerState` | `buffer.db`（24 bytes，little-endian）：`writer_next_record` u64 @0、writer/reader file id u16 @8/@10、`reader_last_record` u64 @16 |

離線判斷 PVC 是否為空：`pending = writer_next_record - reader_last_record - 1`。`scripts/lab/vector/inspect-pvc.sh` 就是讀這個值。

和 vmagent 一樣，`buffer-data-*.dat` 的檔案大小**不代表**有沒有未送出的資料：已 ack 的 record 會一直留在目前的 data file 裡，直到檔案輪替。

## 2. 設定重點（`helm/values/vector.yaml`）

| 設定 | 原因 |
|---|---|
| `image.tag: 0.61.0-alpine` | chart 預設的 distroless image 沒有 `/bin/sh`，preStop 和除錯都需要 |
| `autoscaling.enabled: false`，`replicas: 2` | chart 直接 render `replicas`，用 `kubectl scale` 調整。實驗當時用 `autoscaling.external: true` 讓 KEDA 管 replicas，現已移除。`helm upgrade` 前先 `make vpin N=off` 回到 2，否則可能遇到和下文相同的 `conflict occurred` |
| `updateStrategy.rollingUpdate.maxUnavailable: 1`、`minReadySeconds: 10`、PDB `maxUnavailable: 1` | rolling upgrade 和 node drain 都一次只動一個 pod |
| preStop `sleep 15` | pod 已經從 Service endpoints 移除；讓 fluent-bit 在 Vector 關閉 listener 前，把 keep-alive 連線換到其他 pod |
| `VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS=240`、`terminationGracePeriodSeconds: 300` | 下游中斷最多 240 秒還能送完；300 > 15 + 240 + 餘裕 |
| sink `buffer: {type: disk, max_size: 1GiB, when_full: block}` | buffer 滿時對上游施加 back-pressure，fluent-bit 會 retry，不會丟資料 |
| `request.retry_max_duration_secs: 10` | 下游恢復後 10 秒內一定會重試 |
| `persistence.retentionPolicy: Retain` | 超過 graceful limit 的資料留在 PVC，同一個 ordinal 回來時會 replay |
| source `use_otlp_decoding: true` + sink `codec: otlp` | OTLP 原樣轉送，`LogAttributes` 和直接送 rotel 時完全一樣 |
| fluent-bit `Workers 4` + `net.keepalive_max_recycle 20` | kube-proxy 是以連線為單位分流；連線定期重建，新的 pod 才分得到流量 |

注意 metric 的語意：`use_otlp_decoding` 會讓 **buffer 和 sink 把一個 OTLP request 算成 1 個 event**（`vector_buffer_size_events`）。`otlp_in` source 的 `vector_component_received_events_total` 則是 **log 行數**，所以實驗當時 KEDA 用後者；要看真正的 ingest 速率也該用它。

## 3. 實測

### 3.1 Scale up（`make vload N=6`，約 1200 lines/s）

- 14:14:44：HPA 平均 547/pod，超過 400 → desired 3。`vector-2` 在 5 秒內 Ready；`vector-0`、`vector-1` 的 age 沒有重置。
- 20 秒內各 pod 收到的量：vector-0 197、vector-1 777、vector-2 305 lines/s。新 pod 有分到流量，但分配不平均（per-connection 分流）。

### 3.2 Rolling upgrade（改 StatefulSet env）

修訂版本的替換順序是 vector-2（14:20:09）→ vector-1（14:21:07）→ vector-0（14:21:44）。每次只有一個 pod not ready，前一個 Ready 之後才換下一個。

下游正常時，被替換的 pod 從 SIGTERM 到 `Vector has stopped.` 只花 17ms：buffer 是空的，PVC 由同一個 ordinal 沿用。

### 3.3 下游中斷中縮容（`make vscenario`，graceful limit 240s）

| 時間（UTC） | 事件 |
|---|---|
| 14:15:48 | rotel → 0。buffer 增長：vector-0 183 筆 / 18.4MB、vector-1 198 / 20.1MB、vector-2 166 / 17.0MB |
| 14:16:49 | pin 2 → vector-2 開始 preStop（sleep 15） |
| 14:17:04 | SIGTERM：`Shutting down... remaining_components="rotel, vector_metrics, otlp_in, prom" time_remaining="239 seconds left"` |
| 14:17:14–14:17:39 | 只剩 `remaining_components="rotel"`：sink 持續 retry，buffer 還沒送完 |
| 14:17:38 | rotel 恢復 |
| 14:17:45 | `Vector has stopped.`（graceful 結束，沒有出現 `Failed to gracefully`） |
| 之後 | `data-vector-2` ledger：`writer_next_record=343 reader_last_record=342` → **pending_records=0** ✅（data file 36MB 是已 ack 的資料） |

**端到端零遺失檢查**：loggen 每行都有遞增的 `seq`。14:15:30–14:18:30 這段期間，6 個 loggen pod 共約 21 萬行。

- 用 `k8s.pod.name` 分組統計時，只「缺」1 行。
- 那一行其實在 ClickHouse 裡，只是 `LogAttributes` 是空的（見 §4）。
- 所以這段期間沒有任何資料遺失。

### 3.4 對照組：graceful limit 10 秒

用 `VECTOR_GRACEFUL_SHUTDOWN_LIMIT_SECS=10` 跑同一個情境：

| 時間（UTC） | 事件 |
|---|---|
| 14:23:33 | SIGTERM：`time_remaining="9 seconds left"` |
| 14:23:43 | `ERROR ... components="rotel" Failed to gracefully shut down in time. Killing components.` |
| 之後 | `data-vector-2` ledger：`writer_next_record=1052 reader_last_record=862` → **pending_records=189** ❌ |
| 14:25:37 | vector-2 重新上線（KEDA 擴容，重新掛上同一個 PVC）。不久後 ledger `reader_last_record=1198`，已超過 1052 → 殘留的 189 筆已 **replay 並 ack** ✅ |

結論：

- graceful limit 是唯一的時間界限。
- 超過界限的資料不會遺失，但要等同一個 ordinal 回來才會送出；因此 `Retain` 是必要設定。

改設定時的附帶發現：

- 用 `kubectl set env` 改了 chart 管理的欄位之後，`helm upgrade` 會失敗：`conflict occurred`，revision 2 變成 failed。
- 原因是 helm 4 預設用 server-side apply，而那個欄位的 field manager 已經變成 kubectl。
- 需要 `helm upgrade --force-conflicts` 才能修回來。
- 結論：**chart 管理的值只透過 values 檔修改。**

## 4. 附帶發現：fluent-bit 偶發未加工的 record

30 分鐘約 59 萬行中有 19 行（約 0.003%）寫進 ClickHouse 時 `LogAttributes` 完全是空的，連 `log.iostream` 都沒有。Body 和時間戳都正確，可以對應到原始 container log 裡的某一行，所以**不是遺失**。推測這些 record 是 tail 的 `multiline.parser cri, docker` 輸出的，而且繞過了 parser 和 kubernetes filter 的加工。

影響：用 `LogAttributes['k8s.*']` 過濾的查詢會漏看這些行。可以試的處理方式（未驗證）：

- 改用單一 `multiline.parser cri`。
- 或改用非 multiline 的 `parser cri`。

## 5. 取捨與剩餘風險

- **graceful limit 決定能承受多久的下游中斷。** 超過時資料會留在 PVC（Retain）；同一個 ordinal 回來時會 replay，但在那之前資料延遲送達。
- `podManagementPolicy: OrderedReady`：一次縮掉多個 pod 時是**依序**終止，每個 pod 最多可能等到 graceful limit。手動縮容時一次減 1 個、等它結束再減下一個；實驗當時 HPA 的 scaleDown policy 就是每 120 秒只減 1 個。
- 負載分配依賴 fluent-bit 定期重建連線，所以新 pod 達到平均負載需要一點時間；擴容後先等負載分布穩定再縮容（實驗當時 HPA 的 30 秒 stabilization window 吸收了這段落差）。
- preStop sleep 15 秒期間，舊連線上仍可能有 request 進來（Vector 還在接收），這部分會照常寫進 buffer，並在 shutdown 時一起送完。
