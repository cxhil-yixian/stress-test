#!/usr/bin/env bash
#
# stress-test.sh -- 壓力測試 (CentOS 7.9 / KVM VM)
#
# 用法說明見下面的 usage()，或不帶參數直接執行。
#
# 每次執行只產生一份報告，五個項目依 CPU -> RAM -> DISK -> SWAP -> NTP 的順序
# 寫在同一個檔案裡，最後附一段摘要。
#
# 腳本刻意不 cd 到自己所在的目錄：測試產物 (報告、fio 測試檔) 都落在
# 「你執行時所在的目錄」底下的 logs/，跟腳本放在哪無關。要換地方就 cd 過去再跑。

set -uo pipefail

# 用法說明寫成字串常數，不要回頭讀腳本自己。
# bash <(curl -fsSL ...) 這類跑法餵給 bash 的是一次性的 pipe (/dev/fd/63)，
# bash 讀完腳本後它就到 EOF 了，回頭讀只會拿到空字串 --
# 而「參數打錯」正是最需要用法說明的時候。
usage() {
    cat <<'EOF'
本機壓測:
  stress-test.sh cpu           CPU 壓測
  stress-test.sh ram           記憶體壓測
  stress-test.sh disk          磁碟讀寫
  stress-test.sh swap          SWAP 壓測
  stress-test.sh ntp           NTP 時間偏移 2 分鐘
  stress-test.sh all           以上全跑 (不含 ntp，時鐘要自己單獨測)

網路測試 (主機扛下載流量時網站還答不答得動):
  stress-test.sh baseline      只跑 wrk，建立網站效能基準           需要 URL
  stress-test.sh traffic       只跑 curl 多路下載，拉高接收流量      需要 DL_URL
  stress-test.sh mixed         下載流量 + 網站壓測同時               需要 URL 與 DL_URL

通用參數:
  DUR=60            每項持續秒數
  DISK_DIR=./logs   fio 測試檔位置 (測完自動刪除)

網路測試參數 (URL/DL_URL 沒有預設，必須自己給授權的目標):
  URL=http://127.0.0.1/            wrk 壓測目標，只能是你自己的網站
  DL_URL=https://來源/big.bin      curl 下載來源，逗號分隔可多個
  WRK_THREADS=2  WRK_CONNS=50      wrk 執行緒 / 連線數
  DL_WORKERS=4                     同時幾個 curl 下載程序
  HOST_HEADER=  UA=stress-test/1.0 自訂 Host / User-Agent
  INSECURE=1                       跳過 TLS 驗證 (測自簽憑證的內部站才用)

  URL 只能填你有權壓測的網站 (通常是本機 127.0.0.1)，wrk 會產生真實高併發
  請求，打別人的站等同 DoS。DL_URL 建議用自己的檔案來源；公開測速檔 (如
  ash-speed.hetzner.com/1GB.bin) 只適合短時間驗證，別長時間連續灌。

範例:
  URL=http://127.0.0.1/ DUR=60 stress-test.sh baseline
  DL_URL=https://ash-speed.hetzner.com/1GB.bin DL_WORKERS=4 stress-test.sh traffic
  URL=http://127.0.0.1/ DL_URL=https://ash-speed.hetzner.com/1GB.bin stress-test.sh mixed

不落地直接跑 (參數要接在 <(...) 之後，環境變數放最前面):
  URL=http://127.0.0.1/ bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) baseline

每次執行產生一份報告 logs/<項目>-<時間戳>.log，內容依序寫在同一個檔案裡。
EOF
    echo "這次的輸出會寫到: ${LOGDIR:-<尚未建立>}"
}

# 先驗身分再建目錄，不然非 root 執行會留下一個空的 logs/ 才跟你說不能跑
[ "$(id -u)" = "0" ] || { echo "要 root"; exit 1; }

DUR="${DUR:-60}"
# DUR 會進到算術展開跟 fio --runtime，非數字的話錯誤訊息會很難懂，先擋掉
case "$DUR" in ''|*[!0-9]*) echo "DUR 要是正整數，收到: $DUR"; exit 2 ;; esac
[ "$DUR" -ge 1 ] || { echo "DUR 要 >= 1"; exit 2; }

# ---------- 網路測試參數 (baseline / traffic / mixed 用) ----------
# URL / DL_URL 沒有預設值，因為它們是「你授權的目標」，寫死等於幫使用者決定
# 要打誰 -- 絕對不行。缺的時候由主流程按模式各自要求。
URL="${URL:-}"                      # wrk 壓測的網站 (baseline/mixed 必填)
DL_URL="${DL_URL:-}"                # curl 下載來源，逗號分隔多個 (traffic/mixed 必填)
WRK_THREADS="${WRK_THREADS:-2}"     # wrk -t
WRK_CONNS="${WRK_CONNS:-50}"        # wrk -c
DL_WORKERS="${DL_WORKERS:-4}"       # 同時幾個 curl 下載程序
HOST_HEADER="${HOST_HEADER:-}"      # 自訂 Host header (打 IP 測特定 vhost 時用)
UA="${UA:-stress-test/1.0}"         # 自訂 User-Agent
INSECURE="${INSECURE:-0}"           # =1 時跳過 TLS 驗證 (curl -k / wrk 本來就不驗)
for _v in WRK_THREADS WRK_CONNS DL_WORKERS; do
    eval "_val=\$$_v"
    case "$_val" in ''|*[!0-9]*) echo "$_v 要是正整數，收到: $_val"; exit 2 ;; esac
    [ "$_val" -ge 1 ] || { echo "$_v 要 >= 1"; exit 2; }
done
# INSECURE 統一收斂成 curl 要不要加 -k。只有明確 =1 才關驗證，
# 寫成 ${INSECURE:+-k} 會連 INSECURE=0 都觸發 (非空即展開)，這是常見的坑。
CURL_K=""; [ "$INSECURE" = "1" ] && CURL_K="-k"

# 相對於 CWD 建立，再轉成絕對路徑存起來。
# 轉絕對路徑有兩個好處：報告裡印出的路徑不會有「這是相對誰」的疑問，
# 而且之後任何 cd 都不會讓 trap 清錯檔案。
LOGDIR="./logs"
mkdir -p "$LOGDIR" || { echo "無法在目前目錄建立 logs/ (pwd: $PWD)"; exit 1; }
LOGDIR="$(cd "$LOGDIR" && pwd)"

# fio 測試檔預設就寫在 logs/ 裡，跑完由 trap 刪掉。
# 注意這跟 /tmp 在同一個檔案系統時，數據不會有差別。
DISK_DIR="${DISK_DIR:-$LOGDIR}"
mkdir -p "$DISK_DIR" || { echo "無法建立 $DISK_DIR"; exit 1; }
DISK_DIR="$(cd "$DISK_DIR" && pwd)"
TS=$(date +%Y%m%d-%H%M%S)

# 整份報告就一個檔案，主流程決定檔名後才設定
LOG=""

