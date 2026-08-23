# edge

サーバー 1 台の**ホスト層**を配る repo。全ホストで中身が同じ 1 つの repo（`tn-org/edge`）で、
各ホストへそのまま clone して使う。テンプレではないのでプレースホルダの置換は無い。
ホストごとに違う値はすべて `.env`（git 管理外）にある。

置いているもの:

| 置き場                                | 役割                                                                      |
| ------------------------------------- | ------------------------------------------------------------------------- |
| `docker-compose.yml`                  | Traefik v3（80/443・ACME）と CrowdSec。共有ネットワークへ external で参加 |
| `traefik/`                            | 静的設定のテンプレートと、ホスト共通の動的設定（TLS・ミドルウェア）       |
| `crowdsec/`                           | acquisition（Traefik のアクセスログ）と有効化する collection              |
| `systemd/` `logrotate/` `auto-patch/` | ホスト保守のタイマー・ログ回転・OS 自動更新                               |
| `scripts/`                            | セットアップ・デプロイ・通知・遮断操作                                    |

**プロジェクト固有のものは何も無い。** ドメイン・upstream・証明書の対応表は持たない。
公開の宣言は各プロジェクトの compose の Traefik ラベルが持ち、証明書は Traefik の ACME が
自動で取る。運用コンソール（console）も各プロジェクトの repo が持ち、
サーバー上は `/app/<slug>/console` で動く。

```
EC2 1 台
 ├ /app/edge                 この repo。Traefik + CrowdSec + systemd timer + ホスト通知
 │                             共有 docker network（既定名 edge）をホストに 1 本
 ├ /app/<slug>/main/prod     backend。compose のラベルで公開 FQDN を宣言するだけで外に出る
 ├ /app/<slug>/main/stag     同上
 ├ /app/<slug>/console       console
 └ /app/<slug2>/...          2 つ目以降も同じ。edge は何も変えない
```

## 新しいホストを立てる

サーバー側（EC2 に SSM か SSH で入る。作業ユーザーは `ssm-user`）:

1. repo を置き場へ clone する（パスは固定）
   ```
   sudo mkdir -p /app && sudo chown ssm-user:ssm-user /app
   git clone git@github.com:tn-org/edge.git /app/edge
   ```
2. `.env` を作って値を入れる
   ```
   cd /app/edge
   cp .env.example .env
   make env
   ```
   埋めるのは `APP_ENV=production` と `ACME_EMAIL`・`INTERNAL_TOKEN`・`CROWDSEC_BOUNCER_KEY`。
   秘密の 2 つは `openssl rand -hex 32` で作る。`INTERNAL_TOKEN` はこのホストの
   main / console と同じ 1 値にする。`EDGE_NETWORK` と `OPS_NOTIFY_URL` は既定のままでよい。
3. 一括セットアップを流す（再実行可・冪等）
   ```
   make setup
   ```
   共有ネットワーク作成 → 設定生成 → Traefik / CrowdSec 起動 → `/etc` と systemd タイマーの
   反映（logrotate・OS 自動更新・遮断レポート・ディスク記録・ホスト同期）まで入る。
4. 確認
   ```
   make ps
   docker compose logs traefik | grep -i acme
   docker compose exec crowdsec cscli metrics
   ```
   `cscli metrics` の acquisition が 0 行のままなら CrowdSec がログを読めていない。
   この状態でも正常終了するので必ず目で見る。

GitHub 側（このホストへ自動デプロイさせる設定。1 ホスト目で作り、2 台目以降は 5 だけ）:

5. repo variable `SSM_INSTANCE_IDS` にインスタンス ID を足す（空白区切りで複数可）
   ```
   gh variable set SSM_INSTANCE_IDS --repo tn-org/edge --body "i-0aaa... i-0bbb..."
   ```
   ここに並んだホストへ、main への push のたびに同じ反映が matrix で流れる。
6. repo secret `AWS_ROLE_ARN` に、SSM を叩ける IAM ロールの ARN を入れる
   ```
   gh secret set AWS_ROLE_ARN --repo tn-org/edge
   ```
