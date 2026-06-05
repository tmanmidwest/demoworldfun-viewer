# demoworldfun inbox viewer

A small, portable web viewer for the catch-all inbox on `demoworldfun.net`.
It lists inbound emails (indexed in DynamoDB) and renders message bodies
(stored in S3 by Amazon SES).

The whole point of this repo: **the container is the unit of deployment.**
Build the image once and run the *same artifact* anywhere — your Mac, homelab
Docker, or AWS — with no code changes. Where it runs is just a config decision
you can change any time.

## Repo layout

```
app.py               FastAPI viewer (+ optional built-in basic auth)
requirements.txt     Pinned Python deps
Dockerfile           python:3.12-slim, non-root, with healthcheck
docker-compose.yml   For local / homelab runs
.env.example         Copy to .env and fill in
.dockerignore
.gitignore
```

## Configuration

Everything is environment-driven. Copy `.env.example` to `.env` and fill it in.

| Variable | Purpose |
|---|---|
| `AWS_DEFAULT_REGION` | `us-east-1` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Only for local/Docker. **Leave blank on AWS** and use a role. |
| `TABLE_NAME` | `demoworldfun-messages` |
| `BUCKET_NAME` | `demoworldfun-inbound-mail` |
| `S3_PREFIX` | `inbox/` |
| `AUTH_USER` / `AUTH_PASS` | Set both to require login. Leave blank to disable auth. |
| `HOST_PORT` | Host port for compose (default `8100`). |

### How credentials work (the portable bit)

The app never hard-codes credentials. It uses the standard boto3 chain:

- **Local / Docker:** the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` you
  put in `.env` (use the scoped read-only `demoworldfun-viewer` IAM user —
  it can only `dynamodb:Query` the table + index and `s3:GetObject` the bucket).
- **On AWS:** attach an instance/task role with that same read-only policy and
  leave the key variables blank. The SDK picks the role up automatically.

Same image, same code — only the credential source differs.

### Auth

Auth is built into the app so it travels with the container. Set `AUTH_USER`
and `AUTH_PASS` to turn on an HTTP basic login on all view routes. Leave them
blank to disable (e.g. when you front it with Authentik or Cognito). `/healthz`
is always unauthenticated for health probes.

> Basic auth is intentionally minimal and dependency-free. If you want a nicer
> cookie-based login form later, that's a small swap — ask and I'll add it.

## Run it

### Locally (dev)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env          # fill it in
set -a && . ./.env && set +a  # load .env into the shell
uvicorn app:app --reload --port 8000
# http://localhost:8000
```

### Docker / homelab (compose)

```bash
cp .env.example .env          # fill it in
docker compose up -d --build
# http://<host>:8100
```

### Build a portable multi-arch image (no more "Mac vs Linux")

Your Mac is arm64; most servers and Fargate are amd64. `buildx` builds both at
once so the image runs anywhere:

```bash
docker buildx create --use --name multiarch    # one-time
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <your-registry>/demoworldfun-viewer:latest --push .
```

Push to whatever registry you like — GitLab CR, GHCR, or ECR (below).

## Host it on AWS

You don't need to commit to one AWS service. Two good options, easiest first:

### Option 1 — App Runner (simplest "set it and forget it")

App Runner takes a container image and gives you an autoscaling HTTPS URL with
no VPC, load balancer, or cluster to manage.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. Create an ECR repo and push the image
aws ecr create-repository --repository-name demoworldfun-viewer
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
docker buildx build --platform linux/amd64 \
  -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/demoworldfun-viewer:latest --push .
```

Then in the App Runner console: create a service from that ECR image, set the
port to `8000`, add the env vars (`TABLE_NAME`, `BUCKET_NAME`, `AUTH_USER`,
`AUTH_PASS` — **not** the AWS keys), set the health check path to `/healthz`,
and assign an **instance role** carrying the read-only policy below. You get a
stable `https://...awsapprunner.com` URL out of the box.

### Option 2 — ECS Fargate

More control (your VPC, an ALB, custom domain), more setup. Use this if you
outgrow App Runner. The image and env contract are identical; only the
surrounding infrastructure differs.

### The read-only role/policy (either option)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["dynamodb:Query"],
      "Resource": [
        "arn:aws:dynamodb:us-east-1:ACCOUNT_ID:table/demoworldfun-messages",
        "arn:aws:dynamodb:us-east-1:ACCOUNT_ID:table/demoworldfun-messages/index/global-index"
      ] },
    { "Effect": "Allow", "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::demoworldfun-inbound-mail/*" }
  ]
}
```

## Putting it in a repo

```bash
git init && git add . && git commit -m "demoworldfun inbox viewer"
git remote add origin <your gitlab/github remote>
git push -u origin main
```

`.env` is gitignored, so no secrets get committed — keep it that way.