# fio 測試檔的路徑存成全域，讓中斷時的 trap 也清得到。
# t_disk 自己的 RETURN trap 只在正常返回時觸發，Ctrl-C 走的是下面這條，
# 不處理的話會留一個 4GB 的檔案在 logs/ 裡。
FIO_FILE=""
# t_swap 動過的 sshd oom_score_adj，格式 "pid:原值 pid:原值"
OOM_SAVED=""
# 網路測試的暫存：curl worker 的 PID 清單 + 一個放監看統計/下載計數的暫存目錄，
# 中斷時要收乾淨。
DL_PIDS=""
NET_TMP=""

# ---------- 摘要用的全域 ----------
# SUITE 決定摘要長哪一套：local (cpu/ram/disk/swap/ntp) 或 net (baseline/traffic/mixed)。
# 兩套的判讀完全不同，硬塞在一起只會互相干擾。
SUITE="local"

# 本機壓測。每個 t_* 跑完自己填。沒跑到的維持「未執行」，摘要才會永遠列滿五項，
# 讓人一眼看出「這項沒測」而不是「這項沒問題」-- 兩者差很多。
SUM_CPU="未執行"
SUM_RAM="未執行"
SUM_DISK="未執行"
SUM_SWAP="未執行"
SUM_NTP="未執行 (需單獨執行 ntp)"

# 網路測試。依模式填其中幾項。
SUM_WRK="未執行"      # wrk 網站壓測結果 (baseline/mixed)
SUM_DL="未執行"       # curl 下載流量結果 (traffic/mixed)
SUM_SYS="未取得"      # 監看撈到的系統峰值 (CPU/load/TCP)

WARNINGS=""

# 腳本被 Ctrl-C / kill 時：收掉背景監看 + curl workers + 還原 oom_score_adj + 清測試檔，
# 然後把已經跑完的部分做成摘要 -- 中斷不該讓前面的結果白跑
trap 'mon_stop 2>/dev/null; [ -n "$DL_PIDS" ] && kill $DL_PIDS 2>/dev/null
      oom_restore 2>/dev/null
      [ -n "$FIO_FILE" ] && rm -f "$FIO_FILE"; [ -n "$NET_TMP" ] && rm -rf "$NET_TMP"
      echo; echo "已中斷，已清理"; [ -n "$LOG" ] && report_summary "已中斷"; exit 130' INT TERM

# 掃掉上次沒清乾淨的殘骸 (例如被 kill -9)
_scan_stale() {
    local d="$1" f
    for f in "$d"/.fio-test.*; do
        [ -e "$f" ] || continue
        echo "清掉上次殘留的測試檔: $f ($(du -h "$f" 2>/dev/null | cut -f1))"
        rm -f "$f"
    done
}
_scan_stale "$LOGDIR"
# DISK_DIR 指到別的地方時那邊也要掃。-ef 比對 device+inode，
# 所以 ./logs 跟 logs 跟 /abs/path/logs 都認得出是同一個目錄，不會掃兩次。
[ "$DISK_DIR" -ef "$LOGDIR" ] || _scan_stale "$DISK_DIR"

# 缺工具時給明確訊息，而不是讓它噴 command not found
need() {
    local miss="" t
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
    [ -z "$miss" ] && return 0
    log "缺少工具:$miss"
    case "$miss" in
        # wrk 不在 CentOS 7 base repo，要自己編或裝 EPEL 版，訊息裡講清楚
        *wrk*) log "  wrk 需自行安裝: yum install -y epel-release && yum install -y wrk"
               log "         或從原始碼編譯 https://github.com/wg/wrk" ;;
    esac
    case "$miss" in
        *fio*|*stress-ng*|*mpstat*|*vmstat*|*chronyc*)
            log "  yum install -y fio sysstat stress-ng chrony" ;;
    esac
    return 1
}

# ---------- 排版 ----------
RULE=$(printf '%.0s=' {1..78})
THIN=$(printf '%.0s-' {1..78})

# LOG 要到主流程才建立。中斷 trap 可能在那之前就呼叫到 log()，
# 這時 set -u 會讓整個 trap 炸掉，所以給個預設值。
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG:-/dev/null}"; }

# 警告同時進報告本文與摘要。摘要裡再列一次是刻意的：
# 跑 all 時本文有好幾百行，警告很容易被捲過去。
warn() {
    log "  !! $*"
    WARNINGS="$WARNINGS
  !! $*"
}

# sec <編號> <標題> -- 章節標頭。
# 編號固定用 n/5 的正式順序 (CPU=1 RAM=2 DISK=3 SWAP=4 NTP=5)，
# 就算只跑單項也看得出它在整體流程裡的位置。
sec() {
    { echo
      echo
      echo "$RULE"
      echo "  $1  $2"
      echo "$RULE"
    } | tee -a "$LOG"
}

report_head() {
    local model
    model=$(awk -F: '/model name/{sub(/^ +/,"",$2); print $2; exit}' /proc/cpuinfo)
    { echo "$RULE"
      echo "                              壓 力 測 試 報 告"
      echo "$RULE"
      echo
      echo "  主機          $(hostname)"
      echo "  作業系統      $(sed -n '1p' /etc/redhat-release 2>/dev/null || uname -o)"
      echo "  核心版本      $(uname -r)"
      echo "  虛擬化        $(systemd-detect-virt 2>/dev/null || echo '未知')"
      echo "  CPU           ${model:-未知}"
      echo "  核心數        $(getconf _NPROCESSORS_ONLN)"
      echo "  記憶體        $(awk '/MemTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
      echo "  SWAP          $(awk '/SwapTotal/{printf "%d MB", $2/1024}' /proc/meminfo)"
      echo
      echo "  執行項目      $1"
      echo "  每項持續      ${DUR} s"
      echo "  開始時間      $(date '+%F %T %Z')"
      echo "  報告位置      $LOG"
      if [ "$SUITE" = "net" ]; then
          [ -n "$URL" ]    && echo "  壓測目標      $URL"
          [ -n "$DL_URL" ] && echo "  下載來源      $DL_URL"
          echo "  wrk           ${WRK_THREADS} 執行緒 / ${WRK_CONNS} 連線"
          echo "  下載程序      ${DL_WORKERS} 個 curl worker"
          [ "$INSECURE" = "1" ] && echo "  TLS 驗證      關閉 (INSECURE=1)"
      else
          echo "  fio 測試檔    $DISK_DIR"
      fi
    } | tee "$LOG"
}

# sum_row <標籤> <內容>，內容可以是多行，續行自動對齊
sum_row() {
    local label="$1" first=1 l
    while IFS= read -r l; do
        if [ "$first" = 1 ]; then printf '  %-6s %s\n' "$label" "$l"; first=0
        else                      printf '  %-6s %s\n' ""      "$l"; fi
    done <<< "$2"
}

