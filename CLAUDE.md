# CLAUDE.md

## 專案概要

單檔 Bash 腳本 `stress-test.sh`，在 CentOS 7.9 / KVM 虛擬機上跑 CPU、RAM、磁碟、SWAP、NTP 五種壓力測試。沒有建置流程、沒有相依套件管理、沒有測試框架 —— 就是一支腳本。

目標平台是 **CentOS 7.9**，即 Bash 4.2 + systemd + yum。不要用 Bash 5 才有的語法（`${var@Q}`、關聯陣列的 `-A` 進階用法等）。

## 語言

程式碼註解、log 輸出、文件全部使用**繁體中文**。與使用者溝通也用繁體中文。錯誤訊息維持既有的簡短口語風格（例：`要 root`、`缺少工具:`）。

## 開發與驗證

**這支腳本無法在開發機（Windows）上執行。** 任何修改都只能靠靜態檢查驗證：

```bash
bash -n stress-test.sh      # 語法檢查
shellcheck stress-test.sh   # 若可用
```

實際行為驗證必須在 CentOS VM 上以 root 執行。**不要聲稱改動「已測試通過」** —— 說明你做了哪些靜態檢查，以及需要在 VM 上驗證什麼。

跑真實測試時務必用小的 `DUR`（例如 `DUR=10`）先確認流程，不要一開始就跑滿 60 秒。

## 這支腳本的設計慣例

修改時務必保留以下不變量，它們都是踩過坑才寫成現在這樣的（腳本內有註解說明原因，別把註解一起刪了）：

1. **背景監看必須是單一函式丟背景，不能接 pipeline。**
   `func &` 的 `$!` 才是該函式本人；`( ... ) | sed | tee &` 拿到的是 `tee` 的 PID，而且中間的 pipe 會區塊緩衝導致輸出延遲數分鐘。`tee` 要放在監看迴圈**裡面**。

2. **監看函式裡要「整行組好再 printf」。**
   `mpstat 1 1` / `vmstat 1 2` 都要等一秒才回來。先印前半段再等它，stress-ng 的輸出會插進來把行切斷。

3. **停監看用 `_killtree` 遞迴殺，先父後子。**
   `pkill -P` 只殺直接子程序會漏掉孫程序；先殺子再殺父會讓存活的父程序噴 job control 訊息到 stderr。`mon_start` 已 `disown`，所以不能也不需要 `wait`。

4. **每個會留下副作用的操作都要有還原保險，涵蓋 Ctrl-C，而且要可重入。**
   - fio 測試檔：`RETURN` trap（正常返回）+ 全域 `FIO_FILE` 搭配頂層 `INT`/`TERM` trap（中斷）+ 啟動時掃除殘骸（`kill -9` 的漏網之魚）。這三層缺一不可。
   - NTP 時鐘：`restore_ntp` 掛在 `RETURN`，另有獨立的 `INT`/`TERM` handler。
   - sshd 的 `oom_score_adj`：`OOM_SAVED` 存原值，`oom_restore` 掛在 `t_swap` 的 `RETURN` 與頂層 `INT`/`TERM`。

   **在函式裡同時掛 `RETURN` 與 `INT` 時要當心跑兩次**：Ctrl-C 中斷 `sleep` 後，INT handler 執行完，函式仍會繼續往下 return 而再觸發 RETURN trap。所以 INT handler 必須 `trap - RETURN` 再自行 `exit 130`。還原函式本身也要用旗標（如 `NTP_SHIFTED`）擋重入 —— `date -s "-2 minutes"` 跑兩次就是倒扣 4 分鐘。

5. **還原要確定性，不要依賴外部條件。**
   時鐘還原先 `date -s "-2 minutes"` 扣回自己撥掉的量，再用 `chronyc makestep` 修殘差。只靠 makestep 的話，機器連不到 NTP 來源時時鐘就一直是錯的。

6. **資料可信度警告不能拿掉，而且要確認它真的會觸發。**
   VM 裡的磁碟數據本來就不可信 —— guest 的 `direct=1` 繞不過 hypervisor 的 cache。頻寬 > 2GB/s 判定為 host cache、測試檔 < RAM 判定為 page cache 汙染，這兩個警告是這支腳本的價值所在。結論一律以**寫入的 p99 尾端延遲**為準。

   解析 fio 輸出時記得它會依數值大小自己挑單位與小數位（`BW=48.0MiB/s`、`BW=3054MiB/s`、`BW=11.7GiB/s`），必須連單位一起處理。曾經因為只比對整數 MiB/s，導致高速（fio 改印 GiB/s）時警告完全不觸發 —— 剛好是最需要它的場合。**靜靜不觸發的檢查比沒有檢查更糟。**

7. **`%steal` 是 KVM guest 的核心指標**，不要為了精簡輸出把它拿掉。mpstat 的欄位順序跨版本會變，所以 `_mon_cpu` 從表頭找欄號，找不到才退回寫死的位置。

8. **新增測試項目時的模式：**
   `need <工具...> || return 1` → `head_ <名稱>` → `log` 說明參數 → `mon_start _mon_xxx` → 主壓測（`2>&1 | tee -a "$LOG"`）→ `mon_stop` → `log "完成 -> $LOG"`。同時更新頂部的用法註解區塊與 `case` 分支即可 —— `usage()` 會自動擷取 shebang 之後、第一個非註解行之前的內容，不需要同步任何行號。

## 文件同步

改動行為時，記得同步更新 `README.md` 與 `CHANGELOG.md`（Keep a Changelog 格式，新變更放在 `[未發布]` 之下）。
