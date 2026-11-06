# 用 `share` 做一次性部署

[English](../share.md) | **繁體中文**

只需要取得一次程式碼的機器（例如一次性部署）不需要自己的金鑰。在一台能讀取儲存庫的機器
（例如你的工作站）上執行 `share`，再到目標機器上執行它印出的指令即可。

> [!TIP]
> 如果你本來就能用 SSH 登入目標機器，就不需要 `share`。直接透過那條連線傳送封存檔：
>
> ```bash
> git archive --remote=internal-git:project-x --format=tar trunk | ssh web-1 'mkdir -p /srv/app && tar -x -C /srv/app'
> ```

## 用法

```bash
/path/to/mini-git-server.sh share \
  --from internal-git:project-x \
  --ref trunk \
  --bind 10.0.0.5
```

```text
[INFO] Exporting 'trunk' from internal-git:project-x
Sharing project-x-trunk.tar.gz (13M) until 2026-11-04 11:59:41, or after 1 download. Press Ctrl-C to stop earlier.

URL:     http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz
SHA-256: 29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a

On the target:
  curl -fsS -o 'project-x-trunk.tar.gz' 'http://10.0.0.5:40719/5d74b83578475deaead8f86fdfc6becc/project-x-trunk.tar.gz' && echo '29d8a7d51554e73e7837be043843c912a8b266073d823f807a33881d919fd91a  project-x-trunk.tar.gz' | sha256sum -c - && tar -xzf 'project-x-trunk.tar.gz'
```

需求：

- 目標機器只需要 `curl`、`sha256sum` 和 `tar`（或 `unzip`）。
- 執行 `share` 的機器需要 `python3`（使用 `--tls` 時還需要 `openssl`）。
- 目標機器必須能連到它：`share` 不會修改任何防火牆。

## 選項

| 選項 | 作用 |
|---|---|
| `--bind ADDRESS` | **必填。** 要監聽的位址；請看[安全注意事項](#安全注意事項) |
| `--depth N` | 包含最近 N 個提交的 `.git`，讓目標機器得到 shallow clone，而不只是檔案。會移除會透露 Git 伺服器名稱的 remote 和 reflog。 |
| `--format zip` | 改用 zip 封存檔而不是 tar.gz，例如給 Windows 目標機器 |
| `--tls` | 使用一次性自簽憑證的 HTTPS。印出的指令會釘選（pin）它的金鑰，所以不涉及任何 CA。 |
| `--max-downloads N` | 允許 N 次完整下載，供多台目標機器使用；`0` 表示在時間限制內不限次數 |
| `--ttl TIME` | 在 `90s`、`30m`、`2h` 等時間後停止；最多 `24h` |
| `--port PORT`、`--url-host NAME` | 固定連接埠（例如為了防火牆規則），以及網址中要顯示的主機名稱 |

## 運作方式

`share` 會：

1. 透過 Gitolite、以你自己的身分用 `git archive` 匯出分支或 tag，所以只能分享你能讀取的
   內容；
2. 在一個包含 128 位元隨機值的網址提供封存檔，其他路徑一律回應 404；
3. 在 30 分鐘後（`--ttl`）、一次完整下載後（`--max-downloads`）或按下 Ctrl-C 時停止，然後
   移除它建立的所有東西。

伺服器一開啟封存檔就會把它從磁碟刪除，而且在 `share` 結束後約一秒內就會自行停止。所以
網址一旦印出，即使 `kill -9` 也只會留下一個空的暫存目錄。

## 安全注意事項

- **不使用 `--tls` 時，網路上的人可以讀取並竄改傳輸中的封存檔。** 印出的指令會驗證
  SHA-256 校驗碼，但前提是這個指令是透過你信任的管道送到目標機器的，例如你的 SSH 連線或
  主控台。在不信任的網路上，請使用 `--tls`。
- **網址是唯一的秘密。** 在分享停止之前，任何拿到網址的人都能下載封存檔，所以請把
  `--max-downloads` 設低。`share` 不會記錄權杖，也不會在任何命令列上傳遞它。但在目標機器
  上，網址會留在 shell 歷史記錄中、在 curl 執行期間出現在程序清單中，中間的代理伺服器也
  可能記錄它。
- **`--bind` 是必填的。** 請監聽目標機器使用的位址。如果用 `0.0.0.0` 或 `::`，`share`
  也會在這台機器連上的其他所有網路上監聽，例如公共 Wi-Fi。
- `share` 只會移除它自己建立的東西。目標機器上的副本要由你自己移除。
- 不包含子模組，Git LFS 檔案只會有指標（pointer）。

## 位在其他網路的目標機器

位在其他網路的目標機器可能連不到你的工作站。請在它連得到的主機上執行 `share`，或透過
SSH 轉發連接埠。也可以搭配 `--bind 127.0.0.1` 使用公開的通道服務，但這樣程式碼會經過該
服務，而且網路上任何拿到網址的人都能下載。
