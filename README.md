# demoworldfun inbox viewer

A small, portable web viewer for a catch-all SES inbox. It lists inbound emails
(indexed in DynamoDB) and renders message bodies (stored in S3 by Amazon SES).

Built to be cloned and run by anyone: **every operational setting is an
environment variable**, the same container image runs locally, on Docker, or on
AWS unchanged, and an optional login is built in.

> This repo is just the viewer app. The AWS backend it reads from (SES receiving
> rule, S3 bucket, DynamoDB table + `global-index`, and the indexer Lambda) is
> assumed to already exist. Point the app at your own resources via env vars.

## Repo layout

```
app.py               FastAPI viewer + OIDC (Authentik SSO) login
requirements.txt     Pinned Python deps
Dockerfile           python:3.12-slim, non-root, with healthcheck
docker-compose.yml   For local / homelab runs
.env.example         Copy to .env and fill in
.dockerignore / .gitignore
```

## Configuration

Everything is environment-driven. Copy `.env.example` to `.env` and fill it in.

| Variable | Required | Purpose |
|---|---|---|
| `AWS_DEFAULT_REGION` | yes | e.g. `us-east-1` |
| `TABLE_NAME` | yes | DynamoDB table (e.g. `demoworldfun-messages`) |
| `BUCKET_NAME` | yes | S3 bucket with the raw emails |
| `S3_PREFIX` | no | Key prefix SES writes under (default `inbox/`) |
| `APP_TITLE` | no | Branding shown in the header/login (default `inbox`) |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | local only | **Leave blank on AWS**; use a role instead |
| `OIDC_DISCOVERY_URL` | for login | Provider's `.well-known/openid-configuration` URL |
| `OIDC_CLIENT_ID` | for login | OAuth2/OIDC client ID from the provider |
| `OIDC_CLIENT_SECRET` | for login | OAuth2/OIDC client secret (store as a secret) |
| `OIDC_REDIRECT_URI` | recommended | Exact callback URL registered with the provider (e.g. `https://host/auth/callback`) |
| `OIDC_ALLOWED_GROUPS` | no | Comma-separated provider groups allowed in; empty = any authenticated user |
| `SESSION_SECRET` | for login | Random string signing the session cookie |
| `AUTH_DISABLED` | no | `true` to run with **no** login (local dev, or behind another auth proxy) |
| `SECURE_COOKIES` | no | `true` when served over HTTPS |
| `HOST_PORT` | compose only | Host port (default `8100`) |

## How AWS credentials work (important)

**Credentials are supplied at deploy time, never through the UI.** The app uses
the standard boto3 chain and resolves them automatically:

- **Local / Docker:** put the scoped read-only keys in `.env`
  (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).
- **On AWS (App Runner / ECS):** attach an instance/task role carrying the
  read-only policy and **leave the key variables blank** — no keys travel with
  the app at all.

This is deliberate. A viewer that accepted AWS keys through a form would have to
store them, encrypt them at rest, and would push people toward long-lived keys
over roles. Keeping credentials at the deployment boundary avoids all of that.
The IAM identity only ever needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:DeleteItem"],
      "Resource": [
        "arn:aws:dynamodb:REGION:ACCOUNT_ID:table/TABLE_NAME",
        "arn:aws:dynamodb:REGION:ACCOUNT_ID:table/TABLE_NAME/index/global-index"
      ] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*" }
  ]
}
```

## Setting up the login (OIDC / Authentik SSO)

The app authenticates users through an OpenID Connect provider using the
Authorization Code flow. Unauthenticated visitors are bounced to the provider to
sign in, then redirected back to `/auth/callback`, where the app verifies the
token and creates its own session cookie. For local dev or when fronted by
another auth proxy, set `AUTH_DISABLED=true` to skip login entirely.

### 1. Create the provider + application in Authentik

In your Authentik admin (`https://authtime.trevorcombs.com`):

1. **Providers → Create → OAuth2/OpenID Provider.** Authorization flow:
   explicit/implicit consent. Client type: **Confidential**. Note the generated
   **Client ID** and **Client Secret**.
2. Set the **Redirect URI** to your app's callback, e.g.
   `https://<your-app-host>/auth/callback` (must match `OIDC_REDIRECT_URI`).
3. **Applications → Create**, bind it to that provider, give it a slug. Access to
   this application (and any group bindings) is what governs who can log in.
4. (Optional) To restrict by group inside the app too, add a **Scope Mapping**
   that emits `groups` and ensure the provider's scopes include it, then set
   `OIDC_ALLOWED_GROUPS`.

Your discovery URL is:
`https://authtime.trevorcombs.com/application/o/<app-slug>/.well-known/openid-configuration`

### 2. Configure the app

```bash
# Generate a session secret (signs the local session cookie)
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

Put these in `.env` (or ECS task env / secrets):

```
OIDC_DISCOVERY_URL=https://authtime.trevorcombs.com/application/o/<app-slug>/.well-known/openid-configuration
OIDC_CLIENT_ID=...
OIDC_CLIENT_SECRET=...
OIDC_REDIRECT_URI=https://<your-app-host>/auth/callback
OIDC_ALLOWED_GROUPS=inbox-admins        # optional
SESSION_SECRET=...
SECURE_COOKIES=true                      # whenever served over HTTPS
```

Notes:

- **`OIDC_CLIENT_SECRET` is a secret** — inject it via ECS Secrets/SSM Parameter
  Store, not as plaintext in a committed file.
- **`OIDC_REDIRECT_URI` must exactly match** what's registered in Authentik
  (scheme, host, and path). Set it explicitly behind a load balancer so the
  app doesn't guess the wrong scheme/host from proxied requests.
- OAuth tokens travel over this URL — **serve the app over HTTPS** in anything
  but throwaway local testing, and set `SECURE_COOKIES=true` to match.
- The app stores no passwords. Identity, MFA, and account lifecycle all live in
  Authentik; the app only trusts the verified ID token.

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

### Build a portable multi-arch image (no "Mac vs Linux")

Your Mac is arm64; servers and Fargate are amd64. `buildx` builds both so one
image runs anywhere:

```bash
docker buildx create --use --name multiarch    # one-time
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <your-registry>/demoworldfun-viewer:latest --push .
```

## Host it on AWS

The container is the unit of deployment — pick a service, the image and env
contract stay identical.

### App Runner (simplest)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr create-repository --repository-name demoworldfun-viewer
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
docker buildx build --platform linux/amd64 \
  -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/demoworldfun-viewer:latest --push .
```

Then create an App Runner service from that image: port `8000`, health check
path `/healthz`, add the env vars (`TABLE_NAME`, `BUCKET_NAME`, `APP_TITLE`,
the `OIDC_*` / `SESSION_SECRET` set — **not** the AWS keys), assign an
**instance role** with the read-only policy above, and set `SECURE_COOKIES=true`.
You get a stable HTTPS URL out of the box.

### ECS Fargate

More control (your VPC, an ALB, custom domain), more setup. Same image and env.

## Putting it in a repo

```bash
git init && git add . && git commit -m "demoworldfun inbox viewer"
git remote add origin <remote>
git push -u origin main
```

`.env` is gitignored, so no secrets get committed — keep it that way.
