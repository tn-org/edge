# AWS-side monitoring setup (external checks, database free space)

The notification hub runs on the server itself, so if the instance dies the notifications
die with it. Two things are therefore placed on AWS managed services to cover that blind
spot. Both are one-off manual steps in the AWS console.

Do this when you bring up a new host, and name things per host (`<host>` below is that
host's identifier; matching the instance's Name tag makes it easy to find).

## 0. SNS topics (where notifications land)

One topic per region, because a CloudWatch alarm can only target a topic in its own
region:

| Region         | Topic                 | Used for                                                       |
| -------------- | --------------------- | -------------------------------------------------------------- |
| us-east-1      | `<host>-health-alert` | Route 53 health checks (their metrics exist only in us-east-1) |
| ap-northeast-1 | `<host>-infra-alert`  | Infrastructure alarms such as RDS                              |

Both need an email subscription with Status = Confirmed (follow the confirmation mail when
creating one). Reusing an existing topic is fine.

## 1. External checks (Route 53 health checks)

AWS checkers around the world hit the endpoint over HTTPS roughly every 30 seconds and
send mail through SNS after repeated failures. It is an outside observer that depends on
neither the instance nor the ops console. Cost is around $0.75 per check per month.

Create one check for each FQDN on this host whose downtime would matter. Typically that is
the application API (`https://api.<apex>/health`) and the ops console
(`https://console.<apex>/health`). `/health` is the same path the deployment health check
uses.

For each one:

1. Route 53 → Health checks → Create health check
2. Enter a name, choose Endpoint / HTTPS, specify the domain name, set Path = `/health`
3. Advanced: Failure threshold = 3 (about 90 seconds of continuous failure)
4. Choose "Create alarm" → Yes, and select the SNS topic `<host>-health-alert`
   (us-east-1). Mail arrives both when the check goes to ALARM and when it recovers.
   If you create the alarm later in CloudWatch instead, remember that both the
   `HealthCheckStatus` metric and the topic live in us-east-1.

## 2. RDS and EC2 alarms (CloudWatch, application region)

If the host runs an application with a database, add these in the application's region:

- `rds-storage-low` — free space; a full disk stops every service (aim for 15% remaining)
- `rds-cpu-high` and `rds-connections-high` — database load and connection exhaustion
- `ec2-cpu-high` — instance load

Send them to `<host>-infra-alert` (subscription Confirmed). When revisiting these, check
that the thresholds still make sense for the current allocation.

## 3. The database storage card in the ops console

Alarms only speak up once a threshold is crossed, so the console also shows the everyday
headroom. Free space comes from the CloudWatch `FreeStorageSpace` metric and the
allocation from the RDS `AllocatedStorage` attribute.

The two permissions needed are `cloudwatch:GetMetricStatistics` and
`rds:DescribeDBInstances`, attached to the instance role of the machine running the ops
console.

The target instance is derived from the first label of `DB_HOST` (the RDS endpoint), so no
extra environment configuration is required. Set `RDS_INSTANCE_ID` only to point at a
different instance.

Without the permissions, or when connected to something other than RDS, the console makes
no AWS calls and simply hides the card. At 85% usage or above it is also raised on the
dashboard as needing attention, the same threshold as the `rds-storage-low` alarm.

## 4. The object storage browser in the ops console

This screen walks the contents of S3 so you can confirm what a file is and delete it
without leaving the console. It is the way to get from "the capacity breakdown says object
storage is large" to the actual file.

Permissions come in three levels. Listing shows key names and sizes only, never content.
Downloads and deletions are written to the audit log.

| Action                 | Permission required                             |
| ---------------------- | ----------------------------------------------- |
| List buckets and files | read on observability and logs                  |
| Download               | write on observability and logs                 |
| Delete                 | full access, plus retyping the full object path |

Add the following to the instance role of the machine running the ops console. Without it
the screen only reports that AWS rejected the request, and nothing else is affected.

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

Downloads do not pass the file through the server; the console issues a presigned URL that
expires in five minutes, so large files never tie up an application process. The URL always
forces an attachment, so HTML or SVG cannot execute as a page on the storage domain.

## Verification

- Route 53: the health check list shows Status = Healthy.
- A live test: stop Traefik for a few minutes and the alarm mail arrives. Do it in a quiet
  window.
- CloudWatch: the alarm list shows OK. If an alarm stays in insufficient data, re-check the
  metric selection.