7. その IAM ロールの信頼ポリシーに、この repo の OIDC sub を足す。
   足す値は次のコマンドで確認する（`repo:tn-org/edge:` が返る）
   ```
   gh api repos/tn-org/edge/actions/oidc/customization/sub --jq .sub_claim_prefix
   ```
   条件は `token.actions.githubusercontent.com:sub` を `repo:tn-org/edge:ref:refs/heads/main`
   に対して StringLike で許可する形。
8. サーバーが git を引けるようにする。この repo に deploy key（read-only）を登録し、
   秘密鍵をサーバーの `ssm-user` に置く
   ```
   ssh-keygen -t ed25519 -C "edge deploy key (<hostname>)" -f ~/.ssh/id_ed25519 -N ""
   ```
   公開鍵を GitHub の Settings → Deploy keys に「Allow write access」なしで登録する。
   ホストごとに別の鍵にする（1 台失っても他へ波及させないため）。

secrets / variables が空のままだと、release workflow は guard job が notice を出して
何もせず退出する。設定が済めば次の push から自動で流れる。

## プロジェクトを載せる

**edge 側の作業は無い。** プロジェクトの compose にラベルを足すだけで公開される。

```yaml
services:
  backend:
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<slug>-${APP_ENV}.rule=Host(`${PUBLIC_HOST:?PUBLIC_HOST が未設定}`)"
      - "traefik.http.routers.<slug>-${APP_ENV}.entrypoints=websecure"
      - "traefik.http.services.<slug>-${APP_ENV}.loadbalancer.server.port=8000"
    networks: [edge]

networks:
  edge:
    external: true
    name: ${EDGE_NETWORK:-edge}
```

- 公開 FQDN はコンテナごとに `.env` の `PUBLIC_HOST` で持つ。未設定なら `:?` で起動を拒否する
- ラベルは配列形式で書く（マッピングのキー側では compose の変数展開が効かない）
- ホストへのポート publish は要らない。console だけは `127.0.0.1:9090:9090` を残す
  （ホストの `report.sh` / `notify.sh` が docker の外から送るため）
- TLS・レート制限・セキュリティヘッダ・遮断は entrypoint の既定ミドルウェアで全ルーターに
  効く。ラベルで指定しなくてよい
- `/internal/` の外部遮断は各プロジェクトの backend 側で行う（`X-Forwarded-For` 付きの
  `/internal/` は 404）。プロキシの種類に依存しない形にしてある

## `.env` のキー

| キー                   | 既定                    | 説明                                                                                        |
| ---------------------- | ----------------------- | ------------------------------------------------------------------------------------------- |
| `APP_ENV`              | `local`                 | `local` = 開発機 / それ以外 = サーバー。sudo の要否と server 専用コマンドのガードに使う     |
| `EDGE_NETWORK`         | `edge`                  | ホストに 1 本置く共有 docker network の名前。edge と各プロジェクトが external で参加する    |
| `ACME_EMAIL`           | —                       | Let's Encrypt の登録メールアドレス（期限切れ通知の宛先）                                    |
| `INTERNAL_TOKEN`       | —                       | 内部通信の共有シークレット。同じホストの main / console / ホスト層で同一の 1 値             |
| `OPS_NOTIFY_URL`       | `http://127.0.0.1:9090` | 通知ハブ（console）の向き先。別ホストへ置いたときだけ変える                                 |
| `CROWDSEC_BOUNCER_KEY` | —                       | Traefik の bouncer と CrowdSec LAPI の共有シークレット。未設定だと compose が起動を拒否する |

秘密の 2 つ（`INTERNAL_TOKEN`・`CROWDSEC_BOUNCER_KEY`）は
`openssl rand -hex 32` で作る。`.env` は git 管理外で、サーバー上にしか無い。
過不足の照合は `make env CMD=check`。

## もっと知る

- コマンド一覧と実行場所ルール: `docs/commands.md`
- 遮断の設計: `docs/abuse-blocking-design.md`
- AWS 側の監視（外形監視・RDS）: `docs/aws-monitoring-setup.md`
- repo の構造と契約: `CLAUDE.md`
