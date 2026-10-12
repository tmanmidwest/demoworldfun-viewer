# demoworldfun inbox viewer

A small, portable web viewer for a catch-all SES inbox. It lists inbound emails
(indexed in DynamoDB) and renders message bodies (stored in S3 by Amazon SES).

Built to be cloned and run by anyone: **almost everything is configured through
the UI at `/settings`** and persisted to a small config file, so the same
container image runs locally, in your homelab, or on AWS unchanged. Optional
single sign-on (OIDC / Authentik) is built in.

> This repo is just the viewer app. The AWS backend it reads from (SES receiving
> rule, S3 bucket, DynamoDB table + its feed index, and the indexer Lambda) is
> assumed to already exist. Point the app at your own resources from `/settings`.

## Repo layout

```
app.py               FastAPI viewer + UI settings + OIDC (Authentik SSO) login
requirements.txt     Pinned Python deps
Dockerfile           python:3.12-slim, non-root, /data volume, healthcheck
docker-compose.yml   For local / homelab runs (mounts a viewer-data volume)
.env.example         Copy to .env and fill in the few bootstrap vars
.dockerignore / .gitignore
```

## Configuration model

There are two layers:

1. **The `/settings` page (primary).** The AWS wiring, AWS credentials, the app
   title, and OIDC single sign-on are all set here and saved to `CONFIG_FILE`
   (default `/data/config.json`, mode `0600`). Changes take effect immediately —
   no restart. The compose file mounts a `viewer-data` volume at `/data` so the
   config survives container recreation.
2. **Environment variables (seeds + bootstrap).** Every `/settings` field is also
   read from a matching env var **on first boot**, so an unattended / env-driven
   deployment still works. Once you save in the UI, the stored file wins.

### What stays in the environment

