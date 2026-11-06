# 存取控制

[English](../access-control.md) | **繁體中文**

這些指令在管理工作站的 `gitolite-admin` 工作目錄中執行。它們只會**暫存**變更；請執行
[`apply`](administration.md#套用管理變更) 來部署。

- [使用者與金鑰](#使用者與金鑰)
- [儲存庫 ACL](#儲存庫-acl)
  - [產生的 ACL 代表什麼](#產生的-acl-代表什麼)
  - [`repo-set` 會取代受管理的狀態](#repo-set-會取代受管理的狀態)
  - [群組](#群組)
  - [檢視與修改目前的狀態](#檢視與修改目前的狀態)
  - [匿名讀取](#匿名讀取)
- [預設分支與受保護分支](#預設分支與受保護分支)

## 使用者與金鑰

加入你的日常身分。它與 `install` 建立的管理身分是分開的，所以這把金鑰無法修改存取規則：

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/.ssh/id_ed25519.pub
```

當金鑰被加到一個可以推送 `gitolite-admin` 的身分時，`user-add` 會發出警告；當這樣的身分
被用在儲存庫 ACL 中時，`repo-set` 也會警告。請看[身分與金鑰](identities.md)。

### 同一個身分的多台裝置

```bash
/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/keys/desktop.pub \
  --key-id desktop

/path/to/mini-git-server.sh user-add \
  --name arthur \
  --key ~/keys/notebook.pub \
  --key-id notebook
```

這會產生 `keydir/desktop/arthur.pub` 和 `keydir/notebook/arthur.pub`。兩把金鑰都對應到
同一個邏輯上的 Gitolite 使用者 `arthur`。

### AI agent

使用各自獨立的身分和金鑰：

```bash
/path/to/mini-git-server.sh user-add \
  --name agent-impl \
  --key ~/keys/agent-impl.pub \
  --key-id agent-host-1

/path/to/mini-git-server.sh user-add \
  --name agent-review \
  --key ~/keys/agent-review.pub \
  --key-id agent-host-1
```

### `user-add` 會拒絕的情況

- 已經存放在另一個身分下的金鑰。因為 sshd 只會使用第一個符合的項目，兩個身分會在不知不覺
  中變成同一個。
- Gitolite 會解讀成其他使用者的名稱。Gitolite 會把 `arthur@laptop.pub` 讀成使用者
  `arthur`，所以裝置標籤請用 `--key-id laptop`。`a@example.com` 這類電子郵件格式的名稱
  沒有問題。

### 移除金鑰

```bash
# 移除 keydir/arthur.pub
/path/to/mini-git-server.sh user-remove --name arthur

# 移除單一裝置的金鑰：keydir/notebook/arthur.pub
/path/to/mini-git-server.sh user-remove --name arthur --key-id notebook

# 移除某個身分的所有金鑰，例如已退役的 agent
/path/to/mini-git-server.sh user-remove --name agent-fix --all
```

`user-remove` 拒絕移除最後一把可以推送 `gitolite-admin` 的金鑰，因為之後就沒有人能修改
存取規則了。請先加入另一把管理金鑰；如果確實要這麼做，請加上 `--force`。

當某個身分已經沒有金鑰、但仍出現在存取規則中時，`user-remove` 會列出相關檔案。請把這個
名稱也從那些規則中移除，否則之後用相同名稱加入的金鑰會取回舊的權限。

## 儲存庫 ACL

`repo-set` 是主要的儲存庫管理指令。它宣告一個儲存庫**完整的期望 ACL 狀態**，並暫存
產生的 Gitolite 片段。程式中沒有寫死 `main` 分支。

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer1,developer2 \
  --agents agent-impl,agent-fix \
  --readers agent-review,ci \
  --protected-branch trunk \
  --protected-branch production
```

| 選項 | 角色 |
|---|---|
| `--owner NAME` | 全部權限（`RW+`）；唯一可以推送 tag 的身分 |
| `--writers LIST` | `RW`，但不能動受保護分支、tag 和 `agent/*` |
| `--agents LIST` | 只能在 `agent/<自己的名稱>/*` 下 `RW`；其他部分唯讀 |
| `--readers LIST` | 唯讀 |
| `--protected-branch NAME` | 寫入者和 agent 不能更新的分支（完全比對）；可重複指定 |
| `--agent-rewind` | 允許 agent 強制推送和刪除自己的分支；請看 [與 AI agent 協作](agents.md#允許-agent-改寫自己的分支) |

清單以逗號分隔，可以包含 `@agents` 之類的[群組](#群組)。

`repo-add` 仍然保留，作為 `repo-set` 的向下相容別名。新的腳本和文件請使用 `repo-set`。

### 產生的 ACL 代表什麼

上面的範例產生的 ACL 概念上像這樣：

```text
repo project-x
    RW+                            =   arthur
    -       refs/heads/trunk$      =   developer1 developer2 agent-impl agent-fix
    -       refs/heads/production$ =   developer1 developer2 agent-impl agent-fix
    -       refs/tags/             =   developer1 developer2 agent-impl agent-fix
    -       agent/                 =   developer1 developer2
    RW                             =   developer1 developer2
    RW      agent/USER/            =   agent-impl agent-fix
    R                              =   agent-impl agent-fix agent-review ci
```

意思是：

- `arthur` 對儲存庫有 `RW+` 權限，也是唯一可以推送 tag 的身分；
- 一般寫入者有 `RW`，但不能更新受保護分支、不能推送 tag，也不能寫入 `agent/*` 分支；
- `agent-impl` 只能寫入 `agent/agent-impl/*`；
- `agent-fix` 只能寫入 `agent/agent-fix/*`；
- agent 擁有的是 `RW` 而不是 `RW+`，所以預設不能強制推送自己的 agent 分支；
- 審查和 CI 身分是唯讀的。

Gitolite 採用第一條符合的規則，所以所有 `-`（拒絕）規則都排在寫入者的 `RW` 規則之前。

`--protected-branch` 使用完全比對。像 `release/1.2` 這樣的分支名稱在寫成 Gitolite refex
之前會先跳脫，所以合法 Git 分支名稱中的正規表示式特殊字元不會意外擴大規則範圍。如果沒有
指定 `--protected-branch`，腳本不會假設任何分支名稱。

`repo-set` 在寫入 ACL 之前會先檢查：

- 每個身分只能有一種角色（擁有者、寫入者、agent 或讀取者）。例如，同時被列為寫入者的
  agent 可以推送到受保護分支以外的所有分支，所以會被拒絕。
- Agent 名稱只能使用英文字母、數字、`-` 和 `_`，因為 Gitolite 會把名稱放進分支規則
  `agent/USER/` 中。
- 對 `keydir/` 中還沒有金鑰的身分發出警告。這通常表示打錯字，或是還沒加入金鑰。Gitolite
  的特殊使用者 `daemon` 和 `gitweb` 永遠沒有金鑰；對它們，腳本會改為說明它們的作用（請看
  [匿名讀取](#匿名讀取)）。

### `repo-set` 會取代受管理的狀態

> [!WARNING]
> `repo-set` 是宣告式的。沒有寫出來的選項會從由腳本管理的 ACL 片段中**移除**。不要只傳入
> 要新增的身分。

例如，某個儲存庫目前是：

```text
writers = developer1 developer2
agents  = agent-impl agent-fix
readers = agent-review ci
```

如果要移除 `developer1` 和 `agent-fix`，請重新執行完整的期望狀態：

```bash
/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer2 \
  --agents agent-impl \
  --readers agent-review,ci \
  --protected-branch trunk
```

取得目前指令最簡單的方法是 [`repo-show`](#檢視與修改目前的狀態)。

### 群組

當有多個 agent 和多個儲存庫時，把 agent 列在一個群組中，再在每個儲存庫使用這個群組：

```bash
/path/to/mini-git-server.sh group-set \
  --name agents \
  --members agent-impl,agent-fix

/path/to/mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --agents @agents \
  --readers agent-review,ci \
  --protected-branch trunk
```

`@agents` 的每個成員仍然只能使用自己的 `agent/<name>/*` 分支。之後要新增或移除 agent，
只要用新的成員清單執行 `group-set` 再 `apply`，不需要對每個儲存庫重新執行 `repo-set`。

`group-set` 和 `repo-set` 一樣是宣告式的：`--members` 是完整清單。寫入群組之前，它會用
新的成員檢查每個使用這個群組的受管理儲存庫，確保成員在同一個儲存庫中不會同時擁有兩種
角色。

```bash
/path/to/mini-git-server.sh group-list
/path/to/mini-git-server.sh group-remove --name agents
```

只要還有儲存庫在使用這個群組，`group-remove` 就會拒絕。群組可以用在 `--writers`、
`--agents` 和 `--readers`；`@all` 照常可用。

### 檢視與修改目前的狀態

```bash
/path/to/mini-git-server.sh repo-list
/path/to/mini-git-server.sh repo-show --repo project-x
```

`repo-show` 的輸出範例：

```text
Repository: project-x
Owner: arthur
Writers: developer1 developer2
Agents: agent-impl agent-fix
Readers: agent-review ci
Protected branches:
  - trunk

Reapply command:
mini-git-server.sh repo-set \
  --repo project-x \
  --owner arthur \
  --writers developer1,developer2 \
  --agents agent-impl,agent-fix \
  --readers agent-review,ci \
  --protected-branch trunk
```

這個指令就是設計來讓你複製、修改後再執行的。變更只會被暫存；仍然需要 `apply` 來提交和
推送。

要檢視實際的 Gitolite 片段：

```bash
/path/to/mini-git-server.sh repo-show --repo project-x --raw
```

`repo-show` 也能解析早期 0.2.x 版本產生、還沒有 `repo-set` 所寫入中繼資料的片段。

### 匿名讀取

`daemon` 和 `gitweb` 是 Gitolite 的特殊使用者，不是有金鑰的身分：

- `--readers daemon` 會讓 Gitolite 在儲存庫中放一個 `git-daemon-export-ok` 檔案。
  `git daemon` 和 `git http-backend` 只會提供有這個檔案的儲存庫，而且任何能連到它們的人
  都不需要金鑰就能讀取。
- `--readers gitweb` 會把儲存庫列在 `projects.list` 中，供 gitweb 使用。

mini-git-server 不會架設 `git daemon`、`git http-backend` 或 gitweb，所以單靠這些設定
不會讓任何東西可以被存取。但只要伺服器上執行了其中任何一個，這就有影響。

`@all` 包含 `daemon` 和 `gitweb`。設定 `--readers @all` 的儲存庫，或任何其他針對 `@all`
的規則（例如 Gitolite 建立的 `testing` 儲存庫），都會被同樣標記。

## 預設分支與受保護分支

這是兩個不同的概念：

| | 預設分支 | 受保護分支 |
|---|---|---|
| 是什麼 | bare 儲存庫的 `HEAD` 指向的分支 | 一條 ACL 規則 |
| 控制什麼 | 一般 clone 時會 checkout 哪個分支 | 誰可以更新這個分支（完全比對） |
| 設定方式 | `install --default-branch`（整台伺服器，新的儲存庫）、`repo-set-default`（單一儲存庫） | `repo-set --protected-branch` |
| 執行位置 | 伺服器 | 管理工作站 |

兩者不必是同一個分支。

### 預設分支

**新建立的儲存庫**在整台伺服器上的預設值，可以在安裝時用 `install --default-branch trunk`
指定。這會為 Gitolite 託管帳號設定 Git 的 `init.defaultBranch`。

單一儲存庫請使用伺服器端指令：

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo project-x \
  --branch trunk
```

效果等同於 `HEAD -> refs/heads/trunk`。請用這個指令，不要手動編輯 bare 儲存庫的 `HEAD`
檔案。

空的儲存庫可以指向一個尚未誕生的分支，這在第一次推送之前很有用。如果要求分支必須已經
存在，請加上 `--require-existing`。

`gitolite-admin` 是例外：`repo-set-default` 只接受 `master`，因為 Gitolite 會忽略推送到
admin 儲存庫其他分支的變更。

### 受保護分支

`--protected-branch trunk` 會禁止透過 `--writers` 和 `--agents` 指定的使用者更新這個
分支（完全比對）。擁有者仍然可以更新。
