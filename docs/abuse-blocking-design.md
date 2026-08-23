# 不正アクセス遮断の設計（CrowdSec 版・2026-08-23）

fail2ban + ipset での設計（2026-08-02）を CrowdSec + Traefik bouncer へ載せ替えたもの。
**遮断の狙いは引き継いでいる**: 検知は実態に合う強さにし、記録は console に永続させる。
変わったのは検知と遮断の実装で、記録の形と管理画面は同じ。

## なぜ載せ替えたか

リバースプロキシを手書き nginx から Traefik にした時点で、fail2ban のフィルタは
ログ形式に合わせて全部書き直しになる。書き直す手間が乗り換えの手間と変わらないうえ、
CrowdSec は Traefik との連携（bouncer プラグイン）と共有ブロックリストを標準で持っている。

## 構成

```
リクエスト
  └─ Traefik（entrypoint websecure の既定ミドルウェア）
       ├─ crowdsec-bouncer … LAPI に問い合わせ、遮断中なら 403 で返す
       ├─ security-headers
       ├─ ratelimit-default … 30 r/s・burst 100 を超えたら 429
       └─ inflight-default  … 同時 100 を超えたら 429
  └─ アクセスログ（JSON・logs/traefik/access.log）
       └─ CrowdSec が読み、シナリオに当たれば decision（遮断）を作る
```

- 遮断の実体は CrowdSec の decision（SQLite。名前付き volume `crowdsec-data`）
- 弾くのは Traefik のミドルウェア。**HTTP だけが対象**で、パケットは落とさない
- 除外リストは `crowdsec/generated/allowlist.tsv` が正。パーサ段の whitelist に変換して読ませるので、
  除外した IP はそもそも decision を作られない

## 1. 検知（CrowdSec の collection）

有効化しているのは 3 つ（compose の `COLLECTIONS`）。

| collection | 何を拾うか |
| --- | --- |
| `crowdsecurity/traefik` | Traefik の JSON ログを読むパーサ（これが無いと何も解析されない） |
| `crowdsecurity/base-http-scenarios` | 404 連発の探索・高速クロール・不審な UA・認証の総当たり |
| `crowdsecurity/http-cve` | 既知の CVE を突く要求 |

fail2ban のジェイルとの対応:

| 旧ジェイル | 移り先 |
| --- | --- |
| nginx-probe（攻撃目的のパスを 1 回で遮断） | `crowdsecurity/http-sensitive-files`・`http-backdoors-attempts`・`http-path-traversal-probing` |
| nginx-scan / nginx-scan-slow（404 連発） | `crowdsecurity/http-probing`・`http-crawl-non_statics` |
| nginx-bruteforce（認証・レート超過の連打） | `crowdsecurity/http-generic-bf`。レート超過は Traefik の 429（後述） |
| nginx-botsearch | `crowdsecurity/http-bad-user-agent` ほか base-http-scenarios |
| **sshd** | **移り先なし**（下の「引き継げなかったもの」） |

閾値は collection のシナジオ定義が持つ。旧設定のように jail.local で数字を書かない。
実態に合わないと分かったら、`cscli scenarios` で確認して個別に上書きする。

遮断の長さは CrowdSec の既定（多くは 4 時間）と手動遮断の 24 時間。
最長でも 1 日に収める考え方は旧設計と同じで、記録が console に残るので
遮断そのものを長く持つ必要はなく、誤爆の影響も 1 日で収まる。

## 2. 遮断の記録（console）

**変えていない。** `ban_records` への追記のみで削除しない設計、
`(jail, ip, banned_at)` の一意キー、`released_at is null かつ expires_at > 現在` で
「いま遮断中か」を判定するところまで同じ。

ホストからの同期も同じ口（`POST /internal/fail2ban`）で、同じ JSON を送る。
`jail` に入る値だけが fail2ban のジェイル名から CrowdSec のシナリオ名
（`crowdsecurity/http-probing` 等）に変わった。

1 つだけ意味が変わった項目がある。`totalBanned`（ジェイル別の累計）は fail2ban が
プロセス内に持っていたカウンタだったが、CrowdSec に相当するものが無いので
**現在の遮断数と同じ値を送っている**。長期の通算は console の `ban_records` が持っており、
画面の「この IP の通算回数」はそちらを見るので実害は無い。

## 3. レート制限

nginx の `limit_req` / `limit_conn` は Traefik のミドルウェアに移した（値は据え置き）。

| | 旧（nginx） | 新（Traefik） |
| --- | --- | --- |
| 秒あたり | `rate=30r/s` `burst=100 nodelay` | `rateLimit: average 30 / period 1s / burst 100` |
| 同時接続 | `limit_conn 100` | `inFlightReq: amount 100` |
| 超過時 | 429 | 429（既定） |

旧構成では「429 を 5 分で 10 回」を fail2ban の nginx-bruteforce が拾って 1 日 ban していた。
CrowdSec 側にこの連鎖はまだ入れていない（429 の連発を拾うシナリオを足すかは実測してから決める）。

## 4. 誤爆対策

- 除外リスト（`make ban CMD=allow IP=… `）。自分の固定 IP と外形監視（Route53 ヘルスチェック）を入れる
- 解除操作は console の監査ログに残る（変更なし）
- 毎朝 08:00 の日報で直近 24 時間の遮断件数とシナリオ別内訳を出す

## 引き継げなかったもの

- **SSH の総当たり遮断**。fail2ban の `[sshd]` はホストの INPUT チェーンで弾いていたが、
  Traefik の bouncer は HTTP しか見ない。CrowdSec に `crowdsecurity/sshd` collection を足しても、
  実際に弾くにはホスト側の firewall bouncer（iptables/nftables）が別途要る。
  現状は「SSH の総当たりは遮断されない」。入れるかどうかは要判断
- **パケット層の遮断**。ipset + DOCKER-USER の DROP が無くなったので、
  遮断中の IP でも TCP 接続と TLS handshake までは通り、HTTP 応答が 403 になる

## 確認のしかた

```
docker compose exec crowdsec cscli metrics      # ログを読めているか（acquisition の行）
docker compose exec crowdsec cscli decisions list
docker compose exec crowdsec cscli bouncers list  # traefik が registered か
make bans                                        # 日報と同じ内容を表示だけする
```

`cscli metrics` の acquisition が 0 行のままなら、Traefik のログ形式か acquis.yaml の
`type: traefik` が合っていない。この状態でも CrowdSec は正常終了するので、
導入時に必ず目で確認する（全件パース失敗が黙って続くのが一番危ない）。
