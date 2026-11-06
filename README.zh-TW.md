# mini-git-server

[English](README.md) | **繁體中文**

一支 Bash 腳本，只用 Debian 套件裡的 OpenSSH、Git 和 Gitolite 3，就能把一台全新的
Debian 13 主機變成給**人與 AI agent** 共用的私有 Git 伺服器。

- **小而容易稽核。** 只有一支腳本，只用 Debian 套件。不附帶網頁介面、資料庫、Redis、
  容器執行環境、套件倉庫或 CI 系統。
- **在伺服器端限制 agent。** 每個 agent 有自己的 SSH 身分，預設只能推送到自己的
  `agent/<name>/*` 分支。只有擁有者可以推送 tag。
- **沒有你的確認就不會生效。** 管理指令只會在 Gitolite 標準的 `gitolite-admin`
  儲存庫中暫存變更；由 `apply` 檢視、提交並推送。
- **不假設主分支叫 `main`。** 受保護分支必須明確指定，預設分支（`HEAD`）也與存取控制
  政策分開管理。

> [!NOTE]
> 要從舊版升級？請看[升級](docs/zh-TW/upgrade.md)。

## 目錄

- [快速開始](#快速開始)
- [存取權限如何運作](#存取權限如何運作)
- [指令](#指令)
- [文件](#文件)
- [開發](#開發)
- [授權](#授權)

## 快速開始

你需要一台全新的 Debian 13 伺服器，以及一台裝有 OpenSSH 和 Git 的管理工作站。每個步驟
的細節請看[安裝](docs/zh-TW/install.md)。

**1. 在工作站建立專用的管理金鑰。** 建議使用 FIDO2 安全金鑰（`ed25519-sk`）；沒有的話，
改用 `-t ed25519` 並設定密碼。

```bash
ssh-keygen -t ed25519-sk -f ~/.ssh/gitolite-admin -C gitolite-admin
```

**2. 安裝伺服器。** 把 `mini-git-server.sh` 和 `gitolite-admin.pub` 複製到伺服器，然後執行：

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

> [!IMPORTANT]
> 腳本不會修改任何防火牆。如果使用非預設的 SSH 埠，請在結束目前的連線**之前**確認該埠
> 可以連線。

**3. 設定工作站。** 把 `install` 印出的 `known_hosts` 行加入 `~/.ssh/known_hosts`，並為每個
身分各設定一個 SSH 主機別名：

```sshconfig
# 管理金鑰，只用於 gitolite-admin
Host internal-git-admin
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/gitolite-admin
    IdentitiesOnly yes

# 日常使用的金鑰
Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

**4. 複製並準備 `gitolite-admin`：**

```bash
git clone internal-git-admin:gitolite-admin
cd gitolite-admin
/path/to/mini-git-server.sh admin-init
```

**5. 新增使用者、agent 和儲存庫。** 這些指令只會暫存變更：

```bash
/path/to/mini-git-server.sh user-add --name arthur     --key ~/.ssh/id_ed25519.pub
/path/to/mini-git-server.sh user-add --name agent-impl --key ~/keys/agent-impl.pub

/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents agent-impl \
  --protected-branch trunk
```

**6. 檢視並部署：**

```bash
/path/to/mini-git-server.sh apply -m "Add project-x"
```

現在 `agent-impl` 可以推送到 `project-x` 的 `agent/agent-impl/*`，你可以用
`agent-branches` 檢視它的成果。請看[與 AI agent 協作](docs/zh-TW/agents.md)。

## 存取權限如何運作

`repo-set` 在每個儲存庫中只給每個身分一種角色：

| 角色 | 選項 | 權限 |
|---|---|---|
| 擁有者 | `--owner` | 全部權限（`RW+`）；唯一可以推送 tag 的身分 |
| 寫入者 | `--writers` | 推送分支，但不能動受保護分支、tag 和 `agent/*` |
| Agent | `--agents` | 只能推送到 `agent/<自己的名稱>/*`，除非加上 `--agent-rewind`，否則不能強制推送；其他部分唯讀 |
| 讀取者 | `--readers` | 唯讀 |

> [!WARNING]
> - `repo-set` 是**宣告式**的：沒寫出來的選項會被移除。請用 `repo-show` 取得目前的指令，
>   修改後再執行一次。
> - Gitolite **只靠 SSH 金鑰**辨識使用者。能使用你金鑰的 agent 就等於是你。請依照
>   [身分與金鑰](docs/zh-TW/identities.md)的說明把金鑰分開。

## 指令

執行 `mini-git-server.sh help` 可看完整清單，`mini-git-server.sh <command> --help` 可看
個別指令的選項。

| 執行位置 | 指令 | 用途 |
|---|---|---|
| 伺服器（root） | `install` | 安裝 OpenSSH、Git 和 Gitolite，並初始化 Gitolite |
| | `status`、`doctor`、`fsck` | 顯示狀態、檢查設定、檢查儲存庫 |
| | `backup` | 以 Git 鏡像方式備份所有儲存庫 |
| | `repo-set-default` | 設定儲存庫的預設分支（`HEAD`） |
| | `host-keys` | 印出 SSH 主機金鑰指紋與 `known_hosts` 行 |
| | `ssh-limits` | 顯示或設定 sshd 的 `MaxStartups` |
| 管理工作站（在 `gitolite-admin` 中） | `admin-clone`、`admin-init` | 複製 `gitolite-admin`；啟用由腳本管理的 ACL 片段 |
| | `user-add`、`user-remove`、`user-list` | 管理 SSH 金鑰與身分 |
| | `repo-set`、`repo-show`、`repo-list` | 設定與檢視儲存庫 ACL（`repo-add` 是 `repo-set` 的舊別名） |
| | `group-set`、`group-remove`、`group-list` | 管理 `@agents` 之類的群組 |
| | `sync`、`apply` | 從伺服器更新；檢視、提交並推送已暫存的變更 |
| 專案的 clone | `agent-branches` | 列出 agent 分支，以及相對於基準分支領先／落後多少 |
| 任何能讀取該儲存庫的機器 | `share` | 用臨時隨機網址提供分支或 tag，供一次性部署 |
| 任何地方 | `version`、`help` | 顯示版本或說明 |

## 文件

| 指南 | 內容 |
|---|---|
| [安裝](docs/zh-TW/install.md) | 管理金鑰、`install` 的選項與它會修改的內容、工作站 SSH 設定、主機金鑰 |
| [管理流程](docs/zh-TW/administration.md) | `admin-init`、`apply`、`sync`、多台管理機器、修復 admin 分支 |
| [存取控制](docs/zh-TW/access-control.md) | 使用者與金鑰、`repo-set` 與產生的 ACL、群組、`repo-show`、預設分支與受保護分支 |
| [與 AI agent 協作](docs/zh-TW/agents.md) | Agent 工作流程、`--agent-rewind`、審查與合併、救回分支、大量 agent |
| [身分與金鑰](docs/zh-TW/identities.md) | 管理／日常／agent 身分、隔離 agent 金鑰、移轉管理權限 |
| [一次性部署](docs/zh-TW/share.md) | `share` 的用法、選項與安全注意事項 |
| [伺服器維運](docs/zh-TW/operations.md) | 健康檢查、備份、SSH 連線數限制、維運規則 |
| [升級](docs/zh-TW/upgrade.md) | 一般升級步驟與各版本說明 |
| [Agent 指示範本](examples/AGENTS.md)（英文） | 給專案儲存庫用的 `AGENTS.md`／`CLAUDE.md` 範本 |

## 開發

```bash
make check                  # 語法檢查、ShellCheck（若已安裝）、單元測試
sudo make test-integration  # 對真實的 Gitolite 測試；請在可拋棄的機器上執行
```

所有測試套件（包含安裝端對端測試）與設計原則，請看
[CONTRIBUTING.md](CONTRIBUTING.md)（英文）。

## 授權

[GNU General Public License v3.0](LICENSE)。
