# 安裝

[English](../install.md) | **繁體中文**

本頁是手動安裝。從工作站用 `remote-install` 一次做完，請看
[遠端安裝伺服器](../../README.zh-TW.md#1-遠端安裝伺服器)。

- [1. 產生專用的管理金鑰](#1-產生專用的管理金鑰)
- [2. 安裝伺服器](#2-安裝伺服器)
- [3. 設定管理工作站](#3-設定管理工作站)
- [伺服器主機金鑰](#伺服器主機金鑰)

下一步：[準備 `gitolite-admin`](administration.md#初始化由腳本管理的-acl-片段)，
然後[新增使用者與儲存庫](access-control.md)。

## 1. 產生專用的管理金鑰

在管理工作站上產生，最好使用 FIDO2 安全金鑰，這樣每次使用管理金鑰都需要實際觸碰：

```bash
ssh-keygen -t ed25519-sk -f ~/.ssh/gitolite-admin -C gitolite-admin
```

沒有安全金鑰的話，使用一般金鑰並設定密碼：

```bash
ssh-keygen -t ed25519 -f ~/.ssh/gitolite-admin -C gitolite-admin
```

請使用專用金鑰，不要沿用其他用途的伺服器登入金鑰。管理金鑰可以修改所有存取規則，
所以它應該屬於一個獨立的 Gitolite 身分（例如 `arthur-admin`），而且只用於
`gitolite-admin`。日常工作使用另一個身分（例如 `arthur`）。請看
[身分與金鑰](identities.md)。

## 2. 安裝伺服器

把 `mini-git-server.sh` 和公鑰複製到一台全新的 Debian 13 伺服器。

以下範例使用 SSH 埠 `2222`，並讓新建立的儲存庫以 `trunk` 作為 Git 預設分支：

```bash
sudo ./mini-git-server.sh install \
  --admin-key ./gitolite-admin.pub \
  --admin-name arthur-admin \
  --ssh-port 2222 \
  --default-branch trunk
```

預設值：

| 設定 | 預設值 |
|---|---|
| 託管用的 Unix 使用者（`--git-user`） | `git` |
| SSH 埠（`--ssh-port`） | `22` |
| 儲存庫位置 | `/home/git/repositories` |
| Git 預設分支（`--default-branch`） | 不變更 |
| sshd `MaxStartups`（`--max-startups`） | sshd 的預設值；請看 [SSH 連線數限制](operations.md#ssh-連線數限制) |

安裝程式會：

1. 從 Debian 安裝 `openssh-server`、`git`、`gitolite3` 和 `ca-certificates`；
2. 視需要建立專用的 `git` 託管帳號；
3. 鎖定該帳號的密碼；
4. 視需要為託管帳號設定 `init.defaultBranch`；
5. 用提供的管理金鑰初始化 Gitolite；
6. 在 `/etc/ssh/sshd_config.d/00-gitolite-port.conf` 寫入 sshd 埠的設定片段；
7. 加入 SSH `Match User git` 強化設定片段，其中也接受 `GIT_PROTOCOL` 變數，讓 Git 可以
   使用 protocol v2；
8. 重新載入 SSH 之前先驗證 SSH 設定；
9. 印出 SSH 主機金鑰指紋與 `known_hosts` 行。

> [!IMPORTANT]
> 腳本不會修改 nftables/iptables、雲端防火牆、路由器 ACL 或 VPN 政策。如果使用非預設
> 的 SSH 埠，請在**結束目前的管理連線之前**確認該埠可以連線。

注意事項：

- `--ssh-port` 會實際設定 sshd，不只是參考資訊。如果 sshd 設定的其他地方已經有生效的
  `Port` 指令，腳本會警告 sshd 可能同時監聽多個埠。安裝程式主要是為全新的 Debian 主機
  設計的。
- `--default-branch` 只影響安裝之後建立的儲存庫。`gitolite-admin` 儲存庫一律使用
  `master` 分支，因為 Gitolite 3.6.12（Debian 13 的套件）只會套用推送到
  `gitolite-admin` 的 `master` 的變更。安裝程式在 `gitolite setup` 時會固定這個分支，
  如果 admin 儲存庫最後落在其他分支上就會停止。另請看
  [預設分支與受保護分支](access-control.md#預設分支與受保護分支)。
- 在已安裝的伺服器上再次執行 `install` 會被拒絕，而且不會修改任何東西。

## 3. 設定管理工作站

每個身分各使用一個 SSH 主機別名。這裡 `internal-git-admin` 使用管理金鑰，只用於
`gitolite-admin`；`internal-git` 使用日常金鑰（之後用
[`user-add`](access-control.md#使用者與金鑰) 加入）：

```sshconfig
Host internal-git-admin
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/gitolite-admin
    IdentitiesOnly yes

Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

第一次連線之前，把 `install` 印出的 `known_hosts` 行（或請看
[伺服器主機金鑰](#伺服器主機金鑰)）加入 `~/.ssh/known_hosts`。這樣 SSH 就不必詢問是否
信任未知的主機金鑰。

確認可以連線：

```bash
ssh internal-git-admin info
```

複製 admin 儲存庫：

```bash
git clone internal-git-admin:gitolite-admin
```

或者不使用 SSH 設定別名：

```bash
./mini-git-server.sh admin-clone \
  --host git.example.internal \
  --port 2222 \
  --identity ~/.ssh/gitolite-admin
```

## 伺服器主機金鑰

```bash
sudo ./mini-git-server.sh host-keys --host git.example.internal
```

這會印出每把 SSH 主機金鑰的指紋，以及各自的 `known_hosts` 行。連接埠從 sshd 讀取；可用
`--port` 覆寫。請透過你信任的管道，把這些行複製到管理工作站和 agent 主機。
