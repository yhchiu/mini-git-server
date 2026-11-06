# 管理流程

[English](../administration.md) | **繁體中文**

所有存取規則都存放在 `gitolite-admin` 儲存庫中。mini-git-server 的指令會在管理工作站上
修改它的工作目錄，並把變更**暫存**起來；在 `apply` 提交並推送之前，伺服器上不會有任何
變化。

```mermaid
flowchart LR
    A["user-add / repo-set / group-set ..."] -->|暫存| B["gitolite-admin 工作目錄"]
    B -->|"apply：檢視、提交、推送"| C["伺服器上的 Gitolite"]
    C -->|"sync"| B
```

- [初始化由腳本管理的 ACL 片段](#初始化由腳本管理的-acl-片段)
- [套用管理變更](#套用管理變更)
- [從多台機器管理](#從多台機器管理)
- [修復位在錯誤分支上的 admin 儲存庫](#修復位在錯誤分支上的-admin-儲存庫)

會暫存變更的指令請看[存取控制](access-control.md)。

## 初始化由腳本管理的 ACL 片段

在 `gitolite-admin` 工作目錄中執行：

```bash
/path/to/mini-git-server.sh admin-init
```

這會依序加入：

```text
include "groups/*.conf"
include "repos/*.conf"
```

並把由腳本管理的群組存放在 `conf/groups/`，儲存庫 ACL 存放在 `conf/repos/`。Gitolite
要求群組必須在規則使用它之前定義，所以 groups 的 include 一定排在前面。重複執行
`admin-init` 是安全的：如果工作目錄是在 0.3.0 之前建立的，它會把 groups 的 include 加在
既有的 repos include 前面（請看英文的
[Upgrading to 0.3.0](../upgrade/0.3.0.md)）。

檢視後部署變更：

```bash
/path/to/mini-git-server.sh apply \
  -m "Initialize managed Gitolite repository ACLs"
```

## 套用管理變更

管理指令只會暫存變更，不會自動推送。

用以下指令檢視並部署：

```bash
/path/to/mini-git-server.sh apply \
  -m "Add project-x and agent access"
```

`apply` 會：

1. 確認工作目錄位在 `master` 分支；
2. 執行 `git diff --check --cached`；
3. fetch `origin`，如果其他機器已經推送了較新的變更，就在提交前停止；
4. 顯示已暫存的差異；
5. 提交變更；
6. 推送到 `origin` 的 `master`。

只提交、不推送：

```bash
/path/to/mini-git-server.sh apply --no-push
```

`apply` 拒絕在 `master` 以外的分支上執行。Gitolite 會忽略推送到 `gitolite-admin` 其他
分支的變更，所以那樣的推送雖然會成功，卻不會改變任何存取規則。

## 從多台機器管理

每台管理工作站都有自己的 `gitolite-admin` 工作目錄。如果其他機器在這段期間套用了變更，
`apply` 會在提交前停止。請先更新工作目錄，再套用一次：

```bash
/path/to/mini-git-server.sh sync
/path/to/mini-git-server.sh apply -m "Add project-y"
```

`sync`：

- 快轉（fast-forward）到 `origin`，保留已暫存但尚未套用的變更；
- 把尚未推送的本機提交（例如推送失敗後，或 `apply --no-push` 之後）rebase 到 `origin`
  上；
- 永遠不會推送。

`repo-set` 會寫入儲存庫的完整 ACL。如果其他機器修改了同一個儲存庫，請在 `sync` 之後
檢查已暫存的差異，或直接在更新後的狀態上重新執行 `repo-set` 指令。在開始修改之前先執行
`sync` 就能避免這種情況。

## 修復位在錯誤分支上的 admin 儲存庫

在 0.3.0 之前，`install --default-branch NAME` 會把 `gitolite-admin` 建立在 `NAME` 分支
而不是 `master`。在這樣的伺服器上，每次推送到 `gitolite-admin` 都會成功，但 Gitolite
從來不會套用：新的金鑰和儲存庫都不會出現。`doctor` 會把這回報為失敗，`apply` 也會拒絕在
該分支上執行。

修復時，先在伺服器上把 admin 儲存庫指向 `master`：

```bash
sudo ./mini-git-server.sh repo-set-default \
  --repo gitolite-admin \
  --branch master
```

接著在管理工作站的 `gitolite-admin` 工作目錄中，重新命名本機分支並推送。這次推送會讓
Gitolite 套用設定：

```bash
git fetch origin
git branch -m master
git push -u origin master
```

也可以從伺服器刪除舊分支（把 `trunk` 換成當時使用的分支名稱）：

```bash
git push origin --delete trunk
```

在工作站用 `ssh internal-git-admin info`、在伺服器用 `sudo ./mini-git-server.sh doctor`
確認結果。
