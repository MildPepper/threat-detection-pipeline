# Threat Detection & Alerting Engine

A production-grade, event-driven serverless pipeline on AWS that ingests
security events, evaluates risk, archives raw data, and stores structured
threat records — built entirely with Infrastructure as Code (Terraform) and
automated CI/CD (GitHub Actions + tfsec).

Built as a hands-on project to develop production AWS engineering skills
alongside AWS Certified Solutions Architect – Associate (SAA-C03) exam prep.

---

## Architecture

```
                 ┌─────────────────┐
   Event    ───► │  SQS Queue       │
   Producer      │ threat-event-    │
                 │ queue            │
                 └────────┬─────────┘
                          │ triggers
                          ▼
                 ┌─────────────────┐        ┌──────────────────┐
                 │  Lambda          │──────► │  S3               │
                 │  threat-evaluator│  raw   │  raw_events       │
                 │  (Python 3.12)   │  event │  (archival)       │
                 └────────┬─────────┘        └──────────────────┘
                          │ evaluated
                          │ record
                          ▼
                 ┌─────────────────┐
                 │  DynamoDB        │
                 │  threat-records  │
                 └─────────────────┘

   Failed messages (after 10 retries) ──► threat-events-dlq

   All services encrypted with a shared customer-managed KMS key.
   Lambda instrumented with AWS X-Ray tracing.
   CloudWatch dashboard tracks invocations/errors, queue depth,
   and DynamoDB write capacity.
```

**Flow:** an event lands in SQS → triggers Lambda → Lambda evaluates risk
(severity: LOW/MEDIUM/HIGH based on failed-attempt thresholds) → archives the
raw event to S3 → writes the structured, evaluated record to DynamoDB. Failed
messages retry automatically and land in a dead-letter queue after 10 failed
attempts, so nothing is silently lost.

---

## Why this design — trade-off analysis

**SQS in front of Lambda, instead of invoking Lambda directly**
Decouples event producers from the processing logic. A producer doesn't need
to know whether Lambda is healthy, slow, or briefly unavailable — it just
enqueues a message and moves on. SQS also provides built-in retry and a
dead-letter queue, so a transient failure (e.g. a bad permission, a bug) does
not lose the event; it retries automatically and lands somewhere inspectable
if it keeps failing. Direct invocation would couple the producer's
availability to Lambda's, with no automatic retry.

**DynamoDB over RDS for processed records**
The access pattern here is simple key-based lookups (`event_id`), not complex
relational queries or joins. DynamoDB's on-demand capacity mode means paying
per request instead of provisioning and maintaining a running database
instance — appropriate for unpredictable, low-to-moderate event volume. RDS
would add operational overhead (patching, instance sizing, Multi-AZ failover
management) that isn't justified by this access pattern.

**On-Demand (PAY_PER_REQUEST) over Provisioned capacity**
Event volume in this pipeline is unpredictable and currently low. On-demand
avoids paying for idle provisioned throughput and avoids the risk of
under-provisioning causing throttled writes during a burst. If traffic became
large and predictable, provisioned capacity with auto-scaling would likely be
cheaper — a trade-off worth revisiting if this moved toward production scale.

**A single shared customer-managed KMS key across S3, DynamoDB, and SQS**
Centralizes key management and rotation (rotation enabled, 7-day deletion
window) rather than using AWS's default managed keys, which don't allow
fine-grained access control over who/what can use the key. All three services
share one key here for simplicity at this project's scale; a larger
production system might use per-service keys for tighter blast-radius control
if one key were ever compromised.

**Accepted tfsec finding: `access_logs` bucket does not log itself**
`tfsec` flags every S3 bucket without logging enabled, including the
`access_logs` bucket that exists solely to receive access logs from
`raw_events`. Enabling logging on the logging bucket itself would create a
recursive logging loop with no security benefit, since it holds only log
metadata, not sensitive application data. This is a deliberate, documented
exception rather than an oversight — the scan currently passes 41/42 checks,
with this one finding consciously accepted.

---

## Security posture

