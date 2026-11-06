# 身分與金鑰

[English](../identities.md) | **繁體中文**

Gitolite 只根據連線的 SSH 金鑰判斷你是誰。任何能使用某把金鑰的程序**就是**那個身分。
因此，伺服器端的存取規則能保護你的程度，取決於用戶端是否把金鑰分開保管。

- [三種身分](#三種身分)
- [把 agent 的金鑰分開](#把-agent-的金鑰分開)
- [把管理權限移到獨立的身分](#把管理權限移到獨立的身分)

## 三種身分

| 身分 | 範例 | 權限 | 私鑰存放位置 |
|---|---|---|---|
| 管理 | `arthur-admin` | 只有 `gitolite-admin` | 管理工作站；最好是 FIDO2 金鑰（`-sk`） |
| 日常（擁有者） | `arthur` | 你的儲存庫的擁有者 | 你的工作站 |
| Agent | `agent-impl` | `agent/agent-impl/*`，其他部分唯讀 | 只放在該 agent 自己的環境中 |

管理身分不應該是任何儲存庫的擁有者、寫入者、agent 或讀取者，而且任何 AI agent 都不應該
能使用管理金鑰或日常金鑰。

## 把 agent 的金鑰分開

在你自己的終端機中執行的 AI agent，通常可以使用你能用的所有金鑰：它會繼承
`SSH_AUTH_SOCK`（你的 ssh-agent），也能讀取 `~/.ssh`。這時 Gitolite 看到的是你的身分，
而不是 agent 的。要限制 agent：

- 讓每個 agent 以自己的 Unix 使用者身分執行，或在自己的容器或 VM 中執行。
- 只把 agent 自己的私鑰放進那個環境。不要掛載你的 `~/.ssh`，也不要把你的 ssh-agent
  轉發進去。
- 在 agent 的環境中清除 `SSH_AUTH_SOCK`，並在它的 SSH 設定中使用 `IdentityAgent none`
  和 `IdentitiesOnly yes`。
- 用 FIDO2 安全金鑰保護管理金鑰（最好日常金鑰也是）。即使 agent 能接觸到金鑰，它也無法
  按下按鈕。
- 每種 agent 角色都使用自己的身分。多台主機可以用 `--key-id` 共用一個身分，但這樣它們也
  會共用同一個分支命名空間。

Agent 環境中的 SSH 設定範例：

```sshconfig
Host internal-git
    HostName git.example.internal
    User git
    Port 2222
    IdentityFile ~/.ssh/agent-impl
    IdentitiesOnly yes
    IdentityAgent none
    StrictHostKeyChecking yes
    UserKnownHostsFile ~/.ssh/known_hosts
```

設定 agent 環境時，把 [`host-keys`](install.md#伺服器主機金鑰) 印出的 `known_hosts` 行
放進這個檔案。設定 `StrictHostKeyChecking yes` 後，agent 遇到未知或已變更的主機金鑰會
直接拒絕，而不是停在提示畫面等待，或被要求關閉檢查。

要確認 agent 實際的身分，請在它的環境中執行 `ssh internal-git info`；請看
[Agent 工作流程](agents.md#agent-工作流程)。

## 把管理權限移到獨立的身分

0.3.0 之前的範例讓管理身分和日常身分使用同一個名稱。要把管理權限移到 `arthur-admin`
而不把自己鎖在外面：

1. 建立管理金鑰（[安裝的第 1 步](install.md#1-產生專用的管理金鑰)）並加入：

   ```bash
   /path/to/mini-git-server.sh user-add \
     --name arthur-admin \
     --key ~/.ssh/gitolite-admin.pub
   ```

2. 在 `conf/gitolite.conf` 中，把新身分加入 `gitolite-admin` 的規則，例如
   `RW+ = arthur arthur-admin`。然後執行 `git add conf/gitolite.conf` 和 `apply`。
3. 讓 admin 工作目錄改用管理金鑰，並確認：

   ```bash
   git remote set-url origin internal-git-admin:gitolite-admin
   ssh internal-git-admin info
   ```

   輸出中 `gitolite-admin` 必須顯示 `R W`。
4. 從 `gitolite-admin` 的規則中移除舊身分（`RW+ = arthur-admin`），然後執行
   `git add conf/gitolite.conf` 和 `apply`。`arthur` 會保留它的金鑰，並且仍然是你的
   儲存庫的擁有者。
