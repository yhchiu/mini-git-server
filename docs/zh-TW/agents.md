# 與 AI agent 協作

[English](../agents.md) | **繁體中文**

每個 agent 都有自己的 SSH 身分，預設只能推送到自己的 `agent/<name>/*` 分支。這是由伺服器
上的 Gitolite 強制執行的，而不是只靠給 agent 的指示。

- [授權模型](#授權模型)
- [Agent 工作流程](#agent-工作流程)
- [允許 agent 改寫自己的分支](#允許-agent-改寫自己的分支)
- [審查與合併 agent 的成果](#審查與合併-agent-的成果)
- [救回被改寫或刪除的分支](#救回被改寫或刪除的分支)
- [給 agent 的指示](#給-agent-的指示)
- [同時運作大量 agent](#同時運作大量-agent)

> [!IMPORTANT]
> Gitolite 只靠 agent 連線時使用的 SSH 金鑰來辨識它。能使用你金鑰的 agent **就是**你。
> 在給 agent 存取權之前，請先閱讀[把 agent 的金鑰分開](identities.md#把-agent-的金鑰分開)。

## 授權模型

建議的授權模型：

```text
人類擁有者
    整個儲存庫：RW+
    唯一可以推送 tag 的身分

寫入者
    分支：RW，但不包含受保護分支和 agent/*
    tag：無

實作用 agent
    agent/<自己的使用者>/*：RW
    儲存庫的其他部分：R

審查用 agent
    儲存庫：R

CI runner
    儲存庫：R
```

設定這個模型的 `repo-set` 指令請看[儲存庫 ACL](access-control.md#儲存庫-acl)。

## Agent 工作流程

實作用 agent 應該使用自己的 SSH 金鑰和分支命名空間：

```bash
git switch -c agent/agent-impl/issue-42
git push -u origin agent/agent-impl/issue-42
```

Agent 可以確認自己實際的身分：

```bash
ssh internal-git info
```

第一行會顯示身分名稱，例如 `hello agent-impl, this is git@...`。如果顯示的是你自己的
名稱，表示 agent 可以使用你的金鑰。

列在 `--readers` 中的審查用 agent 只能讀取。如果要讓它以分支的形式交回修正或註記，請改把
它列在 `--agents`：這樣它就會有自己的 `agent/agent-review/*` 命名空間。

## 允許 agent 改寫自己的分支

預設情況下，agent 不能強制推送或刪除分支，連自己的分支也不行。審查之後，想要 rebase 的
agent 必須推送一個新分支，例如 `agent/agent-impl/issue-42-v2`，舊分支會保留到擁有者刪除
為止。

許多 agent 工具會 rebase 後用 `--force-with-lease` 推送。如果只想在每個 agent 自己的
命名空間內允許這麼做，請加上 `--agent-rewind`：

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents @agents \
  --agent-rewind \
  --protected-branch trunk
```

這只會把 `agent/USER/` 的 agent 規則從 `RW` 改為 `RW+`。Agent 仍然不能寫入其他地方，也
不能改寫或刪除其他 agent 的分支。

## 審查與合併 agent 的成果

Agent 永遠不會寫入主要分支；由擁有者合併它們的成果。在你工作站上的專案 clone 中，先看
總覽：

```bash
/path/to/mini-git-server.sh agent-branches
```

```text
AGENT       BRANCH                    AHEAD  BEHIND  UPDATED           SUBJECT
agent-impl  agent/agent-impl/issue-1      2       0  3 hours ago       Step two
agent-fix   agent/agent-fix/typo          0       1  2 days ago        Fix a typo

Ahead and behind are counted against origin/trunk.
```

`agent-branches` 會先 fetch，把最新的分支列在最前面，並與遠端的預設分支（它的 `HEAD`）
比較，所以不會假設分支名稱。

| 選項 | 作用 |
|---|---|
| `--base BRANCH` | 與其他分支比較 |
| `--remote NAME` | 使用其他 remote |
| `--no-fetch` | 不要 fetch |
| `--merged` | 只列出所有提交都已在基準分支中的分支，並附上在伺服器上刪除它們的指令 |

接著用一般的 Git 指令檢視、合併和清理分支：

```bash
# 查看某個分支在 trunk 之上新增了什麼
git log --oneline trunk..origin/agent/agent-impl/issue-42
git diff trunk...origin/agent/agent-impl/issue-42

# 比較同一份工作的兩個版本，例如 rebase 之後
git range-diff trunk origin/agent/agent-impl/issue-42 origin/agent/agent-impl/issue-42-v2

# 合併並發布
git switch trunk
git merge --no-ff origin/agent/agent-impl/issue-42
git push origin trunk

# 列出所有提交都已在 trunk 中的 agent 分支，然後刪除
/path/to/mini-git-server.sh agent-branches --merged
git push origin --delete agent/agent-impl/issue-42
```

用 squash 或 rebase 方式合併的分支，在 `agent-branches` 中仍會顯示領先的提交，因為它們
自己的提交並不在基準分支中。

## 救回被改寫或刪除的分支

Gitolite 的日誌會記錄每次推送的使用者、分支、舊提交和新提交。找出你要救回的提交：

```bash
sudo grep -h 'refs/heads/agent/agent-impl/issue-42' /home/git/.gitolite/logs/gitolite-*.log
```

新安裝的伺服器也會在每個託管的儲存庫中保留 reflog（`core.logAllRefUpdates=always`）。
對於被強制推送（而不是被刪除）的分支，reflog 會列出它先前的提交：

```bash
sudo runuser -u git -- git -C /home/git/repositories/project-x.git \
  reflog show refs/heads/agent/agent-impl/issue-42
```

然後在舊提交上建立新分支。這是唯一需要直接在託管儲存庫中執行 Git 的情況：

```bash
sudo runuser -u git -- git -C /home/git/repositories/project-x.git \
  branch recovered/issue-42 OLD_COMMIT
```

限制：

- 刪除分支也會刪除它的 reflog。被刪除的分支請從 Gitolite 日誌中找提交。
- 沒有任何分支或 reflog 指向的提交，在超過兩週後（`gc.pruneExpire`）可能會被 Git 刪除。
  reflog 中的提交會保留比較久（預設 30 天）。請盡快救回，或依賴
  [`backup`](operations.md#備份)。
- 0.3.0 之前的安裝在手動啟用之前沒有 reflog（請看英文的
  [Upgrading to 0.3.0](../upgrade/0.3.0.md)）。`doctor` 會回報是否已啟用。

## 給 agent 的指示

[`examples/AGENTS.md`](../../examples/AGENTS.md)（英文）是每個專案儲存庫中指示檔
（`AGENTS.md`、`CLAUDE.md`，或你的 agent 工具讀取的任何檔案）的範本。它告訴 agent 如何
找出自己的身分、可以推送到哪些分支、推送被拒絕時該怎麼做，以及交付成果時要回報什麼。
不論有沒有這個檔案，伺服器都會強制執行規則；這個檔案只是讓 agent 不必做會被拒絕的工作。

## 同時運作大量 agent

- **Git protocol v2。** 新的安裝會為託管帳號接受 `GIT_PROTOCOL`，讓 Git 可以使用
  protocol v2。使用 v2 時，伺服器只會列出用戶端要求的 ref（例如 `git fetch origin trunk`
  只列出 `trunk`），而不是每次連線都列出所有分支和 tag。當儲存庫累積了很多 agent 分支時，
  這點很重要。0.3.0 之前的安裝需要手動修改一處（請看英文的
  [Upgrading to 0.3.0](../upgrade/0.3.0.md)）。`doctor` 會回報是否已啟用。
- **連線尖峰。** 預設情況下，只要有 10 個連線正在等待登入，sshd 就會開始隨機拒絕新連線。
  如果許多 agent 同時 fetch，有些出現 "Connection closed" 失敗，請用 `ssh-limits` 提高
  上限；請看 [SSH 連線數限制](operations.md#ssh-連線數限制)。
