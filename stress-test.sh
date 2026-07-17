#!/usr/bin/env bash
#
# stress-test.sh -- 壓力測試 (CentOS 7.9 / KVM VM)
#
# 用法說明見下面的 usage()，或不帶參數直接執行。
#
# 腳本刻意不 cd 到自己所在的目錄：測試產物 (log、fio 測試檔) 都落在
# 「你執行時所在的目錄」底下的 logs/，跟腳本放在哪無關。要換地方就 cd 過去再跑。

set -uo pipefail

# 用法說明寫成字串常數，不要回頭讀腳本自己。
# bash <(curl -fsSL ...) 這類跑法餵給 bash 的是一次性的 pipe (/dev/fd/63)，
# bash 讀完腳本後它就到 EOF 了，回頭讀只會拿到空字串 --
# 而「參數打錯」正是最需要用法說明的時候。
usage() {
    cat <<'EOF'
用法:
  stress-test.sh cpu           CPU 壓測
  stress-test.sh ram           記憶體壓測
  stress-test.sh disk          磁碟讀寫
  stress-test.sh swap          SWAP 壓測
  stress-test.sh ntp           NTP 時間偏移 2 分鐘
  stress-test.sh all           以上全跑 (不含 ntp)

參數:
  DUR=60            每項持續秒數
  DISK_DIR=./logs   fio 測試檔位置 (測完自動刪除)

不落地直接跑 (參數要接在 <(...) 之後):
  bash <(curl -fsSL https://raw.githubusercontent.com/cxhil-yixian/stress-test/main/stress-test.sh) cpu

測試產物都落在你執行時所在的目錄底下的 logs/。
EOF
    # LOGDIR 在下面才建立，這裡用預設值擋著 set -u
    echo "這次的輸出會寫到: ${LOGDIR:-<尚未建立>}"
}

# 先驗身分再建目錄，不然非 root 執行會留下一個空的 logs/ 才跟你說不能跑
[ "$(id -u)" = "0" ] || { echo "要 root"; exit 1; }

DUR="${DUR:-60}"
# DUR 會進到算術展開跟 fio --runtime，非數字的話錯誤訊息會很難懂，先擋掉
case "$DUR" in ''|*[!0-9]*) echo "DUR 要是正整數，收到: $DUR"; exit 2 ;; esac
[ "$DUR" -ge 1 ] || { echo "DUR 要 >= 1"; exit 2; }

# 相對於 CWD 建立，再轉成絕對路徑存起來。
# 轉絕對路徑有兩個好處：log 裡印出的路徑不會有「這是相對誰」的疑問，
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

# fio 測試檔的路徑存成全域，讓中斷時的 trap 也清得到。
# t_disk 自己的 RETURN trap 只在正常返回時觸發，Ctrl-C 走的是下面這條，
# 不處理的話會留一個 1.4GB 的檔案在 logs/ 裡。
FIO_FILE=""
# t_swap 動過的 sshd oom_score_adj，格式 "pid:原值 pid:原值"
OOM_SAVED=""

# 腳本被 Ctrl-C / kill 時：收掉背景監看 + 還原 oom_score_adj + 清掉測試檔
trap 'mon_stop 2>/dev/null; oom_restore 2>/dev/null; [ -n "$FIO_FILE" ] && rm -f "$FIO_FILE"; echo; echo "已中斷，已清理"; exit 130' INT TERM

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
    local miss=""
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
    [ -z "$miss" ] && return 0
    echo "缺少工具:$miss"
    echo "  yum install -y fio sysstat stress-ng chrony"
    return 1
}

# LOG 要到 head_ 才建立。中斷 trap 可能在那之前就呼叫到 log()，
# 這時 set -u 會讓整個 trap 炸掉，所以給個預設值。
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "${LOG:-/dev/null}"; }
head_() { LOG="$LOGDIR/$1-$TS.log"; echo "=== $1 壓測 / $(date) / ${DUR}s ===" | tee "$LOG"; }

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
    need stress-ng mpstat || return 1
    head_ cpu
    local n; n=$(getconf _NPROCESSORS_ONLN)
    log "拉滿 $n 核，${DUR}s"
    mon_start _mon_cpu
    stress-ng --cpu "$n" --cpu-method all -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop
    log "完成 -> $LOG"
    log "註: steal 若持續 >0，代表 host 超賣，bogo ops 低不是這台 VM 的問題"
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
    need stress-ng || return 1
    head_ ram
    # 總記憶體的 80%，分 2 個 worker
    local total_mb per_mb
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    per_mb=$(( total_mb * 80 / 100 / 2 ))
    log "總 ${total_mb}MB，2 worker x ${per_mb}MB = $(( per_mb*2 ))MB (80%)"
    mon_start _mon_ram
    stress-ng --vm 2 --vm-bytes "${per_mb}M" --vm-keep -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop
    log "完成 -> $LOG"
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
    need stress-ng vmstat || return 1
    head_ swap
    local total_mb swap_mb target_mb
    total_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
    swap_mb="${swap_mb:-0}"
    [ "$swap_mb" -eq 0 ] && { log "沒有 swap，跳過"; return; }
    # RAM 的 95% + swap 的 50%，逼出換頁但不至於 OOM
    target_mb=$(( total_mb * 95 / 100 + swap_mb / 2 ))
    log "RAM=${total_mb}MB swap=${swap_mb}MB -> 吃 ${target_mb}MB，逼出換頁"
    log "!! OOM killer 可能出手。監看: dmesg -w"

    # 保護 sshd 不被 OOM 殺掉。先存原值，測完由 oom_restore 還原。
    local p old
    OOM_SAVED=""
    for p in $(pgrep -x sshd 2>/dev/null); do
        old=$(cat "/proc/$p/oom_score_adj" 2>/dev/null) || continue
        echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null && OOM_SAVED="$OOM_SAVED $p:$old"
    done
    [ -n "$OOM_SAVED" ] && log "已把 sshd 的 oom_score_adj 設成 -1000 (測完還原)"
    trap 'oom_restore' RETURN

    mon_start _mon_swap
    stress-ng --vm 1 --vm-bytes "${target_mb}M" --vm-keep -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop

    log "--- OOM 記錄 ---"
    # 先 grep 再 tail。反過來的話 OOM 之後只要再多幾行 kernel 訊息，記錄就被 tail 切掉了。
    dmesg | grep -iE 'oom|killed process' | tail -30 | tee -a "$LOG" || log "(無 OOM)"
    log "完成 -> $LOG"
}