# 兩套摘要的共通框架：標頭、警告區、收尾。中間的資料列與判讀提示由 SUITE 決定。
report_summary() {
    { echo
      echo
      echo "$RULE"
      echo "  摘要${1:+  ($1)}"
      echo "$RULE"
      echo
      if [ "$SUITE" = "net" ]; then
          [ -n "$URL" ]    && sum_row "目標" "$URL"
          [ -n "$DL_URL" ] && sum_row "下載" "$DL_URL"
          echo
          sum_row "網站" "$SUM_WRK"
          sum_row "流量" "$SUM_DL"
          sum_row "系統" "$SUM_SYS"
      else
          sum_row "CPU"  "$SUM_CPU"
          sum_row "RAM"  "$SUM_RAM"
          sum_row "DISK" "$SUM_DISK"
          sum_row "SWAP" "$SUM_SWAP"
          sum_row "NTP"  "$SUM_NTP"
      fi
      echo
      if [ -n "$WARNINGS" ]; then
          echo "$THIN"
          echo "  警告"
          echo "$THIN"
          echo "$WARNINGS"
          echo
      fi
      echo "$THIN"
      echo "  判讀提示"
      echo "$THIN"
      if [ "$SUITE" = "net" ]; then
          echo "  * mixed 的 Requests/sec 要跟「單獨 baseline」的數字比，才看得出"
          echo "    下載流量壓力下網站掉了多少。兩者是分開執行的，請自行對照。"
          echo "  * 接收流量遠低於網卡上限時，瓶頸多半在 CPU (軟中斷/單一佇列) 或"
          echo "    下載來源端，不是本機頻寬。看系統列的 CPU 峰值。"
          echo "  * TIME-WAIT 隨短連線暴增，可能耗盡來源埠；ESTAB 停滯代表連線"
          echo "    建立受限。網站延遲飆高時先看這兩個數字。"
      else
          echo "  * steal 持續 >0 代表 CPU 被 hypervisor 拿去給別的 VM，"
          echo "    此時 bogo ops 低是 host 超賣，不是這台機器的問題。"
          echo "  * VM 內的磁碟「讀取」數據普遍不可信 -- guest 的 direct=1 繞不過"
          echo "    hypervisor 的 cache。以「寫入的 p99 尾端延遲」為準。"
          echo "  * 平均延遲會把快慢兩群混在一起。p99 才是你的服務真正會遇到的。"
      fi
      echo
      echo "  結束時間      $(date '+%F %T %Z')"
      echo "  完整報告      $LOG"
      echo "$RULE"
    } | tee -a "$LOG"
}

# ---------- 背景監看 ----------
# 血淚教訓：不要寫成  ( while ...; done ) | sed | tee &
#   1. $! 拿到的是 tee 的 PID，不是 while 迴圈的
#   2. wait $! 會等「整條 pipeline 這個 job」結束，kill 掉 tee 不夠，job 不結束 -> 永遠卡住
#   3. 中間那個 sed 的 stdout 是 pipe，會區塊緩衝(4KB)，監看輸出要等 4 分鐘才吐出來
# 正解：監看函式直接丟背景(不接 pipeline)，$! 就是它本人；tee 放在迴圈「裡面」。
MON_PID=""

mon_start() {
    "$1" &            # 單一函式丟背景，不是 pipeline -> $! 即為其 PID
    MON_PID=$!
    # 把 job 從 bash 的 job table 移除。不然我們 kill -9 它之後，
    # bash 會回報 "line 69: 22074 Killed  "$1"" 到 stderr。
    # 先用 %% (剛丟到背景的就是 current job)：CentOS 7 的 bash 4.2 只吃 jobspec，
    # 給 PID 會被當成 job number 而找不到。新版 bash 才支援 PID，留作後備。
    # disown 之後不能再 wait 它，但我們用 kill -9 直接確保它死透，不需要 wait。
    disown %% 2>/dev/null || disown "$MON_PID" 2>/dev/null || true
}

# 遞迴殺整棵程序樹（由下往上）。
# 為什麼不能只用 pkill -P：監看迴圈裡是 `{ ...; } | tee`，本身又是一條 pipeline，
# 會再 fork 出孫程序。pkill -P 只殺直接子程序，孫程序會漏網並多吐一行出來。
_killtree() {
    local pid="$1" child children
    # 必須先「收集」子程序清單，再殺父程序：父死之後 pgrep -P 就查不到了。
    children=$(pgrep -P "$pid" 2>/dev/null)
    # 先殺父再殺子。反過來的話父程序還活著，會回報 job control 訊息
    # (line 125: 1407 Killed  vmstat 1 2) 噴到 stderr 弄髒輸出。
    kill -9 "$pid" 2>/dev/null
    for child in $children; do
        _killtree "$child"
    done
}

mon_stop() {
    [ -n "$MON_PID" ] || return 0
    # 監看只是印統計，沒有東西需要優雅收尾，直接 -9 最乾脆，
    # 也不用擔心 bash「等前景子程序跑完才處理訊號」那個行為拖時間。
    # 已 disown，所以不能也不需要 wait。
    _killtree "$MON_PID"
    MON_PID=""
}

# 取得目前報告的行數，之後用 tail -n +N 就能只撈這一段的監看數據。
# 報告現在是單一檔案，不記位置的話會把前面項目的數據也算進來。
mark() { wc -l < "$LOG"; }
# since <行號> -- 印出該行之後的報告內容
since() { tail -n +$(( $1 + 1 )) "$LOG"; }

# ---------- OOM 保護的還原 ----------
# oom_score_adj=-1000 等於永久豁免 OOM killer，測完不還原的話，
# 這台機器之後就再也不會 OOM 掉 sshd 了，跟系統預期行為不符。
oom_restore() {
    [ -n "$OOM_SAVED" ] || return 0
    local e p old n=0
    for e in $OOM_SAVED; do
        p="${e%%:*}"; old="${e##*:}"
        [ -d "/proc/$p" ] && echo "$old" > "/proc/$p/oom_score_adj" 2>/dev/null && n=$(( n + 1 ))
    done
    OOM_SAVED=""
    # 印出來才有辦法確認保險真的有生效，不然只能自己去 cat /proc/<pid>/oom_score_adj
    [ "$n" -gt 0 ] && log "已還原 $n 個 sshd 的 oom_score_adj"
    return 0
}

