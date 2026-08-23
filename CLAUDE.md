# edge

**ホスト層**だけを持つ repo。1 台のサーバー（EC2）の「箱」側を丸ごとここで配る:

- **Traefik v3**: リバースプロキシ。ルーティングは各プロジェクトの compose のラベルで
  自動検出する（docker provider）。TLS 証明書は内蔵の ACME が発行・更新する
- **CrowdSec**: 不正アクセスの検知。Traefik のアクセスログを読んで遮断を決め、
  Traefik 側の bouncer プラグインが実際に弾く
- **ホスト保守**: systemd タイマー（ディスク・遮断記録・再起動待ち・ホスト同期）・
  logrotate・OS 自動更新（dnf-automatic）・`scripts/` のホスト運用スクリプト

**全ホストで中身が同じ 1 つの repo**（`tn-org/edge`）。テンプレではなく実体で、各ホストへ
そのまま clone して使う。ホストごとに違う値はすべて `.env`（git 管理外）にあり、
repo 本体にプロジェクト名もドメインもホスト固有のパスも書かない。置き場は `/app/edge` 固定。

運用コンソール（console）は**この repo には無い**。各プロジェクトの repo が持ち、
サーバー上は `/app/<slug>/console` で自分でデプロイする。

## プロジェクトを足すときに edge は触らない

公開の宣言は各プロジェクトの compose のラベルが持つ。edge にはドメインも upstream も
書かない（書く場所自体を無くしてある）。

```yaml
services:
  backend:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<name>.rule=Host(`${PUBLIC_HOST:?PUBLIC_HOST が未設定}`)"
      - "traefik.http.routers.<name>.entrypoints=websecure"
      - "traefik.http.services.<name>.loadbalancer.server.port=8000"
    networks: [edge]
```

ホストへのポート publish は要らない（Traefik が共有ネットワーク経由で届く）。
TLS・レート制限・セキュリティヘッダ・遮断は entrypoint の既定ミドルウェアで全ルーターに
効くので、ラベルで指定しなくてよい。プロジェクト固有のミドルウェアだけ自分のラベルで足す。

## console との境界（変えてはいけない契約）

ホスト層は console に依存しないが、次の 2 点だけは接点として固定されている:

- `scripts/notify.sh` / `scripts/report.sh` は運用通知ハブ（console の `/internal/notify` ほか）へ
  `.env` の `OPS_NOTIFY_URL`（既定 `http://127.0.0.1:9090`）で送る。認証は `.env` の `INTERNAL_TOKEN`。
  遮断の同期口は `/internal/fail2ban` のまま（中身が CrowdSec になっても JSON の形は変えていない。
  fail2ban の「ジェイル」に当たるものは CrowdSec のシナリオ名）
- console の公開は console 側 compose の Traefik ラベルが持つ。両者は共有ネットワーク
  （`.env` の `EDGE_NETWORK`・既定 `edge`。external な docker network）で繋がる

## 設定の生成（.env → 実体）

Traefik の静的設定と CrowdSec の LAPI キーは、ファイルの中で環境変数を展開できない。
`scripts/render-config.sh` が `.env` の値（`ACME_EMAIL`・`EDGE_NETWORK`・`CROWDSEC_BOUNCER_KEY`）を
埋めて `traefik/generated/` と `crowdsec/generated/` へ書き出す（どちらも git 管理外）。
`make up` / `deploy-host.sh` が自動で走らせるので、手で叩くのは値を変えた直後に反映を
急ぐときだけ（`make render`）。

## デプロイ

main への push で `release.yml` が SSM 経由でサーバーの git を `origin/main` へ追従させ、
`scripts/deploy-host.sh`（設定生成 → `compose up -d`）を流す。対象ホストは repo variable
`SSM_INSTANCE_IDS`（空白区切り）で、書いてあるぶんだけ matrix で同じ反映が走る。
ルーティングとミドルウェアは Traefik が watch しているので入れ替えは要らない。
静的設定（`traefik/traefik.yml`・`crowdsec/`）が変わったときだけコンテナを入れ替える。
`/etc` 配下・systemd に関わる変更はサーバーで `make host-apply` を手で流す。

新しいホストの立て方は `README.md`、コマンド一覧と実行場所ルールは `docs/commands.md`、
遮断の設計は `docs/abuse-blocking-design.md` を参照。

チーム共通規約は Claude Code plugin `claude@tnlake`（tn-standards）が供給する（SessionStart bootstrap ＋ `core-standards` skill）。
