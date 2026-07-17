# stress-test

針對 CentOS 7.9 / KVM 虛擬機的單檔壓力測試腳本。分兩組：

- **本機壓測** —— CPU、記憶體、磁碟、SWAP、NTP 時間偏移
- **網路測試** —— 主機在扛大量下載流量時，網站是否仍能正常回應（`baseline` / `traffic` / `mixed`）

跑測試的同時會在旁邊持續輸出系統監看數據，每次執行產生一份報告寫進 `logs/`。

腳本的重點不只是「把機器操滿」，而是**讓數據可信**：磁碟測試會偵測 KVM host cache 汙染、SWAP 測試會先保護 sshd 不被 OOM killer 殺掉、NTP 測試不管怎麼中斷都會把時鐘還原、網路測試會把 CPU 峰值跟吞吐擺在一起讓你判斷瓶頸在哪。

## 一鍵執行

不落地，複製貼上就跑（需要 root）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) cpu
```

**參數要接在 `<(...)` 之後**，不是接在 `curl` 後面 —— 這是最容易寫錯的地方。把最後的 `cpu` 換掉就是其他項目：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) ram
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) disk
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) swap
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) ntp
bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) all
```

環境變數寫在最前面。先用短時間走一遍流程是個好習慣：

```bash
DUR=10 bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) all
```

跑之前先把相依工具裝好，否則腳本只會告訴你缺什麼然後結束：

```bash
yum install -y fio sysstat stress-ng chrony
```

log 會寫到**你當下所在目錄**的 `logs/`。在 `~` 底下跑就是 `/root/logs/`，想收在別的地方就先 `cd` 過去。

### 幾個容易踩的點

**為什麼是 `bash <(...)` 而不是 `curl ... | bash`？** 後者腳本是從 stdin 讀進來的，bash 邊讀邊執行；測試工具若有任何動到 stdin 的行為，就會把還沒讀到的腳本內容吃掉，症狀是腳本莫名其妙跑到一半就結束。`bash <(...)` 沒有這個問題。

**URL 一定要有分支名。** `raw.githubusercontent.com` 的格式是 `/<使用者>/<repo>/<分支>/<路徑>`，少了中間的 `main` 會拿到 404。

**要可重現的話把 `main` 換成 commit SHA。** `main` 隨時會變，同一行指令兩週後跑的可能不是同一份腳本。

### 或者存成檔案

要重複跑很多次、或機器連不上 GitHub 時：

```bash
curl -fsSL -o stress-test.sh https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh
chmod +x stress-test.sh
./stress-test.sh cpu
```

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

不帶參數執行會印出用法說明與這次的輸出目錄。

### 輸出位置

測試產物（log、fio 測試檔）一律落在**你執行時所在的目錄**底下的 `logs/`，跟腳本本身放在哪無關：

```bash
cd /var/tmp/bench
/opt/tools/stress-test.sh cpu     # → /var/tmp/bench/logs/cpu-20260717-135400.log
```

所以想把結果收在某個位置，`cd` 過去再跑就好。腳本啟動時會把路徑解析成絕對路徑，log 裡印出來的位置不會有「這是相對誰」的疑問。

目前目錄不可寫時腳本會直接中止，而不是跑完才發現寫不進去。

### 環境變數

| 變數 | 預設 | 說明 |
|---|---|---|
| `DUR` | `60` | 每個項目持續秒數。disk 會把這個值平分給四種讀寫模式 |
| `DISK_DIR` | `./logs` | fio 測試檔的位置，測完自動刪除 |

```bash
DUR=300 ./stress-test.sh all
DISK_DIR=/data ./stress-test.sh disk
```

`DISK_DIR` 是唯一會跑出 `logs/` 之外的東西 —— 要測的是特定那顆磁碟時才需要指定，否則 fio 只會量到 `logs/` 所在的檔案系統。

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

## 網路測試（baseline / traffic / mixed）

回答一個問題：**主機正在扛大量對外下載流量時，你的網站還答不答得動？** 用 `wrk` 打網站、`curl` 灌下載流量、監看記錄 CPU / Load / 網卡收發 / TCP 狀態。

> 這不是分散式壓測平台，也取代不了外部壓測機。它量的是「單機在網路忙碌下的自我表現」。

### 需要的工具

```bash
yum install -y epel-release && yum install -y wrk    # wrk 不在 base repo
# curl base 就有
```