# ---------- CPU ----------
# 注意：一定要「整行組好再印」，不能邊算邊印。
# mpstat 1 1 要花整整一秒才回來，如果先 printf 前半段再等它，
# 這一秒空窗期 stress-ng 的輸出會插進來把行切斷：
#   load=... stress-ng: info: [22075] dispatching hogs
#   usr=97% sys=2%
_mon_cpu() {
    local ts load cpu
    while :; do
        ts=$(date +%H:%M:%S)
        load=$(cut -d' ' -f1-3 /proc/loadavg)
        # steal 對 KVM guest 是最關鍵的一項：它代表 CPU 被 hypervisor 拿去給別的 VM。
        # 壓測分數低但 steal 高 -> 問題在 host 超賣，不是這台機器慢。
        #
        # 千萬不要拿「表頭的欄號」去索引 Average 行 -- 兩者欄數不一樣。
        # CentOS 7 預設 en_US.UTF-8，mpstat 的時間印成 12 小時制:
        #   02:57:18 PM  CPU  %usr ...   <- 表頭前面兩欄 (時間 + PM)，%idle 在第 13 欄
        #   Average:     all  99.75 ...  <- 資料行前面只有一欄，idle 其實在第 12 欄
        # 照表頭的欄號讀會整排錯位一格，讀到的 usr 其實是 %nice、steal 其實是 %guest，
        # idle 則指到不存在的欄位而變成空字串。這個 bug 靜靜地錯，數字看起來很正常。
        #
        # 正解: 以資料行自己的 "all" 那欄當基準往後數，不管前面有幾欄時間戳都對。
        # CPU 之後的順序 (usr nice sys iowait irq soft steal guest gnice idle) 跨
        # sysstat 版本固定，新欄位一律往後加，所以 idle 取 $NF 最保險。
        # LC_ALL=C 則確保關鍵字是 Average/all 而不是被翻譯過的字串。
        cpu=$(LC_ALL=C mpstat 1 1 2>/dev/null | awk '
            /Average|平均/ {
                a = 0
                for (i = 1; i <= NF; i++) if ($i == "all") a = i
                if (!a) next
                printf "usr=%s%% sys=%s%% steal=%s%% idle=%s%%", $(a+1), $(a+3), $(a+7), $NF
            }')
        printf '  %s  load=%s  %s\n' "$ts" "$load" "$cpu" | tee -a "$LOG"
        sleep 3
    done
}
t_cpu() {
    sec "1/5" "CPU"
    need stress-ng mpstat || { SUM_CPU="跳過 (缺工具)"; return 1; }
    local n m ops steal
    n=$(getconf _NPROCESSORS_ONLN)
    log "拉滿 $n 核，${DUR}s，方法 all"
    m=$(mark)
    mon_start _mon_cpu
    stress-ng --cpu "$n" --cpu-method all -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop

    # stress-ng --metrics-brief 的資料行:
    #   stress-ng: info:  [23801] cpu   9360   10.03   39.67   0.01   933.17   235.89
    #   $4=stressor $5=bogo ops ...      $(NF-1)=bogo ops/s (real time)
    ops=$(since "$m" | awk '$4=="cpu" && $5 ~ /^[0-9]+$/ {print $(NF-1)}' | tail -1)
    steal=$(since "$m" | grep -oE 'steal=[0-9.]+' | cut -d= -f2 | sort -rn | head -1)
    SUM_CPU="${ops:-?} bogo ops/s (${n} 核)，steal 峰值 ${steal:-?}%"
    # steal 超過幾個百分點就代表 host 上有人在跟你搶 CPU
    if [ -n "$steal" ] && awk -v s="$steal" 'BEGIN{exit !(s > 5)}'; then
        warn "CPU steal 峰值 ${steal}% -> host 超賣，這個 bogo ops 不代表這台 VM 的實力"
    fi
}

# ---------- RAM ----------
_mon_ram() {
    while :; do
        awk '/MemTotal|MemAvailable|SwapFree/{sub(/:$/,"",$1); printf "  %s=%dMB",$1,$2/1024} END{print ""}' \
            /proc/meminfo | tee -a "$LOG"
        sleep 3
    done
}
t_ram() {
    sec "2/5" "RAM"
    need stress-ng || { SUM_RAM="跳過 (缺工具)"; return 1; }
    # 總記憶體的 80%，分 2 個 worker
    local total_mb per_mb m ops minavail
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    per_mb=$(( total_mb * 80 / 100 / 2 ))
    log "總 ${total_mb}MB，2 worker x ${per_mb}MB = $(( per_mb*2 ))MB (80%)"
    m=$(mark)
    mon_start _mon_ram
    stress-ng --vm 2 --vm-bytes "${per_mb}M" --vm-keep -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop

    ops=$(since "$m" | awk '$4=="vm" && $5 ~ /^[0-9]+$/ {print $(NF-1)}' | tail -1)
    minavail=$(since "$m" | grep -oE 'MemAvailable=[0-9]+' | cut -d= -f2 | sort -n | head -1)
    SUM_RAM="${ops:-?} bogo ops/s，配置 $(( per_mb*2 ))MB，最低可用 ${minavail:-?}MB"
    # bogo ops 為 0 不是壞掉，是 DUR 太短跑不完一輪 -- 講清楚免得被當成故障
    if [ "${ops:-1}" = "0" ] || [ "${ops:-1}" = "0.00" ]; then
        SUM_RAM="$SUM_RAM
(bogo ops 0 = ${DUR}s 內跑不完一輪，DUR 加大即可)"
    fi
}

# ---------- SWAP ----------
# 同 _mon_cpu：vmstat 1 2 要等一秒，必須整行組好再印，
# 否則會變成  SwapFree=1583MBstress-ng: info: [22075] dispatching hogs
_mon_swap() {
    local mem swp
    while :; do
        mem=$(awk '/SwapTotal|SwapFree|MemAvailable/{sub(/:$/,"",$1); printf "  %s=%dMB",$1,$2/1024}' /proc/meminfo)
        swp=$(vmstat 1 2 2>/dev/null | awk 'NR==4{printf "  si=%s so=%s",$7,$8}')
        printf '%s%s\n' "$mem" "$swp" | tee -a "$LOG"
        sleep 2
    done
}
t_swap() {
    sec "4/5" "SWAP"
    need stress-ng vmstat || { SUM_SWAP="跳過 (缺工具)"; return 1; }
    local total_mb swap_mb target_mb m p old maxso minavail oom
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb="${swap_mb:-0}"
    [ "$swap_mb" -eq 0 ] && { log "沒有 swap，跳過"; SUM_SWAP="跳過 (這台沒有 swap)"; return; }
    # RAM 的 95% + swap 的 50%，逼出換頁但不至於 OOM
    target_mb=$(( total_mb * 95 / 100 + swap_mb / 2 ))
    log "RAM=${total_mb}MB swap=${swap_mb}MB -> 吃 ${target_mb}MB，逼出換頁"
    log "!! OOM killer 可能出手。另開一個 terminal 跑 dmesg -w 可以即時看到"

    # 保護 sshd 不被 OOM 殺掉。先存原值，測完由 oom_restore 還原。
    OOM_SAVED=""
    for p in $(pgrep -x sshd 2>/dev/null); do
        old=$(cat "/proc/$p/oom_score_adj" 2>/dev/null) || continue
        echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null && OOM_SAVED="$OOM_SAVED $p:$old"
    done
    [ -n "$OOM_SAVED" ] && log "已把 sshd 的 oom_score_adj 設成 -1000 (測完還原)"
    trap 'oom_restore' RETURN

    m=$(mark)
    mon_start _mon_swap
    stress-ng --vm 1 --vm-bytes "${target_mb}M" --vm-keep -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop

    maxso=$(since "$m" | grep -oE 'so=[0-9]+' | cut -d= -f2 | sort -rn | head -1)
    minavail=$(since "$m" | grep -oE 'MemAvailable=[0-9]+' | cut -d= -f2 | sort -n | head -1)

    echo "$THIN" | tee -a "$LOG"
    log "OOM 記錄"
    # 先 grep 再 tail。反過來的話 OOM 之後只要再多幾行 kernel 訊息，記錄就被 tail 切掉了。
    oom=$(dmesg | grep -iE 'oom|killed process' | tail -30)
    if [ -n "$oom" ]; then
        printf '%s\n' "$oom" | sed 's/^/  /' | tee -a "$LOG"
        warn "SWAP 測試期間出現 OOM 記錄，請確認被殺掉的是哪些程序"
        SUM_SWAP="換出峰值 ${maxso:-?} KB/s，最低可用 ${minavail:-?}MB，!! 有 OOM 記錄"
    else
        log "  (無 OOM)"
        SUM_SWAP="換出峰值 ${maxso:-?} KB/s，最低可用 ${minavail:-?}MB，無 OOM"
    fi
}

# ---------- DISK ----------
t_disk() {
    sec "3/5" "DISK"
    need fio || { SUM_DISK="跳過 (缺工具)"; return 1; }
    local avail_mb size mem_mb rt mode out iops bw_str bw p99 punit p99ms line
    avail_mb=$(df -Pm "$DISK_DIR" | awk 'NR==2{print $4}')
    # 測試檔要大於 RAM 才不會被 page cache 整份吃掉；空間不夠就取可用空間的一半
    size=$(( avail_mb / 2 ))
    [ "$size" -gt 4096 ] && size=4096
    [ "$size" -lt 512 ] && { log "$DISK_DIR 只剩 ${avail_mb}MB，空間不足"; SUM_DISK="跳過 (空間不足，只剩 ${avail_mb}MB)"; return 1; }
    log "$DISK_DIR 可用 ${avail_mb}MB -> 測試檔 ${size}MB"
    log "註: direct=1 繞過 guest 的 page cache，但繞不過 KVM host 的"

    # 存全域而不是 local，頂層的 INT/TERM trap 才清得到同一個檔案
    FIO_FILE="$DISK_DIR/.fio-test.$$"
    trap 'rm -f "$FIO_FILE"; FIO_FILE=""; log "已清掉測試檔"' RETURN

    mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    [ "$size" -lt "$mem_mb" ] && warn "測試檔 ${size}MB < RAM ${mem_mb}MB，讀取數據會被 cache 汙染"

    # DUR < 4 時整數除法會得到 0，而 fio 的 --runtime=0 是「不設限」，
    # 配上 --time_based 就永遠跑不完。至少留 1 秒。
    rt=$(( DUR / 4 )); [ "$rt" -lt 1 ] && rt=1
    log "每個模式跑 ${rt}s (DUR 四等分)"
    # 太短的話 iodepth=32 只發得出幾十個 IO，百分位數純粹是雜訊。
    # 不講的話它會安靜地產出看起來很正常、實際沒意義的數字。
    [ "$rt" -lt 5 ] && warn "每個模式只有 ${rt}s，IO 樣本太少，百分位數不具參考價值 (建議 DUR>=240)"

    SUM_DISK=""
    for mode in "randread 隨機讀" "randwrite 隨機寫" "read 循序讀" "write 循序寫"; do
        set -- $mode
        echo "$THIN" | tee -a "$LOG"
        log "$2 ($1)"
        out=$(fio --name="$1" --filename="$FIO_FILE" --size="${size}M" \
            --rw="$1" --bs=$([ "${1#rand}" = "$1" ] && echo 1M || echo 4k) \
            --ioengine=libaio --iodepth=32 --direct=1 \
            --runtime="$rt" --time_based --group_reporting 2>&1)

        # 收 IOPS/BW、平均延遲、以及 p95/p99/p99.99 尾端延遲。
        # 尾端才是重點：共享雲端磁碟的平均值好看，p99 會差兩個數量級。
        # 一定要一起收 "clat percentiles (usec):" 那行 -- fio 會依數值大小自己換單位，
        # 少了它，log 裡的 848 和 3473 長得一模一樣，實際上差 1000 倍。
        printf '%s\n' "$out" \
            | grep -E 'IOPS=|BW=|lat \((usec|msec|nsec)\): min=|percentiles \(|95\.00th|99\.00th|99\.99th' \
            | sed 's/^/  /' | tee -a "$LOG"

        iops=$(printf '%s\n' "$out" | grep -oE 'IOPS=[0-9.]+k?' | head -1 | cut -d= -f2)
        bw_str=$(printf '%s\n' "$out" | grep -oE 'BW=[0-9.]+[KMGT]iB/s' | head -1 | cut -d= -f2)
        # 百分位數的單位由 "clat percentiles (usec):" 決定，不是固定的
        punit=$(printf '%s\n' "$out" | sed -nE 's/.*clat percentiles \((usec|msec|nsec)\).*/\1/p' | head -1)
        p99=$(printf '%s\n' "$out" | sed -nE 's/.*99\.00th=\[[[:space:]]*([0-9]+)\].*/\1/p' | head -1)
        # 統一換算成 ms 才能跨模式比較
        if [ -n "$p99" ] && [ -n "$punit" ]; then
            p99ms=$(awk -v v="$p99" -v u="$punit" 'BEGIN{
                if (u=="usec") v/=1000; else if (u=="nsec") v/=1000000
                printf "%.1fms", v }')
        else
            p99ms="?"
        fi
        line=$(printf '%s  %-8s IOPS  %-12s p99 %s' "$2" "${iops:-?}" "${bw_str:-?}" "$p99ms")

        # host cache 偵測：guest 的 direct=1 繞不過 hypervisor 的 cache。
        # 一般雲端磁碟不可能超過 2GB/s，超過就是在量 host RAM 不是磁碟。
        # fio 依數值大小自己挑單位跟小數位 (BW=48.0MiB/s / BW=3054MiB/s / BW=11.7GiB/s)，
        # 所以要連單位一起抓再換算成 MiB/s。只比對整數 MiB 的話，
        # 高速時 fio 早就改印 GiB/s 了，這個警告永遠不會觸發 -- 正是最需要它的時候。
        bw=$(printf '%s\n' "$out" | grep -oE 'BW=[0-9.]+[KMGT]iB/s' | tail -1 | awk '
            { match($0, /[0-9.]+/); v = substr($0, RSTART, RLENGTH) + 0
              if (/KiB/) v /= 1024; else if (/GiB/) v *= 1024; else if (/TiB/) v *= 1048576
              printf "%d", v }')
        if [ -n "$bw" ] && [ "$bw" -gt 2000 ]; then
            warn "$2 ${bw}MiB/s 超出實體磁碟合理範圍 -> 這是 KVM host 的 cache，此數據無效"
            line="$line   !! 無效 (host cache)"
        fi
        SUM_DISK="${SUM_DISK:+$SUM_DISK
}$line"
    done
}

# ---------- NTP 時間偏移 ----------
NTP_SHIFTED=0
t_ntp() {
    sec "5/5" "NTP"
    need chronyc || { SUM_NTP="跳過 (缺工具)"; return 1; }
    local before after
    before=$(date '+%F %T')
    log "現在時間: $before"
    log "chronyd 狀態: $(systemctl is-active chronyd)"

    # 一定要有還原保險：腳本被 Ctrl-C 也要把時鐘拉回來
    restore_ntp() {
        echo "$THIN" | tee -a "$LOG"
        log "還原"
        # 先把自己撥掉的 2 分鐘扣回來。只靠 chronyc makestep 的話，
        # 機器連不到 NTP 來源時時鐘就一直錯 2 分鐘；這一步是確定性的，不依賴網路。
        # NTP_SHIFTED 擋重入：這個函式若跑兩次就會倒扣 4 分鐘。
        if [ "$NTP_SHIFTED" = "1" ]; then
            NTP_SHIFTED=0
            date -s "-2 minutes" > /dev/null
        fi
        # 不管有沒有撥過時鐘都要把 chronyd 拉回來 -- 上面撥時鐘失敗而提早 return 時，
        # chronyd 已經是停的了。
        systemctl start chronyd 2>/dev/null
        sleep 2
        # 再讓 chronyd 修掉剩下的殘差
        chronyc makestep 2>&1 | sed 's/^/  /' | tee -a "$LOG"
        sleep 3
        log "還原後: $(date '+%F %T')"
        chronyc tracking 2>&1 | grep -E 'System time|Last offset' | sed 's/^/  /' | tee -a "$LOG"
        SUM_NTP="偏移 +2min 觀察 ${DUR}s 後已還原 (現在 $(date '+%T'))"
    }
    # RETURN 管正常結束。INT/TERM 要自己收尾：先關掉 RETURN trap 避免還原跑兩次
    # (Ctrl-C 會中斷 sleep -> 跑 INT handler -> 函式繼續往下 return -> RETURN trap 又觸發)，
    # 而且要自己 exit 130，不然中斷後 exit code 會是 0。
    trap 'restore_ntp' RETURN
    trap 'trap - RETURN; restore_ntp; echo; echo "已中斷，已還原"; report_summary "已中斷"; exit 130' INT TERM

    log "停掉 chronyd (不停的話兩秒後就被拉回，你會以為沒生效)"
    systemctl stop chronyd
    sleep 1

    log "把系統時鐘往前撥 2 分鐘"
    if date -s "+2 minutes" | sed 's/^/  /' | tee -a "$LOG"; then
        NTP_SHIFTED=1
    else
        log "date -s 失敗，取消測試"
        SUM_NTP="失敗 (date -s 沒成功)"
        return 1    # RETURN trap 會把 chronyd 拉回來
    fi
    after=$(date '+%F %T')
    log "偏移後: $after"

    echo "$THIN" | tee -a "$LOG"
    log "觀察 ${DUR}s -- 這期間去看你的應用有沒有異常"
    log "  TLS 憑證驗證 / cron / DB replication / log 時序都可能出事"
    sleep "$DUR"
    # trap RETURN 會自動呼叫 restore_ntp
}

# ==================================================================
#  網路測試 (baseline / traffic / mixed)
# ==================================================================
# 這一組跟本機壓測是不同世界：目標是「主機在扛大量下載流量時，網站還答不答
# 得動」。wrk 打網站、curl 灌下載流量、監看記 CPU/網卡/TCP。

# 逗號分隔的 URL 清單 -> 陣列 _CSV。前後空白會 trim 掉，允許 "a, b" 這種寫法。
# 不用 mapfile (spec 要求相容 bash 4.2 且避免進階用法)。
_split_csv() {
    local IFS=',' raw part
    _CSV=()
    read -ra raw <<< "$1"
    for part in "${raw[@]}"; do
        part="${part#"${part%%[![:space:]]*}"}"    # 去頭部空白
        part="${part%"${part##*[![:space:]]}"}"    # 去尾部空白
        [ -n "$part" ] && _CSV+=("$part")
    done
}

# 全網卡 (排除 lo) 的累計收發位元組。/proc/net/dev 的 "eth0:12345" 冒號可能黏著
# 數字，先把冒號換成空白再切欄。$2=接收位元組，$10=傳送位元組。
# 一定要「永遠輸出兩個數字」-- 呼叫端是 set -- $(_nic_bytes)，空輸出會讓 set -u 炸掉。
_nic_bytes() {
    [ -r /proc/net/dev ] || { echo "0 0"; return; }
    awk '{sub(/:/," ")} NR>2 && $1!="lo" {rx+=$2; tx+=$10} END{print rx+0, tx+0}' /proc/net/dev
}
# /proc/stat 第一行的 CPU 累計時間 -> "總計 閒置"，兩次相減就是這段區間的忙碌比。
_cpu_snap() {
    [ -r /proc/stat ] || { echo "0 0"; return; }
    awk '/^cpu /{idle=$5+$6; t=0; for(i=2;i<=NF;i++) t+=$i; print t, idle; exit}' /proc/stat
}
# bytes/s -> 人看得懂的單位
_hr() {
    awk -v b="${1:-0}" 'BEGIN{ if(b<0)b=0
        if(b>=1048576) printf "%.1fMB/s",b/1048576
        else if(b>=1024) printf "%.0fKB/s",b/1024
        else printf "%dB/s",b }'
}
# 累計 bytes -> 人看得懂的單位 (不是速率)
_hb() {
    awk -v b="${1:-0}" 'BEGIN{ if(b<0)b=0
        if(b>=1073741824) printf "%.2fGB",b/1073741824
        else if(b>=1048576) printf "%.1fMB",b/1048576
        else printf "%.0fKB",b/1024 }'
}