Nothing *has* to be set — the admin key that unlocks the wizard is generated on
first boot (see [Admin key](#admin-key)). These settings remain optional:

| Variable | Required | Purpose |
|---|---|---|
| `ADMIN_TOKEN` | no | Pins the admin key to a fixed value instead of generating one. Leave blank to use the generated key. |
| `SESSION_SECRET` | recommended | Signs the session cookie (incl. the admin unlock). Set it so the unlock and logins survive a restart; otherwise a random one is generated per process. |
| `SECURE_COOKIES` | no | `true` when served over HTTPS (marks the session cookie `Secure`). A transport flag applied at startup. |
| `CONFIG_FILE` | no | Where UI settings are stored (default `/data/config.json`). |
| `ADMIN_KEY_FILE` | no | Where the admin-key hash is stored (default `/data/admin.key`). |
| `HOST_PORT` | compose only | Host port (default `8100`). |

You can bring up the container with **no env vars at all**, grab the generated
admin key, and configure everything else in the wizard at `/settings`.

### What you configure at `/settings` (env seeds shown in parentheses)

| Setting | Env seed | Notes |
|---|---|---|
| App title | `APP_TITLE` | Shown in the header / browser tab (default `inbox`) |
| Region | `AWS_REGION` / `AWS_DEFAULT_REGION` | e.g. `us-east-1` |
| DynamoDB table | `TABLE_NAME` | e.g. `demoworldfun-messages` |
| DynamoDB index | `DYNAMODB_INDEX` | The global feed GSI (default `global-index`) |
| S3 bucket | `BUCKET_NAME` | Bucket with the raw emails |
| S3 prefix | `S3_PREFIX` | Key prefix SES writes under (default `inbox/`) |
| Access key ID | `AWS_ACCESS_KEY_ID` | Blank → use a role / `~/.aws` (see below) |
| Secret access key | `AWS_SECRET_ACCESS_KEY` | Stored `0600`, masked in the form |
| Session token | `AWS_SESSION_TOKEN` | Only for temporary/SSO credentials |
| Require SSO login | `AUTH_DISABLED` (`true` = off) | Toggle SSO on/off |
| Discovery URL | `OIDC_DISCOVERY_URL` | Provider's `.well-known/openid-configuration` |
| Client ID | `OIDC_CLIENT_ID` | OAuth2/OIDC client ID |
| Client secret | `OIDC_CLIENT_SECRET` | Stored `0600`, masked in the form |
| Redirect URI | `OIDC_REDIRECT_URI` | Exact callback registered with the provider |
| Allowed groups | `OIDC_ALLOWED_GROUPS` | Comma-separated; empty = any authenticated user |

Secret fields (client secret, AWS secret key, session token) are masked; leaving
one blank on save **keeps the stored value** rather than wiping it.

## Admin key

The setup wizard configures OIDC — the app's own login — so it can't be protected
by that login. It's gated by an **admin key** instead:

- **On first boot**, if `ADMIN_TOKEN` isn't set, the app generates a strong random
  key. It's shown **once** in the browser the first time you open the app, and
  also printed **once** to the container log (`docker logs <container>` or the
  Portainer log viewer). Only a hash is stored on the `/data` volume — the
  plaintext is never written to disk.
- **Save it** in your password manager. It can't be displayed again.
- **Lost it?** It can't be recovered — regenerate it (the only recovery path):

  ```bash
  docker exec <container> python app.py reset-admin-key
  ```

  This prints a fresh key, invalidates the old one, and leaves everything else
  (AWS/OIDC config, sessions) intact.
- **Pin it instead:** set `ADMIN_TOKEN` in the environment and that fixed value is
  the admin key — nothing is generated or stored.

Because the key hash lives on the `/data` volume alongside `config.json`, copying
that volume to a new host migrates the admin identity too.

> **Security note:** because the key is shown on the first web visit and the app
> may be internet-exposed, claim it immediately after deploying (ideally over your
> LAN). If anyone could have seen it first, reset it with the command above. It's
> shown only once, then never again until a reset.

## The setup wizard

Open `http://<host>:<port>/settings` (also linked top-right of the inbox). Unlock
with the admin key (stored in your signed session; **Lock settings** clears it).

On a fresh install it drops you straight into a two-step wizard; afterwards the
same steps are editable from the settings overview:

1. **AWS backend** — region, table, index, bucket, prefix, and credentials, with a
   **Test connection** button that runs the exact operations the app uses (a
   DynamoDB `Query` on the feed index, then an S3 `HeadObject` — same permission
   as `GetObject` — on a real message key) and reports PASS/FAIL per check.
2. **Single sign-on** — the OIDC toggle and Authentik details.

The overview page then shows the status of each area (Configured / Not set up /
Disabled / Incomplete) with Edit links, plus the admin-key recovery command.

**Fail-closed behavior.** If SSO is enabled but not fully configured, the inbox is
blocked (you're sent to a "configure SSO" notice) rather than served without a
login. If the AWS backend isn't configured, the inbox shows a "set this up at
Settings" page (HTTP 503); if a backend call fails (wrong keys, missing IAM
permission), it shows the error and points at **Test connection** (HTTP 502)
instead of a raw 500.

## AWS credentials & IAM permissions

The app resolves credentials in this order:

1. **Keys entered at `/settings`** (or seeded from `AWS_ACCESS_KEY_ID` /
   `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`). Stored in the `0600` config
   file on the `/data` volume.
2. **Otherwise the standard boto3 chain** — ambient env vars, a mounted `~/.aws`,
   or an instance/task role. **Leave the credential fields blank to use this.**

Guidance by environment:

- **On-prem / homelab:** create a dedicated IAM user with the policy below and
  enter its access key at `/settings` (or seed it in `.env`). Prefer scoped,
  rotate-able keys.
- **On AWS (ECS / App Runner):** leave the credential fields blank and attach an
  **instance/task role** carrying the policy — no long-lived keys travel with the
  app at all.

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

`Query`/`UpdateItem`/`DeleteItem` cover listing, marking-read, and delete;
`GetObject`/`DeleteObject` cover rendering and deleting message bodies. The
**Test connection** button (AWS step of the wizard) deliberately checks only
these — it does **not** need `ListBucket` or `DescribeTable`. (Adjust
`global-index` if you set a different DynamoDB index.)

## Setting up the login (OIDC / Authentik SSO)

The app authenticates users through an OpenID Connect provider using the
Authorization Code flow. Unauthenticated visitors are bounced to the provider to
sign in, then redirected back to `/auth/callback`, where the app verifies the
token and creates its own session cookie. Turn the **Require SSO login** toggle
off at `/settings` (or set `AUTH_DISABLED=true`) to run without login — for local
dev, or when fronted by another auth proxy.

### 1. Create the provider + application in Authentik

In your Authentik admin (`https://authtime.trevorcombs.com`):

1. **Providers → Create → OAuth2/OpenID Provider.** Authorization flow:
   explicit/implicit consent. Client type: **Confidential**. Note the generated
   **Client ID** and **Client Secret**.
2. Set the **Redirect URI** to your app's callback, e.g.
   `https://<your-app-host>/auth/callback` (must match the Redirect URI you enter
   in `/settings`). The settings page shows the callback it will use as a hint.
3. **Applications → Create**, bind it to that provider, give it a slug. Access to
   this application (and any group bindings) is what governs who can log in.
4. (Optional) To restrict by group inside the app too, add a **Scope Mapping**
   that emits `groups` and ensure the provider's scopes include it, then set
   **Allowed groups**.

Your discovery URL is:
`https://authtime.trevorcombs.com/application/o/<app-slug>/.well-known/openid-configuration`

### 2. Configure the app

Enter the Discovery URL, Client ID, Client secret, Redirect URI, and (optionally)
Allowed groups at `/settings`, turn on **Require SSO login**, and save. (Or seed
the same values via the `OIDC_*` env vars.)

Notes:

- **The Redirect URI must exactly match** what's registered in Authentik (scheme,
  host, and path). Set it explicitly behind a load balancer / reverse proxy so
  the app doesn't guess the wrong scheme/host from proxied requests.
- OAuth tokens travel over this URL — **serve the app over HTTPS** in anything
  but throwaway local testing, and set `SECURE_COOKIES=true` to match.
- The app stores no passwords. Identity, MFA, and account lifecycle all live in
  Authentik; the app only trusts the verified ID token.

## Run it

### Locally (dev)

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
export CONFIG_FILE=./config.json ADMIN_KEY_FILE=./admin.key   # writable local paths
export SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
uvicorn app:app --reload --port 8000
# http://localhost:8000  → the first visit shows your generated admin key,
#   then walks you through the setup wizard. (The key is also printed to the log.)
```

### Docker / homelab (compose)

```bash
cp .env.example .env          # optional: set SESSION_SECRET; everything else can be blank
docker compose up -d --build
docker logs demoworldfun-viewer | grep -A1 "ADMIN KEY"   # grab the generated key
# http://<host>:8100  → unlock with that key and finish the wizard
```

The compose file mounts a named `viewer-data` volume at `/data`, so your saved
settings (including credentials, `0600`) persist across `up`/`down`/rebuilds.

### Build a portable multi-arch image (no "Mac vs Linux")

Your Mac is arm64; servers and Fargate are amd64. `buildx` builds both so one
image runs anywhere:

```bash
docker buildx create --use --name multiarch    # one-time
docker buildx build --platform linux/amd64,linux/arm64 \
  -t <your-registry>/demoworldfun-viewer:latest --push .
```

## Host it on AWS

The container is the unit of deployment — pick a service, the image stays
identical. On AWS you typically leave the AWS **credential** fields blank and use
a role; still set `ADMIN_TOKEN` (and `SESSION_SECRET`, `SECURE_COOKIES=true`) as
env, and persist `/data` so UI settings survive task restarts.

### App Runner (simplest)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr create-repository --repository-name demoworldfun-viewer
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com
docker buildx build --platform linux/amd64 \
  -t ${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/demoworldfun-viewer:latest --push .
```

Then create an App Runner service from that image: port `8000`, health check path
`/healthz`, set `ADMIN_TOKEN` / `SESSION_SECRET` / `SECURE_COOKIES=true` (and
optionally seed the AWS + OIDC vars), assign an **instance role** with the
read-only policy above, and configure the rest at `/settings`. You get a stable
HTTPS URL out of the box. (Note: App Runner's filesystem is ephemeral — seed via
env vars, or attach durable storage, if you don't want to re-enter settings after
a redeploy.)

### ECS Fargate

More control (your VPC, an ALB, custom domain), more setup. Same image; use a
task role for credentials and an EFS mount for `/data` if you want UI settings to
persist.

## Putting it in a repo

```bash
git init && git add . && git commit -m "demoworldfun inbox viewer"
git remote add origin <remote>
git push -u origin main
```

`.env` is gitignored, so no secrets get committed — keep it that way. The runtime
config file (`/data/config.json`) lives on a volume, not in the repo.