# ---------- DISK ----------
t_disk() {
    need fio || return 1
    head_ disk
    local avail_mb size
    avail_mb=$(df -Pm "$DISK_DIR" | awk 'NR==2{print $4}')
    # 測試檔要大於 RAM 才不會被 page cache 整份吃掉；空間不夠就取可用空間的一半
    size=$(( avail_mb / 2 ))
    [ "$size" -gt 4096 ] && size=4096
    [ "$size" -lt 512 ] && { log "$DISK_DIR 只剩 ${avail_mb}MB，空間不足"; return 1; }
    log "$DISK_DIR 可用 ${avail_mb}MB -> 測試檔 ${size}MB"
    log "註: direct=1 繞過 page cache，量的是真實磁碟"

    # 存全域而不是 local，頂層的 INT/TERM trap 才清得到同一個檔案
    FIO_FILE="$DISK_DIR/.fio-test.$$"
    trap 'rm -f "$FIO_FILE"; FIO_FILE=""; log "已清掉測試檔"' RETURN

    local mem_mb; mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if [ "$size" -lt "$mem_mb" ]; then
        log "!! 測試檔 ${size}MB < RAM ${mem_mb}MB，讀取數據會被 cache 汙染"
    fi

    # DUR < 4 時整數除法會得到 0，而 fio 的 --runtime=0 是「不設限」，
    # 配上 --time_based 就永遠跑不完。至少留 1 秒。
    local rt=$(( DUR / 4 )); [ "$rt" -lt 1 ] && rt=1

    local mode out bw
    for mode in "randread 隨機讀" "randwrite 隨機寫" "read 循序讀" "write 循序寫"; do
        set -- $mode
        log "--- $2 ($1) ---"
        out=$(fio --name="$1" --filename="$FIO_FILE" --size="${size}M" \
            --rw="$1" --bs=$([ "${1#rand}" = "$1" ] && echo 1M || echo 4k) \
            --ioengine=libaio --iodepth=32 --direct=1 \
            --runtime="$rt" --time_based --group_reporting 2>&1)

        # 收 IOPS/BW、平均延遲、以及 p95/p99/p99.99 尾端延遲。
        # 尾端才是重點：共享雲端磁碟的平均值好看，p99 會差兩個數量級。
        printf '%s\n' "$out" \
            | grep -E 'IOPS=|BW=|lat \((usec|msec|nsec)\): min=|95\.00th|99\.00th|99\.99th' \
            | sed 's/^/  /' | tee -a "$LOG"

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
            log "  !! ${bw}MiB/s 超出實體磁碟合理範圍 -> 這是 KVM host 的 cache，此數據無效"
        fi
    done
    log "完成 -> $LOG"
    log "註: VM 內的讀取數據普遍不可信 (host cache)，以寫入的 p99 尾端延遲為準"
}

# ---------- NTP 時間偏移 ----------
NTP_SHIFTED=0
t_ntp() {
    need chronyc || return 1
    head_ ntp
    local before after
    before=$(date '+%F %T')
    log "現在時間: $before"
    log "chronyd 狀態: $(systemctl is-active chronyd)"

    # 一定要有還原保險：腳本被 Ctrl-C 也要把時鐘拉回來
    restore_ntp() {
        log "--- 還原 ---"
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
    }
    # RETURN 管正常結束。INT/TERM 要自己收尾：先關掉 RETURN trap 避免還原跑兩次
    # (Ctrl-C 會中斷 sleep -> 跑 INT handler -> 函式繼續往下 return -> RETURN trap 又觸發)，
    # 而且要自己 exit 130，不然中斷後 exit code 會是 0。
    trap 'restore_ntp' RETURN
    trap 'trap - RETURN; restore_ntp; echo; echo "已中斷，已還原"; exit 130' INT TERM

    log "停掉 chronyd (不停的話兩秒後就被拉回，你會以為沒生效)"
    systemctl stop chronyd
    sleep 1

    log "把系統時鐘往前撥 2 分鐘"
    if date -s "+2 minutes" | sed 's/^/  /' | tee -a "$LOG"; then
        NTP_SHIFTED=1
    else
        log "date -s 失敗，取消測試"
        return 1    # RETURN trap 會把 chronyd 拉回來
    fi
    after=$(date '+%F %T')
    log "偏移後: $after"

    log "--- 觀察 ${DUR}s，這期間去看你的應用有沒有異常 ---"
    log "    (TLS 憑證驗證 / cron / DB replication / log 時序都可能出事)"
    sleep "$DUR"
    # trap RETURN 會自動呼叫 restore_ntp
}

# ---------- 主 ----------
case "${1:-}" in
    cpu)   t_cpu ;;
    ram)   t_ram ;;
    disk)  t_disk ;;
    swap)  t_swap ;;
    ntp)   t_ntp ;;
    all)   t_cpu; t_ram; t_disk; t_swap ;;
    *)  usage; exit 2 ;;
esac