# 網路監看：每 3 秒印一行 CPU/load/可用記憶體/網卡收發/TCP 狀態，
# 同時把原始數字 (drx dtx busy estab tw load) 寫進 $NET_TMP/mon 供事後算峰值。
# 跟 _mon_cpu 一樣，一定要整行組好再印，避免跟 wrk 的輸出交錯。
_mon_net() {
    local prx ptx pt pi nrx ntx nt ni drx dtx busy estab tw load mem
    set -- $(_nic_bytes); prx=$1; ptx=$2
    set -- $(_cpu_snap);  pt=$1; pi=$2
    while :; do
        sleep 3
        set -- $(_nic_bytes); nrx=$1; ntx=$2
        set -- $(_cpu_snap);  nt=$1; ni=$2
        drx=$(( (nrx - prx) / 3 )); dtx=$(( (ntx - ptx) / 3 ))
        busy=$(awk -v a="$pt" -v b="$pi" -v c="$nt" -v d="$ni" \
               'BEGIN{dt=c-a; di=d-b; if(dt>0) printf "%.0f",(dt-di)*100/dt; else print 0}')
        prx=$nrx; ptx=$ntx; pt=$nt; pi=$ni
        load=$(cut -d' ' -f1 /proc/loadavg)
        mem=$(awk '/MemAvailable/{printf "%d",$2/1024; f=1} END{if(!f) print 0}' /proc/meminfo)
        # ss -tan 第一欄是連線狀態；END 一定會跑，所以 ss 不存在時也是印 "0 0"
        set -- $(ss -tan 2>/dev/null | awk 'NR>1{s[$1]++} END{print s["ESTAB"]+0, s["TIME-WAIT"]+0}')
        estab=${1:-0}; tw=${2:-0}
        printf '  %s  cpu=%s%% load=%s  avail=%sMB  rx=%s tx=%s  ESTAB=%s TW=%s\n' \
            "$(date +%H:%M:%S)" "$busy" "$load" "$mem" "$(_hr "$drx")" "$(_hr "$dtx")" "$estab" "$tw" \
            | tee -a "$LOG"
        echo "$drx $dtx $busy $estab $tw $load" >> "$NET_TMP/mon"
    done
}
# _mon_peak <欄號> max|avg -- 從 $NET_TMP/mon 撈某欄的峰值或平均
_mon_peak() {
    [ -s "$NET_TMP/mon" ] || { echo 0; return; }
    awk -v f="$1" -v m="$2" '{v=$f+0; if(m=="max"){if(v>x)x=v} else {s+=v;n++}}
        END{ if(m=="max") print x+0; else printf "%.0f", (n? s/n:0) }' "$NET_TMP/mon"
}

