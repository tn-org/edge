# make コマンド一覧

Makefile は repo ルート 1 本。この repo が持つのはホスト層（Traefik・CrowdSec・systemd・
logrotate・OS 自動更新）だけで、運用コンソール（console）は各プロジェクトの repo
（サーバー上は `/app/<slug>/console`）が持つ。console の make コマンドはそちらの
`docs/commands.md` が正。

**ドメインと証明書のコマンドは無い。** 公開の宣言は各プロジェクトの compose の
Traefik ラベルが持ち、証明書は Traefik の ACME が自動で取る。

実行場所は root `.env` の `APP_ENV` で判定する（`local` = 開発機 / それ以外 = サーバー）。
server 専用コマンドを local で叩くと即エラー + 正しい手順を 1 行表示する。
必須引数が未指定のときは、tty あり → 対話で聞く / tty なし → usage 表示 + exit 1（CI/SSM をハングさせない）。

## コマンド表

### スタック運用

| コマンド       | 用途                            | 引数                                                | 実行場所 | 呼び出し元         |
| -------------- | ------------------------------- | --------------------------------------------------- | -------- | ------------------ |
| `make up`      | Traefik / CrowdSec 起動         | —                                                   | 両方     | 手動・setup.sh     |
| `make down`    | Traefik / CrowdSec 停止         | —                                                   | 両方     | 手動               |
| `make restart` | Traefik / CrowdSec 再起動       | —                                                   | 両方     | 手動               |
| `make ps`      | 稼働状況                        | —                                                   | 両方     | 手動・setup.sh     |
| `make logs`    | ログ閲覧                        | `TARGET=access\|container` `[DOMAIN=]` `[SERVICE=]` | 両方     | 手動               |
| `make render`  | `.env` の値を設定ファイルへ反映 | —                                                   | 両方     | up・deploy-host.sh |

- `logs TARGET=access` は Traefik の JSON アクセスログ 1 本を流す。`DOMAIN=` を付けると
  その宛先の行だけに絞る（ドメイン別のログファイルは存在しない）。
- `render` が作るのは `traefik/generated/`（静的設定・LAPI キー）と
  `crowdsec/generated/`（除外リスト）。どれも git 管理外。
- 設定を反映するのに reload コマンドは要らない。ルーティングは docker のイベント、
  `traefik/dynamic/` はファイル watch で自動的に読み直される。

### デプロイ

| コマンド           | 用途                          | 引数 | 実行場所 | 呼び出し元               |
| ------------------ | ----------------------------- | ---- | -------- | ------------------------ |
| `make deploy-pull` | Git を origin/main へ強制追従 | —    | server   | 手動（CI は git 直書き） |

main への push で `release.yml` が SSM 経由で「git 追従 → `scripts/deploy-host.sh`」を流す。
`deploy-host.sh` は設定を生成して `compose up -d --remove-orphans` するだけで、
静的設定（`traefik/traefik.yml`・`crowdsec/`）が変わったときだけコンテナを入れ替える。
`/etc` 配下・systemd に関わる変更は自動では入らない（`make host-apply` を手で流す）。

### 監視・保守

| コマンド            | 用途                                       | 引数                                                       | 実行場所 | 呼び出し元                        |
| ------------------- | ------------------------------------------ | ---------------------------------------------------------- | -------- | --------------------------------- |
| `make host-apply`   | ホスト側設定の一括反映（logrotate・timer） | —                                                          | server   | 手動・setup.sh                    |
| `make ban`          | 遮断・除外リスト操作（無引数=対話）        | `[CMD=list\|ban\|unban\|allow\|disallow\|allowed]` `[IP=]` | server   | 手動・管理画面からの操作要求      |
| `make bans`         | 遮断状況を表示（通知抑止・表示のみ）       | —                                                          | server   | 手動                              |
| `make docker-prune` | 未使用 docker イメージの削除               | —                                                          | server   | 手動（週次は docker-prune.timer） |

- `ban CMD=ban` の遮断は既定 24 時間。`BAN_DURATION=72h make ban CMD=ban IP=…` で変えられる。
- `allow` / `disallow` は除外リスト（`crowdsec/generated/allowlist.tsv`）を書き換えて
  CrowdSec を再起動する（数秒）。除外した IP はそもそも遮断の判断対象から外れる。
- 操作名は fail2ban 時代のまま。管理画面から積まれる操作要求の `action` がこの名前のため。

### 環境・初回

