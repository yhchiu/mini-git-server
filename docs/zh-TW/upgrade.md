# 升級

[English](../upgrade/README.md) | **繁體中文**

升級就是替換腳本。它本身永遠不會修改存取規則：既有的金鑰和儲存庫 ACL 會繼續運作，
Gitolite 本身也不會被更動。當新版本需要修改伺服器或 `gitolite-admin` 時，它的升級說明會
列出這些修改，由你手動執行。

查看目前的版本：

```bash
./mini-git-server.sh version
```

## 升級說明

請由舊到新，閱讀比你目前版本新的每個版本的說明：

| 版本 | 升級自 | 說明 |
|---|---|---|
| 0.3.0 | 0.2.x | [0.3.0.md](../upgrade/0.3.0.md)（英文） |

> [!NOTE]
> 各版本的升級說明只有英文版。

## 一般步驟

1. 閱讀新版本，以及你跳過的每個版本的升級說明。
2. 把伺服器和每台管理工作站上的 `mini-git-server.sh` 換成新版本，並確認：

   ```bash
   ./mini-git-server.sh version
   ```

3. 在伺服器上修改任何其他東西之前，先做備份：

   ```bash
   sudo ./mini-git-server.sh backup
   ```

4. 在伺服器上執行 `doctor`，記下每一行 `[FAIL]` 和 `[WARN]`：

   ```bash
   sudo ./mini-git-server.sh doctor
   ```

5. 執行升級說明中的伺服器步驟。
6. 在每台管理工作站上，把 `gitolite-admin` 工作目錄更新到最新：

   ```bash
   /path/to/mini-git-server.sh sync
   ```

7. **只在一台**工作站上執行升級說明中的工作站步驟，檢視已暫存的差異後 `apply`。其他工作站
   用 `sync` 取得結果。
8. 在伺服器上再執行一次 `doctor`。不應該再有任何 `[FAIL]` 行；可能留下的 `[WARN]` 行會在
   升級說明中解釋。

以上指令假設使用預設的託管帳號 `git`，家目錄為 `/home/git`。如果安裝時使用了
`--git-user`，請改用該帳號，並在伺服器指令中加上 `--git-user`。