# 單一 curl 下載程序：反覆下載到 /dev/null 直到 deadline，累計下載位元組寫進 sf。
# 每輪覆寫 sf (而非 append)，被 kill 也留得住最後一次的累計值。
_dl_worker() {
    local n="$1" deadline="$2" sf="$3"; shift 3
    local urls=("$@") i=0 total=0 got
    echo 0 > "$sf"
    while [ "$(date +%s)" -lt "$deadline" ]; do
        # 關鍵：不要用 `|| got=0`。大檔 (例如 1GB) 在 --max-time 內下不完時，
        # curl 會以 exit 28 (逾時) 結束 -- 但那 30 秒它其實下載了幾十 MB，而且
        # --write-out 的 size_download 照樣印到 stdout。用 `|| got=0` 會把這些
        # 實際灌出去的流量全部歸零 (Cloud180 實測: 網卡收了 55MB，卻回報下載 21KB)。
        # 逾時本來就是「持續灌流量」的正常狀態，size_download 要照收。
        got=$(curl --location --silent --show-error --connect-timeout 10 --max-time 30 \
                   $CURL_K --output /dev/null --write-out '%{size_download}' \
                   "${urls[$(( i % ${#urls[@]} ))]}" 2>/dev/null)
        case "$got" in ''|*[!0-9]*) got=0 ;; esac
        total=$(( total + got )); i=$(( i + 1 ))
        echo "$total" > "$sf"
    done
}
# 起 DL_WORKERS 個下載程序 (背景)，deadline = 現在 + dur。回傳後 workers 仍在跑。
_dl_start() {
    local dur="$1" deadline w
    _split_csv "$DL_URL"
    [ "${#_CSV[@]}" -ge 1 ] || { warn "DL_URL 解析後沒有有效來源"; return 1; }
    deadline=$(( $(date +%s) + dur ))
    DL_PIDS=""
    for w in $(seq 1 "$DL_WORKERS"); do
        _dl_worker "$w" "$deadline" "$NET_TMP/dl.$w" "${_CSV[@]}" &
        DL_PIDS="$DL_PIDS $!"
    done
    log "已啟動 ${DL_WORKERS} 個 curl 下載程序 (來源 ${#_CSV[@]} 個)"
}
# 等所有下載程序自然結束 (它們會在 deadline 自己停，最後一輪 curl 受 --max-time 30 上限)
_dl_stop() {
    local p
    for p in $DL_PIDS; do wait "$p" 2>/dev/null; done
    DL_PIDS=""
}
# 加總所有 worker 的下載位元組
_dl_bytes() {
    local sum=0 f v
    for f in "$NET_TMP"/dl.*; do
        [ -e "$f" ] || continue
        v=$(cat "$f" 2>/dev/null); case "$v" in ''|*[!0-9]*) v=0 ;; esac
        sum=$(( sum + v ))
    done
    echo "$sum"
}

