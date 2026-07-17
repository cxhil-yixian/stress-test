#!/usr/bin/env bash
# stress-test.sh -- 壓力測試 (CentOS 7.9 / KVM VM)
#
# 用法:
#   ./stress-test.sh cpu           CPU 壓測
#   ./stress-test.sh ram           記憶體壓測
#   ./stress-test.sh disk          磁碟讀寫
#   ./stress-test.sh swap          SWAP 壓測
#   ./stress-test.sh ntp           NTP 時間偏移 2 分鐘
#   ./stress-test.sh all           以上全跑
#
# 參數:
#   DUR=60            每項持續秒數
#   DISK_DIR=./logs   fio 測試檔位置 (測完自動刪除)
#
# log 都在 ./logs/

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DUR="${DUR:-60}"
LOGDIR="./logs"; mkdir -p "$LOGDIR"
# fio 測試檔預設就寫在 logs/ 裡，跑完由 trap 刪掉。
# 注意這跟 /tmp 在同一個檔案系統時，數據不會有差別。
DISK_DIR="${DISK_DIR:-$LOGDIR}"; mkdir -p "$DISK_DIR"
TS=$(date +%Y%m%d-%H%M%S)

[ "$(id -u)" = "0" ] || { echo "要 root"; exit 1; }

# fio 測試檔的路徑存成全域，讓中斷時的 trap 也清得到。
# t_disk 自己的 RETURN trap 只在正常返回時觸發，Ctrl-C 走的是下面這條，
# 不處理的話會留一個 1.4GB 的檔案在 logs/ 裡。
FIO_FILE=""

# 腳本被 Ctrl-C / kill 時：收掉背景監看 + 清掉測試檔
trap 'mon_stop 2>/dev/null; [ -n "$FIO_FILE" ] && rm -f "$FIO_FILE"; echo; echo "已中斷，已清理"; exit 130' INT TERM

# 掃掉上次沒清乾淨的殘骸 (例如被 kill -9)
for _stale in "$LOGDIR"/.fio-test.*; do
    [ -e "$_stale" ] || continue
    echo "清掉上次殘留的測試檔: $_stale ($(du -h "$_stale" 2>/dev/null | cut -f1))"
    rm -f "$_stale"
done

# 缺工具時給明確訊息，而不是讓它噴 command not found
need() {
    local miss=""
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
    [ -z "$miss" ] && return 0
    echo "缺少工具:$miss"
    echo "  yum install -y fio sysstat stress-ng"
    return 1
}

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
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
    # disown 之後不能再 wait 它，但我們用 kill -9 直接確保它死透，不需要 wait。
    disown "$MON_PID" 2>/dev/null || true
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
        cpu=$(mpstat 1 1 2>/dev/null | awk '/Average|平均/{printf "usr=%s%% sys=%s%% idle=%s%%",$3,$5,$NF}')
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
    [ "$swap_mb" -eq 0 ] && { log "沒有 swap，跳過"; return; }
    # RAM 的 95% + swap 的 50%，逼出換頁但不至於 OOM
    target_mb=$(( total_mb * 95 / 100 + swap_mb / 2 ))
    log "RAM=${total_mb}MB swap=${swap_mb}MB -> 吃 ${target_mb}MB，逼出換頁"
    log "!! OOM killer 可能出手。監看: dmesg -w"

    # 保護 sshd 不被 OOM 殺掉
    for p in $(pgrep -x sshd 2>/dev/null); do echo -1000 > /proc/$p/oom_score_adj 2>/dev/null; done
    log "已把 sshd 的 oom_score_adj 設成 -1000"

    mon_start _mon_swap
    stress-ng --vm 1 --vm-bytes "${target_mb}M" --vm-keep -t "${DUR}s" --metrics-brief 2>&1 | tee -a "$LOG"
    mon_stop

    log "--- OOM 記錄 ---"
    dmesg | tail -30 | grep -iE 'oom|killed process' | tee -a "$LOG" || log "(無 OOM)"
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

    local f="$DISK_DIR/.fio-test.$$"
    FIO_FILE="$f"
    trap 'rm -f "$f"; FIO_FILE=""; log "已清掉測試檔"' RETURN

    local mem_mb; mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
    if [ "$size" -lt "$mem_mb" ]; then
        log "!! 測試檔 ${size}MB < RAM ${mem_mb}MB，讀取數據會被 cache 汙染"
    fi

    for mode in "randread 隨機讀" "randwrite 隨機寫" "read 循序讀" "write 循序寫"; do
        set -- $mode
        log "--- $2 ($1) ---"
        # 收 IOPS/BW、平均延遲、以及 p95/p99/p99.99 尾端延遲。
        # 尾端才是重點：共享雲端磁碟的平均值好看，p99 會差兩個數量級。
        fio --name="$1" --filename="$f" --size="${size}M" \
            --rw="$1" --bs=$([ "${1#rand}" = "$1" ] && echo 1M || echo 4k) \
            --ioengine=libaio --iodepth=32 --direct=1 \
            --runtime=$(( DUR / 4 )) --time_based --group_reporting \
            2>&1 | grep -E 'IOPS=|BW=|lat \((usec|msec|nsec)\): min=|95\.00th|99\.00th|99\.99th' \
            | sed 's/^/  /' | tee -a "$LOG"

        # host cache 偵測：guest 的 direct=1 繞不過 hypervisor 的 cache。
        # 一般雲端磁碟不可能超過 2GB/s，超過就是在量 host RAM 不是磁碟。
        local bw; bw=$(grep -oE 'BW=[0-9]+MiB/s' "$LOG" | tail -1 | grep -oE '[0-9]+')
        if [ -n "$bw" ] && [ "$bw" -gt 2000 ]; then
            log "  !! ${bw}MiB/s 超出實體磁碟合理範圍 -> 這是 KVM host 的 cache，此數據無效"
        fi
    done
    log "完成 -> $LOG"
    log "註: VM 內的讀取數據普遍不可信 (host cache)，以寫入的 p99 尾端延遲為準"
}

# ---------- NTP 時間偏移 ----------
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
        systemctl start chronyd 2>/dev/null
        sleep 2
        chronyc makestep 2>&1 | sed 's/^/  /' | tee -a "$LOG"
        sleep 3
        log "還原後: $(date '+%F %T')"
        chronyc tracking 2>&1 | grep -E 'System time|Last offset' | sed 's/^/  /' | tee -a "$LOG"
    }
    trap 'restore_ntp' RETURN INT TERM

    log "停掉 chronyd (不停的話兩秒後就被拉回，你會以為沒生效)"
    systemctl stop chronyd
    sleep 1

    log "把系統時鐘往前撥 2 分鐘"
    date -s "+2 minutes" | sed 's/^/  /' | tee -a "$LOG"
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
    *)  sed -n '2,16p' "$0"; exit 2 ;;
esac