`wrk` 在 CentOS 7 的 base repo 裡沒有，要透過 EPEL 或自行編譯（[wg/wrk](https://github.com/wg/wrk)）。缺工具時腳本會告訴你怎麼裝。

### 目標怎麼給

目標網址與下載來源**沒有預設值**，必須自己用環境變數提供 —— 這些是你授權要打的目標，腳本不會（也不該）幫你決定：

| 變數 | 用途 | 哪些模式需要 |
|---|---|---|
| `URL` | wrk 壓測的網站 | baseline、mixed |
| `DL_URL` | curl 下載來源，逗號分隔可多個 | traffic、mixed |
| `WRK_THREADS` / `WRK_CONNS` | wrk 執行緒數 / 連線數（預設 2 / 50） | |
| `DL_WORKERS` | 同時幾個 curl 下載程序（預設 4） | |
| `HOST_HEADER` | 自訂 Host header（打 IP 測特定 vhost 時用） | |
| `UA` | 自訂 User-Agent（預設 `stress-test/1.0`） | |
| `INSECURE=1` | 跳過 TLS 驗證（只在測自簽憑證的內部站時用） | |

`DUR` 一樣控制每次測試的秒數。`URL` 與 `DL_URL` 這兩個角色的性質相反，分開講。

#### `URL`（wrk 目標）—— 只能是你自己的網站

wrk 會產生真實的高併發請求（`-c50` 就是持續壓 50 條連線），**對別人的網站等同一次小型 DoS**。只能填你有權壓測的目標：

```bash
URL=http://127.0.0.1/            # 這台機器上自己跑的網站，最常見
URL=http://127.0.0.1:8080/       # 換連接埠
URL=https://你的正式站/           # 你自己擁有的伺服器
```

網站是靠網域名分辨 vhost、直接打 IP 會被導到別站時，打 IP 但用 header 假裝帶網域名，不用改 hosts 或 DNS：

```bash
URL=http://127.0.0.1/ HOST_HEADER=shop.yoursite.com ./stress-test.sh baseline
```

只是想先確認腳本會動的話，這台機器臨時起一個就好：

```bash
python3 -m http.server 8080 &                 # 或 yum install -y httpd && systemctl start httpd
URL=http://127.0.0.1:8080/ DUR=15 ./stress-test.sh baseline
```

#### `DL_URL`（curl 下載來源）—— 用你控制的，或公開測速檔

這是要下載大檔來灌流量。**最推薦用你自己控制的來源**（自己的物件儲存、另一台機房主機上的大檔），乾淨又不打擾別人。

手邊沒有的話，各大機房有**專門公開給人測頻寬**的測速檔，這類就是設計來被下載的：

| 來源 | 範例 URL |
|---|---|
| Hetzner | `https://ash-speed.hetzner.com/1GB.bin` |
| OVH | `https://proof.ovh.net/files/1Gb.dat` |
| Cachefly | `https://cachefly.cachefly.net/100mb.test` |
| Cloudflare | `https://speed.cloudflare.com/__down?bytes=1073741824` |

> ⚠️ **有分寸**：這些是給「跑一兩次測速」用的，不是給你開 8 個 worker 連續灌十分鐘。這個工具會反覆下載直到時間結束，等於持續佔用對方頻寬。正式、長時間的測試請用你自己的檔案來源；拿公開檔只適合驗證工具能動（短時間、`DL_WORKERS` 2~4）。

> 📍 **來源要選近的**：下載速率會被「你到來源的那條線」限死。從中國/亞洲的機器打 `ash-speed.hetzner.com`（美國）大概只會看到 1~2MB/s 且平坦 —— 那是跨洲鏈路的上限，不是你機器的接收能力。想量單機真正能收多少，用地理上近、或同機房的來源。若接收速率又低又平、而 CPU 很閒，八成就是來源太遠。

### 三個模式

**baseline** —— 只跑 wrk，建立**無干擾基準**。這組 Requests/sec 之後拿來跟 mixed 對照。

```bash
URL=http://127.0.0.1/ DUR=60 ./stress-test.sh baseline
```

**traffic** —— 只跑多個 curl 下載，拉高接收流量。確認單機可達的接收流量，觀察 CPU 與 TCP。

```bash
DL_URL=https://ash-speed.hetzner.com/1GB.bin DL_WORKERS=4 DUR=60 ./stress-test.sh traffic
# 多個來源分散壓力：
DL_URL=https://ash-speed.hetzner.com/1GB.bin,https://proof.ovh.net/files/1Gb.dat ./stress-test.sh traffic
```

**mixed** —— 下載流量與網站壓測**同時進行**。模擬主機網路忙碌時仍要提供網站服務，看網站效能相較 baseline 掉了多少。這裡 `URL` 通常就指向同一台機器上的網站（`127.0.0.1`），因為下載流量跟網站搶的是同一台的 CPU 與網卡。

```bash
URL=http://127.0.0.1/ DL_URL=https://ash-speed.hetzner.com/1GB.bin DUR=60 ./stress-test.sh mixed
```

### 怎麼讀

報告摘要會給你這幾行：

```
  網站 Requests/sec 350.00，p99 延遲 310.00ms，傳輸 1.33MB，非 2xx/3xx 5
  流量 網卡平均接收 480.2MB/s，curl 實際下載 28.1GB
  系統 CPU 峰值 96%，load 峰值 8.4，接收峰值 512.0MB/s，ESTAB 峰值 210，TIME-WAIT 峰值 45000
```

- **mixed 的 Requests/sec 要跟單獨 baseline 的數字比** —— 兩者是分開執行的，腳本不會自動對照。掉幅就是流量壓力對網站的衝擊。
- **接收流量遠低於網卡上限、但 CPU 峰值接近 100%** —— 瓶頸在 CPU（軟中斷 / 單一佇列），不是頻寬。腳本會在 CPU 峰值 ≥95% 時警告。
- **TIME-WAIT 暴增** —— 短連線可能耗盡來源埠，腳本超過門檻會提示看 `net.ipv4.ip_local_port_range` 與 `tcp_tw_reuse`。
- 網站在壓力下開始回非 2xx/3xx，或 wrk 出現 socket error，都會升級成警告列進摘要。

下載內容一律寫到 `/dev/null`，不落磁碟。curl worker 反覆下載直到測試時間結束，中斷（Ctrl-C）時所有 worker 與暫存都會收乾淨。

## 報告

每次執行**只產生一個檔案**：`logs/<項目>-<YYYYmmdd-HHMMSS>.log`（相對於執行時所在的目錄），內容與畫面輸出相同。五個項目依 CPU → RAM → DISK → SWAP → NTP 的固定順序寫在同一份報告裡，`cat` 一次就看得完。

報告結構：

```
==============================================================================
                              壓 力 測 試 報 告
==============================================================================

  主機          Cloud180
  作業系統      CentOS Linux release 7.9.2009 (Core)
  核心版本      3.10.0-1160.el7.x86_64
  虛擬化        kvm
  CPU           Intel(R) Xeon(R) ...
  核心數        4
  記憶體        3789 MB
  SWAP          2047 MB

  執行項目      all
  每項持續      60 s
  ...

==============================================================================
  1/5  CPU
==============================================================================
  ...各項目的完整輸出...

==============================================================================
  摘要
==============================================================================

  CPU    933.17 bogo ops/s (4 核)，steal 峰值 0.00%
  RAM    85689.24 bogo ops/s，配置 3030MB，最低可用 178MB
  DISK   隨機讀  99.5k    IOPS  389MiB/s     p99 0.6ms
         隨機寫  69.2k    IOPS  270MiB/s     p99 0.8ms
         循序讀  9        IOPS  9411KiB/s    p99 3473.0ms   !! 無效 (host cache)
         循序寫  1405     IOPS  1406MiB/s    p99 522.2ms
  SWAP   換出峰值 420640 KB/s，最低可用 6MB，無 OOM
  NTP    未執行 (需單獨執行 ntp)

------------------------------------------------------------------------------
  警告
------------------------------------------------------------------------------
  !! 循序讀 7381MiB/s 超出實體磁碟合理範圍 -> 這是 KVM host 的 cache，此數據無效
```

章節編號固定用 `n/5` 的正式順序，跑單項時也看得出它在整體流程中的位置。沒跑到的項目在摘要裡標為「未執行」而不是省略 —— **「沒測」和「沒問題」是兩回事**。

摘要的百分位數一律換算成 ms。fio 會依數值大小自己換單位，原始輸出裡的 `848`（微秒）和 `3473`（毫秒）長得一模一樣卻差 1000 倍，所以報告本文也會一併保留 `clat percentiles (usec):` 這種標明單位的行。

Ctrl-C 中斷時仍會輸出摘要，標記為「已中斷」，前面跑完的項目不會白費。

從這個 repo 的目錄直接跑的話，`logs/` 與 fio 殘骸都已列在 `.gitignore` 裡，不會混進版控。

## 注意事項

- 這會真的把機器操到滿載，**不要在正式環境跑**
- `ntp` 會修改系統時鐘，雖然有還原保險，但觀察期間該機器的時間是錯的
- `swap` 有觸發 OOM killer 的風險，除了 sshd 之外的程序都可能被殺
- `DISK_DIR` 與 `/tmp` 在同一個檔案系統時，換路徑量出來的數據不會有差別
- 從唯讀或空間吃緊的目錄執行時，disk 測試會因為算不出足夠的測試檔大小而放棄（低於 512MB 即中止）