# 收尾：算網卡平均接收 (存進 NET_AVG_RX) 與系統峰值 (填 SUM_SYS)，順便觸發警告。
NET_AVG_RX=0
_net_finish() {
    local rxs="$1" t0="$2" rxe secs pkrx pkcpu pkload pkestab pktw
    set -- $(_nic_bytes); rxe=$1
    secs=$(( $(date +%s) - t0 )); [ "$secs" -lt 1 ] && secs=1
    NET_AVG_RX=$(( (rxe - rxs) / secs ))
    pkrx=$(_mon_peak 1 max); pkcpu=$(_mon_peak 3 max); pkload=$(_mon_peak 6 max)
    pkestab=$(_mon_peak 4 max); pktw=$(_mon_peak 5 max)
    SUM_SYS="CPU 峰值 ${pkcpu}%，load 峰值 ${pkload}，接收峰值 $(_hr "$pkrx")，ESTAB 峰值 ${pkestab}，TIME-WAIT 峰值 ${pktw}"
    [ "$pkcpu" -ge 95 ] 2>/dev/null && \
        warn "CPU 忙碌峰值 ${pkcpu}% -> 網路吞吐可能卡在 CPU (軟中斷/單一佇列)，不是頻寬"
    [ "$pktw" -gt 20000 ] 2>/dev/null && \
        warn "TIME-WAIT 峰值 ${pktw} -> 短連線恐耗盡來源埠，看 net.ipv4.ip_local_port_range / tcp_tw_reuse"
}

