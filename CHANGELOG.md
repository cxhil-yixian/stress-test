# 更新日誌

本專案的所有重要變更都會記錄在此檔案。

格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依循 [語意化版本](https://semver.org/lang/zh-TW/)。

## [未發布]

### 變更（不相容）

- **測試產物改為落在執行時所在的目錄。** 舊版一啟動就 `cd` 到腳本所在目錄，所以不管你在哪裡執行，log 都寫回腳本旁邊的 `logs/`。現在不再 `cd`，`logs/` 與 fio 測試檔都跟著 CWD 走 —— 想把結果收在哪，`cd` 過去再跑即可。腳本放在共用路徑（如 `/opt/tools/`）時差別最明顯
- `LOGDIR` / `DISK_DIR` 啟動時解析成絕對路徑，log 印出的位置不再有「相對誰」的疑問，也讓清理 trap 不受後續 cd 影響
- 目前目錄不可寫時直接中止並印出 `pwd`，而不是跑完才發現寫不進去
- `usage()` 額外印出這次的輸出目錄

### 新增

- CPU 監看加上 `%steal`。這是 KVM guest 最關鍵的一項 —— steal 高代表 CPU 被 hypervisor 拿去給別的 VM，能區分「host 超賣」與「這台 VM 本身慢」
- CPU 測試結束時提示 steal 的判讀方式
- `DUR` 啟動時驗證必須為正整數
- `.gitattributes` 強制 `*.sh` 使用 LF —— 帶著 CRLF 的腳本在 Linux 上會噴 `/usr/bin/env: bash\r: No such file or directory`，很難聯想到是行尾問題
- `.gitignore` 排除 `logs/` 與 `.fio-test.*`。產物現在會落在執行目錄，從 repo 目錄直接跑就會生在版控裡；fio 殘骸可能是個 4GB 的檔案

### 修正

- **磁碟的 host cache 偵測形同虛設。** 舊的 `BW=[0-9]+MiB/s` 比對不到 fio 實際輸出的 `BW=48.0MiB/s`（含小數）與 `BW=11.7GiB/s`（高速時 fio 會自動換單位）。抓不到時警告會靜靜地不觸發 —— 而 GiB/s 正是 host cache 汙染的典型徵兆，也就是這個檢查最該作用的時候。改為連單位一起解析並換算成 MiB/s
- **`DUR` < 4 時磁碟測試永遠跑不完。** `--runtime=$((DUR/4))` 會得到 0，而 fio 的 `runtime=0` 意為「不設限」，配上 `--time_based` 就是無限迴圈。改為至少 1 秒
- **NTP 測試被 Ctrl-C 時會還原兩次、倒扣 4 分鐘。** 中斷 `sleep` 後 INT handler 執行完，函式仍會繼續 return 而再次觸發 RETURN trap。INT handler 改為先解除 RETURN trap 並自行 `exit 130`（原本中斷後的 exit code 是 0），另加旗標確保還原動作可重入
- **NTP 測試在連不到 NTP 來源的機器上無法還原時鐘。** 舊版只靠 `chronyc makestep`。改為先 `date -s "-2 minutes"` 確定性地扣回自己撥掉的量，再讓 chronyd 修殘差
- **SWAP 測試把 sshd 的 `oom_score_adj` 永久留在 -1000。** 這等於永久豁免 OOM killer，與系統預期行為不符。改為記錄原值並於結束（含中斷）時還原
- **SWAP 的 OOM 記錄可能被截斷。** `dmesg | tail -30 | grep` 會在 OOM 之後多出幾行 kernel 訊息時漏掉記錄，改為先 grep 再 tail
- **`DISK_DIR` 指向 `logs/` 以外時，殘留測試檔不會被清除。** 啟動時的殘骸掃描改為同時涵蓋兩個目錄（以 `-ef` 比對 device+inode 避免重複掃描）
- `mon_start` 的 `disown` 改用 jobspec `%%`，PID 形式留作後備 —— CentOS 7 的 bash 4.2 會把 PID 當成 job number 而找不到，導致 job table 沒清掉、`kill -9` 後仍噴出 `Killed` 訊息（也就是這行 `disown` 本來要避免的事）
- 非 root 執行不再留下一個空的 `logs/` 目錄才報錯
- `cd` 到腳本目錄失敗時中止，而非繼續在錯誤的路徑執行

### 變更

- 用法說明改為自動擷取檔案開頭的註解區塊，不再寫死 `sed -n '2,16p'` 的行號；輸出會去掉 `# ` 前綴
- `t_disk` 的測試檔路徑改用全域 `FIO_FILE`，與頂層中斷 trap 指向同一個變數
- `need` 的安裝提示補上 `chrony`

## [1.0.0] - 2026-07-17

初次發布。單檔 `stress-test.sh`，針對 CentOS 7.9 / KVM 虛擬機的壓力測試。

### 新增

- **cpu** —— `stress-ng --cpu-method all` 拉滿所有核心，搭配 loadavg 與 `mpstat` 的 usr/sys/idle 背景監看
- **ram** —— 佔用總記憶體 80%（2 個 worker、`--vm-keep`），監看 MemTotal / MemAvailable / SwapFree
- **disk** —— `fio` 跑隨機讀寫（4k）與循序讀寫（1M），`iodepth=32`、`direct=1`，收 IOPS、頻寬與 p95 / p99 / p99.99 尾端延遲
- **swap** —— 吃到 RAM 95% + swap 50% 逼出換頁，跑完從 `dmesg` 撈 OOM 記錄；無 swap 時跳過
- **ntp** —— 停 chronyd 後將系統時鐘往前撥 2 分鐘，觀察應用行為後以 `chronyc makestep` 還原
- **all** —— 依序執行 cpu / ram / disk / swap（不含 ntp）
- `DUR` 與 `DISK_DIR` 環境變數
- 日誌輸出至 `logs/<項目>-<時間戳>.log`

### 安全與正確性設計

- 磁碟測試檔的三層清理：正常返回的 `RETURN` trap、Ctrl-C / kill 的 `INT`/`TERM` trap、以及啟動時掃除上次 `kill -9` 留下的殘骸
- 磁碟測試偵測 KVM host cache 汙染（頻寬 > 2GB/s）與 page cache 汙染（測試檔 < RAM），發現時標記數據無效
- SWAP 測試前將 sshd 的 `oom_score_adj` 設為 -1000，避免 OOM killer 斷掉連線
- NTP 測試的時鐘還原掛在 `RETURN` / `INT` / `TERM` trap，中斷也會還原
- 背景監看以單一函式（而非 pipeline）丟背景，確保 `$!` 取得的是監看迴圈本身的 PID；停止時遞迴殺整棵程序樹，避免孫程序漏網
- 啟動時檢查 root 權限與相依工具，缺工具時明確指出缺哪幾個

[未發布]: https://github.com/cxhil-yixian/stress-test/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/cxhil-yixian/stress-test/releases/tag/v1.0.0
