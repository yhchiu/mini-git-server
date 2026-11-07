# 伺服器維運

[English](../operations.md) | **繁體中文**

這些指令以 root 身分在 Git 伺服器上執行。`remote-install` 會把腳本放在
`/usr/local/sbin/mini-git-server.sh`，該路徑在 root 的 PATH 上。

- [健康檢查](#健康檢查)
- [備份](#備份)
- [SSH 連線數限制](#ssh-連線數限制)
- [維運規則](#維運規則)

伺服器主機金鑰請看[安裝](install.md#伺服器主機金鑰)，變更儲存庫的預設分支請看
[存取控制](access-control.md#預設分支)。

## 健康檢查

```bash
sudo ./mini-git-server.sh status
sudo ./mini-git-server.sh doctor
sudo ./mini-git-server.sh fsck
```

| 指令 | 用途 |
|---|---|
| `status` | Git、Gitolite 和 SSH 的狀態，包含實際生效的 sshd 連接埠、`MaxStartups`，以及託管帳號設定的 Git 預設分支 |
| `doctor` | 設定與權限檢查；回報 `[ OK ]`、`[WARN]` 和 `[FAIL]` 行 |
| `fsck` | 對託管的儲存庫執行 `git fsck`；`--repo project-x` 只檢查一個 |

請以 root 執行 `status`：沒有 root 權限時它會說明這一點，只有 root 能讀取的欄位（例如
sshd 連接埠和預設分支）會顯示 `(needs root)`，而不是用猜的。

## 備份

建立以 Git 鏡像方式進行的備份：

```bash
sudo ./mini-git-server.sh backup
```

預設的備份位置：

```text
/var/backups/gitolite/YYYYMMDD-HHMMSS/
```

腳本會對每個儲存庫使用 `git clone --mirror file://...`，並對備份執行 `git fsck`。它也會
保存相關的 Gitolite 和 sshd 設定資訊，包含受管理的 SSH 連接埠設定片段。

儲存庫的擁有者是託管帳號，而 Git 會拒絕開啟屬於其他使用者的儲存庫（"detected dubious
ownership"）。因此備份會透過以託管帳號執行的 `git upload-pack` 讀取每個儲存庫。root 只
負責寫入和檢查新的鏡像，鏡像的擁有者是 root。

> [!IMPORTANT]
> 為了災難復原，請在另一個系統上保留有版本管理、離線，或其他方式獨立的副本。

## SSH 連線數限制

預設情況下，只要有 10 個連線正在等待登入，sshd 就會開始隨機拒絕新連線
（`MaxStartups 10:30:100`）。如果許多 agent 同時 fetch，有些出現 "Connection closed"
失敗，請提高上限：

```bash
sudo ./mini-git-server.sh ssh-limits --max-startups 50:30:200
```

`ssh-limits` 會寫入 `/etc/ssh/sshd_config.d/99-gitolite-limits.conf`、用 sshd 檢查，然後
重新載入 sshd。如果 sshd 拒絕這個值，或有其他 `MaxStartups` 設定覆蓋了它，就會還原先前的
設定。

- 不加選項執行 `ssh-limits` 會顯示目前的值。
- `ssh-limits --reset` 會恢復 sshd 的預設值。
- `install` 用 `--max-startups` 接受相同的值，`status` 會顯示實際生效的值。

## 維運規則

日常管理時不要手動編輯以下內容：

```text
/home/git/.ssh/authorized_keys
/home/git/repositories/*
/home/git/.gitolite/*
```

請改用指令：金鑰和存取規則透過 `gitolite-admin`（用 `apply`）管理；變更儲存庫的預設分支
請用 `repo-set-default`，不要編輯 bare 儲存庫的 `HEAD` 檔案。唯一的例外是
[救回遺失的 agent 分支](agents.md#救回被改寫或刪除的分支)。

不要在 Git 伺服器上執行 CI 工作或任意的儲存庫程式碼。讓 Git 伺服器只作為儲存庫／控制
平面，CI 和 agent 請在另外的主機上執行。