# 跑一輪 wrk 並解析結果，填 SUM_WRK。
_wrk_run() {
    local dur="$1" out rps p99 nonx serr xfer
    local args=(-t"$WRK_THREADS" -c"$WRK_CONNS" -d"${dur}s" --latency -H "User-Agent: $UA")
    [ -n "$HOST_HEADER" ] && args+=(-H "Host: $HOST_HEADER")
    log "wrk -t${WRK_THREADS} -c${WRK_CONNS} -d${dur}s --latency $URL"
    out=$(wrk "${args[@]}" "$URL" 2>&1)
    printf '%s\n' "$out" | sed 's/^/  /' | tee -a "$LOG"

    rps=$(printf '%s\n'  "$out" | awk '/^Requests\/sec/{print $2}')
    xfer=$(printf '%s\n' "$out" | awk '/^Transfer\/sec/{print $2}')
    p99=$(printf '%s\n'  "$out" | awk '/Latency Distribution/{f=1} f&&/99%/{print $2; exit}')
    nonx=$(printf '%s\n' "$out" | awk '/Non-2xx or 3xx/{print $NF}')
    serr=$(printf '%s\n' "$out" | grep 'Socket errors' | sed 's/^ *//')

    SUM_WRK="Requests/sec ${rps:-?}，p99 延遲 ${p99:-?}，傳輸 ${xfer:-?}"
    [ -n "$nonx" ] && SUM_WRK="${SUM_WRK}，非 2xx/3xx ${nonx}"
    if [ -n "$nonx" ] && [ "$nonx" -gt 0 ] 2>/dev/null; then
        warn "wrk 收到 ${nonx} 個非 2xx/3xx 回應 -> 網站在壓力下開始回錯誤"
    fi
    [ -n "$serr" ] && warn "wrk $serr"
    [ -z "$rps" ] && warn "wrk 沒解析到 Requests/sec -> 可能連線失敗或 URL 打不通 (詳見上方本文)"
}

# 建立網路測試的暫存目錄。只負責 mktemp -- RETURN 清理必須由呼叫端的
# t_* 自己掛，因為 RETURN trap 是「誰返回誰觸發」：掛在這裡的話，_net_setup
# 一 return 就把剛建好的目錄刪了。這正是 t_disk/t_swap 把 trap 寫在自己
# 函式裡而不是抽出來的原因。
_net_setup() {
    NET_TMP=$(mktemp -d "${TMPDIR:-/tmp}/st-net.XXXXXX") || { log "無法建立暫存目錄"; return 1; }
}
# 統一的網路測試清理 trap 內容。t_* 用 trap "$NET_CLEANUP" RETURN 掛上。
# 正常返回收乾淨；中斷走頂層 INT/TERM (同樣清 DL_PIDS 與 NET_TMP)。
NET_CLEANUP='kill $DL_PIDS 2>/dev/null; DL_PIDS=""; rm -rf "$NET_TMP"; NET_TMP=""'

# ---------- baseline: 只跑 wrk，建立無干擾基準 ----------
t_baseline() {
    sec "1/1" "BASELINE  (wrk 網站基準，無下載干擾)"
    need wrk || { SUM_WRK="跳過 (缺工具)"; return 1; }
    _net_setup || { SUM_WRK="跳過 (暫存目錄建立失敗)"; return 1; }
    trap "$NET_CLEANUP" RETURN
    local rxs t0
    log "建立網站效能基準 -- 這組數字之後拿來跟 mixed 對照"
    set -- $(_nic_bytes); rxs=$1; t0=$(date +%s)
    mon_start _mon_net
    _wrk_run "$DUR"
    mon_stop
    _net_finish "$rxs" "$t0"
}

# ---------- traffic: 只跑 curl 下載，拉高接收流量 ----------
t_traffic() {
    sec "1/1" "TRAFFIC  (curl 下載流量)"
    need curl || { SUM_DL="跳過 (缺工具)"; return 1; }
    _net_setup || { SUM_DL="跳過 (暫存目錄建立失敗)"; return 1; }
    trap "$NET_CLEANUP" RETURN
    local rxs t0 bytes
    log "拉高下載流量 ${DUR}s，觀察單機可達的接收流量與 CPU/TCP"
    set -- $(_nic_bytes); rxs=$1; t0=$(date +%s)
    mon_start _mon_net
    _dl_start "$DUR" || { mon_stop; SUM_DL="失敗 (下載程序沒起來)"; return 1; }
    sleep "$DUR"
    _dl_stop
    mon_stop
    _net_finish "$rxs" "$t0"
    bytes=$(_dl_bytes)
    SUM_DL="網卡平均接收 $(_hr "$NET_AVG_RX")，curl 實際下載 $(_hb "$bytes") (${DL_WORKERS} workers)"
}

# ---------- mixed: 下載流量 + 網站壓測同時 ----------
t_mixed() {
    sec "1/1" "MIXED  (下載流量 + 網站壓測同時進行)"
    need wrk curl || { SUM_WRK="跳過 (缺工具)"; SUM_DL="跳過 (缺工具)"; return 1; }
    _net_setup || { SUM_WRK="跳過 (暫存目錄建立失敗)"; SUM_DL="跳過"; return 1; }
    trap "$NET_CLEANUP" RETURN
    local rxs t0 bytes
    log "先起下載流量，再壓網站，兩者同時進行 ${DUR}s"
    log "把這裡的 Requests/sec 跟單獨 baseline 的數字比，就是流量壓力下的掉幅"
    set -- $(_nic_bytes); rxs=$1; t0=$(date +%s)
    mon_start _mon_net
    _dl_start "$DUR" || log "下載程序沒起來，改成純 wrk"
    _wrk_run "$DUR"      # 前景跑 DUR 秒，期間 curl 在背景同時灌下載流量
    _dl_stop
    mon_stop
    _net_finish "$rxs" "$t0"
    bytes=$(_dl_bytes)
    SUM_DL="網卡平均接收 $(_hr "$NET_AVG_RX")，curl 實際下載 $(_hb "$bytes")"
}

# ---------- 主 ----------
# 先驗參數再決定報告檔名，打錯字不該留下一個空報告
case "${1:-}" in
    cpu|ram|disk|swap|ntp|all) CMD="$1"; SUITE="local" ;;
    baseline|traffic|mixed)    CMD="$1"; SUITE="net" ;;
    *) usage; exit 2 ;;
esac

# 網路模式的目標是必填 -- 缺了就明講缺哪個環境變數，不要跑到報告開頭才失敗
if [ "$SUITE" = "net" ]; then
    case "$CMD" in
        baseline) [ -n "$URL" ] || { echo "baseline 需要 URL，例: URL=https://你的網站/ ... baseline"; exit 2; } ;;
        traffic)  [ -n "$DL_URL" ] || { echo "traffic 需要 DL_URL，例: DL_URL=https://授權來源/big.bin ... traffic"; exit 2; } ;;
        mixed)    { [ -n "$URL" ] && [ -n "$DL_URL" ]; } || { echo "mixed 需要 URL 與 DL_URL 兩者"; exit 2; } ;;
    esac
fi

LOG="$LOGDIR/$CMD-$TS.log"
report_head "$CMD"

case "$CMD" in
    cpu)   t_cpu ;;
    ram)   t_ram ;;
    disk)  t_disk ;;
    swap)  t_swap ;;
    ntp)   t_ntp ;;
    # 順序固定 CPU -> RAM -> DISK -> SWAP。ntp 不含在內：時鐘是全機共用的狀態，
    # 順手跑掉風險太高，要測就自己單獨跑。
    all)   t_cpu; t_ram; t_disk; t_swap ;;
    baseline) t_baseline ;;
    traffic)  t_traffic ;;
    mixed)    t_mixed ;;
esac

report_summary
