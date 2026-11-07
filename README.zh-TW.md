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

你需要一台全新的 Debian 13 伺服器，以及一台裝有 OpenSSH 和 Git 的工作站。

### 1. 遠端安裝伺服器

`remote-install` 在工作站執行，一次做完[手動安裝](docs/zh-TW/install.md)的前三步：建立管理金鑰、在全新的
Debian 13 伺服器上安裝，並在這台機器寫入 `known_hosts` 和 SSH 別名。

```bash
./mini-git-server.sh remote-install \
  --host git.example.internal \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

工作站必須已經能 SSH 到伺服器。預設以 `root`、連接埠 `22` 登入，使用 SSH 平常會嘗試的金鑰。
登入方式不同時，傳入 `--login-user`、`--login-port` 和 `--login-identity`。不是 root 的使用者
必須能執行 `sudo -n`（免密碼 sudo）。

| 選項 | 預設值 | 用途 |
|---|---|---|
| `--host` | 必填 | 用戶端用來連伺服器的名稱或 IPv4 位址 |
| `--admin-name` | 必填 | Gitolite 管理身分，例如 `arthur-admin` |
| `--login-user` | `root` | 用來 SSH 進去並執行 `install` 的 Unix 帳號 |
| `--login-port` | `22` | 該登入的 SSH 埠 |
| `--login-identity` | SSH 自己的選擇 | 該登入使用的私鑰 |
| `--admin-key` | `~/.ssh/gitolite-admin` | 要建立或沿用的管理私鑰 |
| `--key-type` | `ed25519-sk` | `ed25519-sk` 或 `ed25519`；只在建立金鑰時使用 |
| `--no-passphrase` | 會詢問 | 建立一把沒有密碼的金鑰 |
| `--git-user` | `git` | 託管帳號，傳給 `install` |
| `--ssh-port` | `22` | 安裝之後 sshd 要聽的埠 |
| `--default-branch` | 不變更 | 新儲存庫的 Git 預設分支 |
| `--admin-alias` | `internal-git-admin` | 管理金鑰的 SSH 別名 |
| `--daily-alias` | `internal-git` | 日常金鑰的 SSH 別名 |
| `--daily-identity` | `~/.ssh/id_ed25519` | 日常別名指向的私鑰 |
| `--ssh-config` | `~/.ssh/config` | 要更新的 SSH 設定檔 |
| `--known-hosts` | `~/.ssh/known_hosts` | 要更新的 `known_hosts` 檔 |

`remote-install --help` 列出全部選項，包含 `--max-startups` 和 `--no-ssh-hardening`。

第一次連線會釘選伺服器主機金鑰（`StrictHostKeyChecking=accept-new`）。`--ssh-port` 和
`--login-port` 不同時，sshd 會改聽 `--ssh-port`。這個指令不會改防火牆。安裝完成後會以託管使用者
連線一次；如果那個埠沒有回應，工作站的檔案已經寫好，指令會停下來，讓你開放埠之後再執行
`ssh <admin-alias> info`。

成功之後，腳本留在伺服器的 `/usr/local/sbin/mini-git-server.sh`。已存在的管理金鑰會沿用。
已存在的 SSH 別名維持原樣。`remote-install` 不會複製 `gitolite-admin`，也不會新增使用者；那是下面的下一步。

**2. 複製並準備 `gitolite-admin`：**

```bash
git clone internal-git-admin:gitolite-admin
cd gitolite-admin
/path/to/mini-git-server.sh admin-init
```

**3. 新增使用者、agent 和儲存庫。** 這些指令只會暫存變更：

```bash
/path/to/mini-git-server.sh user-add --name arthur     --key ~/.ssh/id_ed25519.pub
/path/to/mini-git-server.sh user-add --name agent-impl --key ~/keys/agent-impl.pub

/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents agent-impl \
  --protected-branch trunk
```

**4. 檢視並部署：**

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
| 管理工作站 | `remote-install` | 建立管理金鑰、安裝新的伺服器，並寫入 SSH 設定 |
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
| [安裝](docs/zh-TW/install.md) | 手動安裝：管理金鑰、`install`、工作站 SSH 設定、主機金鑰 |
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
