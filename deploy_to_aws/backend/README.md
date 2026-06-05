# demoworldfun SES backend — build & teardown

Scripts to stand up (and tear down) the email-receiving pipeline the inbox
viewer reads from: an S3 bucket, a DynamoDB table, a Lambda indexer, and the
SES catch-all receipt rule for your domain.

This is the **backend**. The **viewer** (the web UI) is a separate suite that
reads the table + bucket these scripts create. Build the backend first.

---

## What you need

- An AWS account with access to SES, S3, DynamoDB, Lambda, and IAM
- **AWS CLI v2**, **Python 3**, **zip**, and ideally **dig** (to auto-check MX)
- **Control of your domain's DNS** — you'll add a TXT and an MX record
- A region that supports **SES email receiving** (e.g. `us-east-1`, `us-west-2`,
  `eu-west-1`; `setup.sh` checks this). Use the same region as the viewer.

---

## The one manual step: DNS

AWS can't edit your DNS, so `build.sh` does everything else, then **prints a TXT
and an MX record and pauses** while you add them at your DNS provider. It then
verifies the domain (and checks the MX) before creating the receipt rule. This
is the only point that needs you.

---

## Build

```bash
chmod +x setup.sh build.sh teardown.sh
./setup.sh     # prerequisites + region/permission checks
./build.sh     # provisions everything; prompts for domain, names, and retention
```

`build.sh` prompts for:

- **Domain** (default `demoworldfun.net`)
- **Bucket** / **Table** names — suggested from the domain you enter
  (e.g. `acme.com` → `acme-inbound-mail` / `acme-messages`); override if you
  like, but they must match what the viewer is pointed at
- **S3 prefix** (default `inbox/`)
- **Retention in days** (default `30`) — applied to *both* the DynamoDB TTL and
  the S3 lifecycle rule, so indexed messages and raw emails expire together

When it finishes, send a test email to `anything@yourdomain` and check
`aws s3 ls s3://<bucket>/<prefix>`.

---

## Teardown

```bash
./teardown.sh          # type 'delete' to confirm
```

It **refuses to run if the viewer is still deployed**, because the viewer reads
this backend — pulling it out from under a running viewer would break it. Tear
the viewer down first (its own `./teardown.sh`). To override in an edge case:

```bash
FORCE=1 ./teardown.sh
```

Teardown deletes the receipt rule set, SES identity, Lambda + role, DynamoDB
table, and S3 bucket (all received email is lost). It then reminds you which
DNS records to remove by hand.

---

## What gets created

| Resource | Name (default) | Purpose |
|---|---|---|
| S3 bucket | `demoworldfun-inbound-mail` | Raw emails (private, lifecycle-expired) |
| DynamoDB table | `demoworldfun-messages` | Message index + `global-index` GSI + TTL |
| Lambda | `demoworldfun-index` | Indexes each inbound email into DynamoDB |
| IAM role | `demoworldfun-index-role` | Lambda execution (PutItem + GetObject) |
| SES identity | your domain | Verifies you own the domain |
| SES rule set | `demoworldfun-rules` | Catch-all rule → S3 then Lambda |

The Lambda source is inlined into `build.sh` (written to a temp file and zipped
at build time), so the suite is self-contained — there's no separate Lambda
file to keep in sync. The retention you choose becomes its `TTL_DAYS`.

## Notes

- One backend per account/region (resources use fixed names), matching the
  viewer's isolation model.
- DKIM is intentionally skipped — it's a *sending* feature and this pipeline
  only receives. Verification needs just the TXT record + MX.
- If you customize the bucket/table names, set the same values in the viewer
  (its deploy prompts), or the viewer won't find the data.

## Script reference

| Script | Purpose |
|---|---|
| `setup.sh` | Check tools, region (SES-receiving), and permissions |
| `build.sh` | Provision the full pipeline (prompts for retention + DNS) |
| `teardown.sh` | Remove everything (guarded against a live viewer) |