- **Least-privilege IAM throughout.** Every permission was added individually
  and scoped to a specific action on a specific resource ARN — no
  `AdministratorAccess` on the Lambda execution role. Each grant (SQS
  receive/delete, S3 PutObject, DynamoDB PutItem, KMS decrypt, X-Ray trace
  submission) was added only when the pipeline actually needed it, verified
  by triggering the real `AccessDenied` error first.
- **Encryption at rest everywhere.** S3 (both buckets), DynamoDB, and both SQS
  queues use a shared customer-managed KMS key with automatic key rotation
  enabled.
- **S3 public access fully blocked** on both buckets (block public ACLs,
  block public policy, ignore public ACLs, restrict public buckets).
- **Versioning enabled** on both S3 buckets, protecting against accidental or
  malicious overwrite/delete.
- **DynamoDB point-in-time recovery enabled**, allowing restoration to any
  point in the last 35 days.
- **X-Ray tracing active** on Lambda for distributed tracing across the
  pipeline.
- **Automated security scanning** via `tfsec` on every push, gating merges to
  `main` (see CI/CD below).

---

## CI/CD pipeline

GitHub Actions workflow (`.github/workflows/terraform-check.yml`) runs on
every push and pull request to `main`:

1. **Checkout code**
2. **Terraform format check** (`terraform fmt -check`) — enforces consistent
   style, non-blocking
3. **Package Lambda function** — zips `lambda_function.py` fresh from source
   on every run, rather than committing a pre-built artifact to git
4. **Terraform init** (no backend, no real credentials used in CI)
5. **Terraform validate** — catches syntax/config errors before any human
   would need to
6. **tfsec security scan** — flags misconfigurations against AWS security
   best practices

This pipeline does not currently apply changes to real AWS infrastructure
automatically (no AWS credentials are stored in GitHub Actions) — it acts as
a validation and security gate only. `terraform apply` is run manually, with
review, from a local machine.

---

## Cost estimate (approximate, low/dev traffic)

| Service | Notes | Est. monthly cost |
|---|---|---|
| Lambda | Free tier: 1M requests + 400,000 GB-s/month | ~$0 at this scale |
| SQS | Free tier: 1M requests/month | ~$0 at this scale |
| DynamoDB (on-demand) | Pay per read/write request | ~$0–1 at this scale |
| S3 | Storage + PUT requests, minimal volume | ~$0–1 |
| KMS | $1/month per key + $0.03 per 10,000 requests | ~$1 |
| CloudWatch | Dashboard + basic alarms | ~$0–3 |
| **Total** | | **~$2–6/month** at current dev/test volume |

At meaningful production traffic, DynamoDB and Lambda costs would scale with
request volume; SQS and S3 remain comparatively cheap. KMS is a fixed cost
per key regardless of volume.

---

## Repository structure

```
.
├── main.tf                          # All infrastructure (imported from
│                                     # hand-built resources, then hardened)
├── lambda_function.py                # Lambda source code
├── .github/workflows/
│   └── terraform-check.yml           # CI: format check, validate, tfsec
└── .gitignore                        # Excludes state files, zips, credentials
```

---

## What this project demonstrates

- Migrating hand-built (console-created) AWS infrastructure into Terraform
  via `terraform import`, without downtime — including diagnosing and safely
  resolving state drift and a destructive "replace" plan before applying.
- Debugging real IAM `AccessDenied` errors by reading CloudWatch logs and
  granting precisely the missing permission, rather than defaulting to broad
  access.
- Iteratively hardening infrastructure against automated security scanning
  (15 → 1 tfsec findings), and making a deliberate, documented judgment call
  on the one remaining finding rather than mechanically "fixing" everything.
- Building a CI/CD quality gate (format check, validation, security scanning)
  that runs automatically on every push.

---

## Possible next steps

- Add a WAF in front of an API Gateway if this pipeline were extended to
  accept events over HTTP rather than only via SQS (not currently applicable,
  since there is no internet-facing endpoint).
- Move `terraform apply` into the CI/CD pipeline itself (with stored,
  restricted AWS credentials) for full automated deployment, rather than
  manual local apply.
- Split the single shared KMS key into per-service keys for tighter
  blast-radius control at larger scale.