| コマンド     | 用途                                                   | 引数                                                    | 実行場所 | 呼び出し元                        |
| ------------ | ------------------------------------------------------ | ------------------------------------------------------- | -------- | --------------------------------- |
| `make env`   | .env 設定（無引数=対話 / KEY= VALUE= で 1 キー直設定） | `[KEY= VALUE=]` `[CMD=check]`（照合のみ・読み取り専用） | 両方     | 手動                              |
| `make setup` | 初回セットアップ一括 wizard（再実行可・冪等）          | —                                                       | 両方     | 手動（server はホスト初期化込み） |

初回に埋めるのは 4 つ。`APP_ENV` / `ACME_EMAIL` / `INTERNAL_TOKEN` / `CROWDSEC_BOUNCER_KEY`。
残る `EDGE_NETWORK` と `OPS_NOTIFY_URL` は既定のままでよい（キーの一覧は `README.md`）。

- `CROWDSEC_BOUNCER_KEY` は Traefik の bouncer と CrowdSec の共有シークレット。
  `openssl rand -hex 32` で作って `.env` に置くと、compose が起動時に CrowdSec へ
  `traefik` という名前の bouncer として登録する。手で `cscli bouncers add` する必要は無い。
  すでに別のキーで登録されている場合は `cscli bouncers delete traefik` してから起動し直す。
- `INTERNAL_TOKEN` は同じホストの main / console / ホスト層で同じ 1 値。
- `EDGE_NETWORK` を変えたら、そのホストの全プロジェクトの `.env` も揃える
  （共有ネットワークの実名なので片方だけ変えると繋がらなくなる）。

## 自動実行の一覧（時刻は全て JST）

ホスト側で人が触らなくても動くもの全部。console コンテナ内の scheduler が回すぶんは
console repo 側の一覧が正で、両方あわせた実物は管理画面の **サーバー管理 → 自動実行** で見られる。
名前に「日次」「週次」は入れない（間隔の列で分かるため）。

| 時刻              | 名前                                                      | 実行主体       | 設定場所                                           | 結果の届き方         |
| ----------------- | --------------------------------------------------------- | -------------- | -------------------------------------------------- | -------------------- |
| 毎日 04:00        | OS セキュリティ自動更新                                   | systemd        | dnf-automatic.timer（setup-auto-patch.sh）         | 異常時メール         |
| 毎日 08:00        | 不正アクセス遮断の記録                                    | systemd        | report-bans.timer（setup-bans.sh）                 | 異常時メール         |
| 毎日 08:20        | 再起動待ちの検知（kernel 更新が未反映の間だけ毎日鳴らす） | systemd        | report-reboot-check.timer（setup-reboot-check.sh） | 待ちがある日はメール |
| 毎日 08:30        | ディレクトリ別ディスク使用量の記録                        | systemd        | report-disk-usage.timer（setup-disk-usage.sh）     | 異常時メール         |
| 5 分ごと          | ホスト側の状態取得と操作実行                              | systemd        | host-sync.timer（setup-host-sync.sh）              | 異常時メール         |
| 日曜 06:00        | 未使用 docker イメージの削除                              | systemd        | docker-prune.timer（setup-docker-prune.sh）        | 異常時メール         |
| 月曜 週次         | GitHub Actions の参照更新 PR                              | GitHub Actions | .github/dependabot.yml                             | PR が立つ            |
| main への push 時 | サーバーの git 追従 → compose 反映                        | GitHub Actions | .github/workflows/release.yml                      | Actions が赤         |

TLS 証明書の自動更新（旧 cert-renew.timer）と遮断リストの保存・復元（旧 ipset-persist.service）は
一覧から消えた。証明書は Traefik の ACME が期限前に自分で更新し、遮断は CrowdSec の DB
（名前付き volume）に残るので、どちらも timer が要らなくなったため。

届き方の 3 種:

- **毎回メール**: 毎朝 08:50 のシステムレポート 1 通だけ（送信主体は console）。届かない日は経路か scheduler の異常
- **異常時メール**: error と warning はシステムログに入った時点で即時メールになる。平常時は無音
- **画面のみ**: 管理画面のシステムログに残るだけ

systemd の前提:

- ホストで動く。全て `Persistent=true` + `RandomizedDelaySec` 付きで、
  停止中に飛んだ回は次回起動時に回収する。失敗は `notify-failure@` が拾って通知ハブへ送る
- 導入は初回のみ手動（`scripts/setup-*.sh`。`make setup` / `make host-apply` から一括でも入る）

OS が最初から持っている timer（man の索引更新・locate の索引更新など）は一覧に載せない。
ホスト側（report.sh の emit_unit）で、こちらが運用している unit 名だけに絞っている。
logrotate は unit こそ OS のものだが設定はこちらが配っているので出す。
