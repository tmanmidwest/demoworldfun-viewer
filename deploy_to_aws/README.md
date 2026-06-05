# demoworldfun-viewer — AWS ECS Fargate Scripts

Deploy, manage, update, and tear down the inbox viewer on your own AWS account.
Each person runs these against their own account — fully isolated instances.

> These scripts deploy the **viewer** only. They read from an existing SES
> pipeline (DynamoDB table + S3 bucket). Stand that backend up first; these
> scripts never create or delete it.

---

## What you need

- **AWS account** with permissions for ECS, ECR, EC2, ELB, IAM, plus read on
  your DynamoDB table and S3 bucket
- **AWS CLI v2**, **Docker Desktop**, **Git**, **Python 3**
- An existing SES backend: a DynamoDB table (with a `global-index` GSI) and an
  S3 bucket that your SES receipt rule writes to

**Deploy in the same AWS region as that backend.** The viewer talks to the
table and bucket directly; keeping everything in one region avoids cross-region
surprises.

---

## Quick start

```bash
chmod +x setup.sh deploy.sh manage.sh update.sh teardown.sh restore-state.sh

./setup.sh     # checks tools, AWS access, AND that your table + bucket exist
./deploy.sh    # builds from GitHub, pushes to your ECR, stands up ALB + Fargate
```

`deploy.sh` asks for your domain first and suggests the table name, bucket name,
and app title from it (e.g. `acme.com` → `acme-messages` / `acme-inbound-mail`);
you can override any of them. It then asks for the S3 prefix and an optional
login (username + password). It verifies the backend exists before
building anything, prints your URL when done, and writes a
`.demoworldfun-viewer-state` file tracking your resource IDs.

---

## Day-to-day

```bash
./manage.sh status     # running? what's the URL?
./manage.sh stop       # pause — Fargate charges stop, data untouched
./manage.sh start      # resume
./manage.sh restart    # restart / re-pull image
./manage.sh logs       # stream live logs
./manage.sh url        # print the URL
```

## Updating

```bash
./update.sh
```

Pulls the latest `main` from `tmanmidwest/demoworldfun-viewer`, rebuilds the
image, pushes it, and redeploys. Your login and config persist — they live in
the task definition, not the image.

## Removing everything

```bash
./teardown.sh          # type 'delete' to confirm
```

Deletes the ECS service/cluster, ALB, target group, security groups, log group,
ECR repo, and the IAM task role. **Your SES backend (table + bucket) is not
touched.**

## Second machine

The state file lives only where you deployed. On another machine:

```bash
./restore-state.sh             # default region
./restore-state.sh us-east-1   # or the region you deployed to
```

Read-only discovery — rebuilds the state file from live AWS resources so the
other scripts work. It contains resource IDs and non-secret config only; the
login and session secret stay in the running task definition.

---

## How it differs from the hrDemoWebApp scripts

If you know that suite, the differences here are:

- **No EFS.** The viewer is stateless (reads DynamoDB + S3), so there's no
  filesystem, access point, or mount targets to create or delete.
- **A dedicated task role.** The running container needs to read DynamoDB and
  S3, so `deploy.sh` creates `demoworldfun-viewer-task-role` with a scoped
  policy: `dynamodb:Query` + `dynamodb:DeleteItem` on the table + `global-index`,
  and `s3:GetObject` + `s3:DeleteObject` on the bucket (the Delete button needs
  the two delete actions). `teardown.sh` removes it.
- **Login + config travel in the task definition** as env vars, set once at
  deploy. The state file stays free of secrets.
- **No `fix-image.sh`.** That script existed to migrate hrDemoWebApp off GHCR;
  this suite builds straight to ECR from the first deploy, so it's unnecessary.

---

## Notes

- The ALB listener is plain **HTTP:80**. For HTTPS, add an ACM cert + a 443
  listener and set `SECURE_COOKIES=true` on the task (so the session cookie is
  marked Secure). The login still works over HTTP for internal/demo use.
- The session secret is stored inline in the task definition. For stricter
  setups, move `SESSION_SECRET` / `AUTH_PASS_HASH_B64` into SSM Parameter Store
  (SecureString) and reference them via the task def `secrets` block — the
  execution role then needs `ssm:GetParameters`.
- One deployment per account/region is assumed (resources are looked up by
  name), matching the isolation model.

## Script reference

| Script | Purpose |
|---|---|
| `setup.sh` | Check prerequisites + that the backend exists |
| `deploy.sh` | Full deployment from scratch |
| `manage.sh` | stop / start / restart / logs / status / url |
| `update.sh` | Rebuild from GitHub and redeploy |
| `restore-state.sh` | Rebuild the state file from AWS (second machine) |
| `teardown.sh` | Delete all viewer resources (not the backend) |
