# stress-test

針對 CentOS 7.9 / KVM 虛擬機的單檔壓力測試腳本，涵蓋 CPU、記憶體、磁碟、SWAP 與 NTP 時間偏移五個項目。跑測試的同時會在旁邊持續輸出系統監看數據，所有結果都會寫進 `./logs/`。

腳本的重點不只是「把機器操滿」，而是**讓數據可信**：磁碟測試會偵測 KVM host cache 汙染、SWAP 測試會先保護 sshd 不被 OOM killer 殺掉、NTP 測試不管怎麼中斷都會把時鐘還原。

## 需求

- CentOS 7.9（其他 systemd + Linux 發行版應該也能跑，未驗證）
- root 權限（腳本會直接檢查，非 root 會拒絕執行）
- 相依工具：

  ```bash
  yum install -y fio sysstat stress-ng chrony
  ```

  各項目實際需要的工具：

  | 項目 | 需要 |
  |---|---|
  | cpu | `stress-ng`、`mpstat`（sysstat） |
  | ram | `stress-ng` |
  | disk | `fio` |
  | swap | `stress-ng`、`vmstat` |
  | ntp | `chronyc`（chrony） |

  工具缺少時腳本會明確指出缺哪幾個，不會噴 `command not found`。

## 用法

```bash
./stress-test.sh cpu     # CPU 壓測
./stress-test.sh ram     # 記憶體壓測
./stress-test.sh disk    # 磁碟讀寫
./stress-test.sh swap    # SWAP 壓測
./stress-test.sh ntp     # NTP 時間偏移 2 分鐘
./stress-test.sh all     # 跑 cpu / ram / disk / swap（不含 ntp）
```

不帶參數執行會印出用法說明。

### 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `DUR` | `60` | 每個項目持續秒數。disk 會把這個值平分給四種讀寫模式 |
| `DISK_DIR` | `./logs` | fio 測試檔的位置，測完自動刪除 |

```bash
DUR=300 ./stress-test.sh all
DISK_DIR=/data ./stress-test.sh disk
```

## 各項目做了什麼

### cpu

用 `stress-ng --cpu <核心數> --cpu-method all` 把所有核心拉滿，每 3 秒輸出一次 loadavg 與 `mpstat` 的 usr / sys / **steal** / idle。

`steal` 是這裡最該看的一項：它代表 CPU 被 hypervisor 拿去給同一台 host 上的其他 VM。壓測跑出來的 bogo ops 偏低時，steal 是唯一能區分「host 超賣」與「這台 VM 本身慢」的依據。

### ram

吃掉總記憶體的 80%，分 2 個 worker（`--vm-keep` 讓記憶體維持佔用而非反覆配置釋放）。每 3 秒輸出 MemTotal / MemAvailable / SwapFree。

### disk

依序跑隨機讀、隨機寫、循序讀、循序寫四種模式（隨機用 4k、循序用 1M，`iodepth=32`、`direct=1`）。

測試檔大小取可用空間的一半，上限 4096MB；不足 512MB 會直接放棄。檔案寫在 `$DISK_DIR/.fio-test.$$`，正常結束、Ctrl-C、甚至上次被 `kill -9` 留下的殘骸，下次啟動都會被清掉。

輸出只保留 IOPS、頻寬、平均延遲與 p95 / p99 / p99.99 尾端延遲。**尾端延遲才是重點** —— 共享雲端磁碟的平均值往往很好看，p99 卻會差上兩個數量級。

兩個資料可信度的警告會自動觸發：

- 測試檔小於 RAM 時，提醒讀取數據會被 page cache 汙染
- 頻寬超過 2GB/s 時，判定為在量 KVM host 的 cache 而非實體磁碟，該數據無效

VM 內的讀取數據普遍不可信（guest 的 `direct=1` 繞不過 hypervisor 的 cache），**請以寫入的 p99 尾端延遲為準**。

### swap

吃到 RAM 的 95% + swap 的 50%，逼出換頁但盡量不觸發 OOM。開始前會把所有 sshd 的 `oom_score_adj` 設成 -1000，避免被 OOM killer 挑中而斷線，結束時（含中斷）還原原值。跑完會從 `dmesg` 撈出 OOM 記錄。

沒有設定 swap 的機器會直接跳過此項目。

> OOM killer 仍有可能出手，建議另開一個 terminal 跑 `dmesg -w` 觀察。

### ntp

停掉 chronyd、把系統時鐘往前撥 2 分鐘，觀察 `DUR` 秒後還原。用來檢查應用在時間跳動時是否異常 —— TLS 憑證驗證、cron、DB replication、log 時序都可能出事。

必須先停 chronyd，否則兩秒後時間就被拉回，會誤以為沒生效。還原動作掛在 `RETURN` / `INT` / `TERM` trap 上，正常結束或 Ctrl-C 都會還原：先 `date -s "-2 minutes"` 確定性地扣回撥掉的量（不依賴網路，連不到 NTP 來源的機器也還原得了），再由 chronyd `makestep` 修掉殘差。

`all` 不包含此項目，需要時請單獨執行。

## 日誌

每次執行產生一個檔案：`logs/<項目>-<YYYYmmdd-HHMMSS>.log`，內容與畫面輸出相同。

## 注意事項

- 這會真的把機器操到滿載，**不要在正式環境跑**
- `ntp` 會修改系統時鐘，雖然有還原保險，但觀察期間該機器的時間是錯的
- `swap` 有觸發 OOM killer 的風險，除了 sshd 之外的程序都可能被殺
- `DISK_DIR` 與 `/tmp` 在同一個檔案系統時，換路徑量出來的數據不會有差別
