# 更新日誌

本專案的所有重要變更都會記錄在此檔案。

格式依循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號依循 [語意化版本](https://semver.org/lang/zh-TW/)。

## [未發布]

### 新增（網路測試）

- **三個網路測試模式 `baseline` / `traffic` / `mixed`**，回答「主機扛大量下載流量時網站還答不答得動」：
  - `baseline` —— 只跑 `wrk`，建立網站效能基準
  - `traffic` —— 只跑多個 `curl` 下載程序拉高接收流量
  - `mixed` —— 下載流量與網站壓測同時進行，看網站相較 baseline 的掉幅
- 網路監看 `_mon_net`：每 3 秒記錄 CPU 忙碌率（由 `/proc/stat` 前後差算得）、Load、可用記憶體、網卡收發速率（`/proc/net/dev` 差分）、TCP `ESTAB` / `TIME-WAIT` 數（`ss -tan`）
- 摘要依 `SUITE` 分兩套：本機壓測維持 CPU/RAM/DISK/SWAP/NTP，網路測試改列「目標 / 下載 / 網站 / 流量 / 系統」與網路專屬判讀提示
- 自動警告：CPU 忙碌峰值 ≥95%（吞吐卡在 CPU 而非頻寬）、TIME-WAIT 峰值超過門檻（來源埠恐耗盡）、wrk 出現非 2xx/3xx 或 socket error
- 目標網址與下載來源透過環境變數 `URL` / `DL_URL` 提供（無預設值，必填才跑），另有 `WRK_THREADS` / `WRK_CONNS` / `DL_WORKERS` / `HOST_HEADER` / `UA` / `INSECURE`
- 下載內容一律寫 `/dev/null` 不落磁碟；curl worker 反覆下載至時間結束；中斷時所有 worker 與暫存目錄都會收乾淨
- 相容 CentOS 7 / Bash 4.2：不使用 nameref、關聯陣列、mapfile、非必要的 process substitution
- `need` 對 `wrk` 給專屬安裝提示（不在 base repo，需 EPEL 或自行編譯）

### 新增（報告）

- **每次執行只產生一份報告**，五個項目依 CPU → RAM → DISK → SWAP → NTP 的固定順序寫在同一個檔案裡。舊版每個項目各寫一個檔案，`cat swap-*.log` 只看得到 swap，得自己拼四個檔案
- 報告開頭加上機器資訊區塊：主機名、OS、核心版本、虛擬化型態、CPU 型號、核心數、記憶體、SWAP、執行參數
- 章節標頭以固定的 `n/5` 編號，跑單項時也看得出它在整體流程中的位置
- **報告末尾加上摘要**，各項目關鍵數字彙整成一張表，並重列所有警告（`all` 的本文有數百行，警告很容易被捲過去）
- 摘要永遠列滿五項，沒跑到的標為「未執行」而非省略 ——「沒測」和「沒問題」是兩回事
- 摘要附判讀提示：steal 的意義、VM 讀取數據不可信、平均值會掩蓋雙峰延遲
- Ctrl-C 中斷時仍輸出摘要並標記「已中斷」，前面跑完的項目不白費
- DISK 每個模式的 runtime 短於 5 秒時警告 —— `iodepth=32` 下只發得出幾十個 IO，百分位數純粹是雜訊，但它會安靜地產出看起來很正常的數字
- SWAP 偵測到 OOM 記錄時升級為警告並列進摘要
- RAM 的 bogo ops 為 0 時在摘要註明是 `DUR` 太短跑不完一輪，不是故障

### 修正

- **fio 百分位數的單位在報告裡是不明的。** fio 依數值大小自己換單位，而標明單位的 `clat percentiles (usec):` 那行被 grep 濾掉了 —— 同一份 log 裡 `99.00th=[ 848]`（微秒）和 `99.00th=[ 3473]`（毫秒）長得一模一樣卻差 1000 倍。改為保留該行，摘要中的 p99 一律換算成 ms 以便跨模式比較
- **CPU 監看的四個數字全是錯的。** 本次新增 `%steal` 時，順手把欄位改成「從表頭找欄號」以求跨版本穩健，反而錯位。CentOS 7 預設 `en_US.UTF-8`，mpstat 把時間印成 12 小時制 `02:57:19 PM`，表頭因此多一個 AM/PM 欄位（13 欄），而 `Average:` 行開頭只有一欄（12 欄）—— 拿表頭欄號索引資料行整排差一格：`usr` 讀到的是 `%nice`、`sys` 是 `%iowait`、`steal` 是 `%guest`，`idle` 指向不存在的欄位而成空字串。改為以資料行自己的 `all` 欄為基準往後數，並加上 `LC_ALL=C`。實機 log 的症狀是 4 核滿載卻顯示 `usr=0.00% ... idle=%`
- **`bash <(curl ...)` 跑法下用法說明印不出來。** `usage()` 原本回頭讀腳本自己來擷取開頭的註解區塊，但 process substitution 餵給 bash 的是一次性的 pipe（`/dev/fd/63`），bash 讀完腳本後它就到 EOF，回頭讀只會拿到空字串 —— 而「參數打錯」正是最需要用法說明的時候。改為寫成字串常數。檔案執行、`bash <(...)`、`curl | bash -s --` 三種跑法現在行為一致
- 腳本不再需要知道自己的路徑，`$SELF` 隨之移除

### 變更（不相容）

- **測試產物改為落在執行時所在的目錄。** 舊版一啟動就 `cd` 到腳本所在目錄，所以不管你在哪裡執行，log 都寫回腳本旁邊的 `logs/`。現在不再 `cd`，`logs/` 與 fio 測試檔都跟著 CWD 走 —— 想把結果收在哪，`cd` 過去再跑即可。腳本放在共用路徑（如 `/opt/tools/`）時差別最明顯
- `LOGDIR` / `DISK_DIR` 啟動時解析成絕對路徑，log 印出的位置不再有「相對誰」的疑問，也讓清理 trap 不受後續 cd 影響
- 目前目錄不可寫時直接中止並印出 `pwd`，而不是跑完才發現寫不進去
- `usage()` 額外印出這次的輸出目錄，並附上不落地執行的一行指令
- `oom_restore` 還原 sshd 的 `oom_score_adj` 後印出訊息，之前它靜靜地做，無從確認保險是否生效
- `log()` 在 `LOG` 尚未建立時不再因 `set -u` 而中斷整個 trap
- README 新增「一鍵執行」章節並移到最前面，列出各項目的完整 `bash <(curl ...)` 指令，另記下三個實際踩過的坑：參數要接在 `<(...)` 之後、raw URL 少了分支名會 404、`main` 會變動所以要可重現就換成 commit SHA

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
