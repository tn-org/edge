# AWS 側監視のセットアップ（外形監視・RDS 空き容量）

自前ハブ（console）は EC2 上にあるため、EC2 ごと死ぬと通知も一緒に沈黙する。
その盲点を埋める 2 つだけ AWS マネージド側に置く。どちらも AWS コンソールでの一度きりの手作業。

ホストを新しく立てたときにやる。名前はホストごとに分ける（下の表の `<host>` は
そのホストの識別名。EC2 の Name タグと揃えると探しやすい）。

## 0. SNS トピック（通知の受け口）

リージョンごとに 1 つずつ使う（CloudWatch アラームは同一リージョンのトピックしか選べない）:

| リージョン     | トピック              | 用途                                                      |
| -------------- | --------------------- | --------------------------------------------------------- |
| us-east-1      | `<host>-health-alert` | Route53 外形監視（メトリクスが us-east-1 にしか無いため） |
| ap-northeast-1 | `<host>-infra-alert`  | RDS などインフラのアラーム                                |

どちらも Email 購読が Status = Confirmed であること（新規作成時は確認メールの
Confirm subscription を踏む）。既存のトピックがあれば使い回してよい。

## 1. 外形監視（Route53 ヘルスチェック）

世界各地の AWS チェッカーが約 30 秒間隔で HTTPS を叩き、失敗が続くと SNS へメールする。
EC2・console に一切依存しない「外の目」。料金は 1 本あたり月 $0.75 程度。

このホストで公開している FQDN のうち、落ちたら困るものに 1 本ずつ立てる。目安は
プロジェクトの API（`https://api.<apex>/health`）と console（`https://console.<apex>/health`）の 2 本。
`/health` はデプロイのヘルスチェックが叩いているのと同じパス。

手順（それぞれ）:

1. Route53 → Health checks → Create health check
2. 名前を入力・Endpoint / HTTPS / ドメイン名指定・Path = `/health`
3. Advanced: Failure threshold = 3（約 90 秒の連続失敗で異常判定）
4. 「Create alarm」で Yes → 通知先に SNS `<host>-health-alert`（us-east-1）を選択
   （Health check status が ALARM = 落ちた時と、OK 復帰時にメールが来る）
   ※アラームをあとから CloudWatch で作る場合、メトリクス（HealthCheckStatus）と
   トピックはどちらも us-east-1 側にある点に注意

## 2. RDS・EC2 アラーム（CloudWatch・東京）

データベースを使うプロジェクトを載せているなら、東京リージョンに以下を置く:

- `rds-storage-low` — 空き容量（満杯 = 全サービス停止の予防。残 15% 目安）
- `rds-cpu-high` / `rds-connections-high` — RDS の高負荷・接続枯渇
- `ec2-cpu-high` — EC2 の高負荷

通知先は `<host>-infra-alert`（購読 Confirmed）。見直すときは、しきい値が現在の
割り当てに対して妥当かを確認する。

## 3. console ダッシュボードの「RDS ストレージ」カード

アラームは閾値を超えたときしか教えてくれないので、平常時の余裕を管理画面でも見えるようにする。
空きは CloudWatch の FreeStorageSpace、割り当ては RDS の AllocatedStorage から取る。

必要な権限は `cloudwatch:GetMetricStatistics` と `rds:DescribeDBInstances` の 2 つ。
console が動く EC2 のインスタンスロールに付ける。

対象インスタンスは `DB_HOST`（RDS エンドポイント）の先頭ラベルから自動で決まるので、
env の追加設定は要らない。別インスタンスを見たい時だけ `RDS_INSTANCE_ID` で上書きする。

権限が無い・RDS 以外に繋いでいる場合は AWS を一切呼ばずカードごと非表示になる。
使用率 85% 以上で TOP の「要対応」にも上がる（CloudWatch の rds-storage-low と同じ基準）。

## 4. console の「ファイル保管（S3）」画面

S3 の中身を辿って、実物を確かめて消すところまでを管理画面で完結させる。
容量の内訳で「S3 が大きい」と分かったあと、原因のファイルへ直行するための画面。

権限は 3 段。閲覧はキー名と大きさだけで中身は見えない。ダウンロードと削除は監査ログに残る。

| 操作                   | 必要な権限                        |
| ---------------------- | --------------------------------- |
| バケット・ファイル一覧 | 観測・ログの read                 |
| ダウンロード           | 観測・ログの write                |
| 削除                   | 全権のみ + 対象フルパスの打ち直し |

console が動く EC2 のインスタンスロールに以下を追加する（未設定なら
画面は「AWS が要求を拒否しました」を出すだけで、他の画面には影響しない）:

```json
{
  "Sid": "S3Explorer",
  "Effect": "Allow",
  "Action": [
    "s3:ListAllMyBuckets",
    "s3:GetBucketLocation",
    "s3:GetBucketVersioning",
    "s3:ListBucket",
    "s3:GetObject",
    "s3:DeleteObject"
  ],
  "Resource": "*"
}
```

ダウンロードはファイル本体をサーバーに通さず、5 分で失効する署名付き URL を発行する。
大きいファイルで PHP を占有させないため。URL は必ず添付ファイル扱いになるので、
HTML や SVG が S3 のドメイン上でページとして動くことはない。

## 確認

- Route53: Health checks 一覧で Status = Healthy になること
- 試験: EC2 の Traefik を数分止めればアラームメールが届く（やるなら stag 時間帯に）
- CloudWatch: アラーム一覧で状態 = OK（データ不足のままなら メトリクス選択を再確認）
