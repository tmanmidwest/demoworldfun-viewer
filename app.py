"""
demoworldfun inbox viewer.

A small, portable FastAPI app that lists inbound emails indexed in DynamoDB
and renders message bodies from S3. Everything is configured via environment
variables so the same image runs locally, on homelab Docker, or on AWS.

Credentials come from the standard boto3 chain:
  - locally / Docker:  AWS_DEFAULT_REGION + AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  - on AWS (ECS / App Runner): the task / instance role (no keys needed)
"""

import os
import html
import secrets

import boto3
from boto3.dynamodb.conditions import Key
from email import message_from_bytes
from email.policy import default as default_policy
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.responses import HTMLResponse, PlainTextResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

# ---------------------------------------------------------------------------
# Config (all via environment)
# ---------------------------------------------------------------------------
TABLE_NAME = os.environ["TABLE_NAME"]
BUCKET_NAME = os.environ["BUCKET_NAME"]
S3_PREFIX = os.environ.get("S3_PREFIX", "inbox/")
AUTH_USER = os.environ.get("AUTH_USER")
AUTH_PASS = os.environ.get("AUTH_PASS")

ddb = boto3.resource("dynamodb")
table = ddb.Table(TABLE_NAME)
s3 = boto3.client("s3")

app = FastAPI(title="demoworldfun inbox")

# auto_error=False so we can decide ourselves whether auth is required.
security = HTTPBasic(auto_error=False)


def require_auth(credentials: HTTPBasicCredentials = Depends(security)):
    """Enforce basic auth only when both AUTH_USER and AUTH_PASS are set.

    Leave them unset to disable auth entirely (e.g. when the app is fronted
    by Authentik / Cognito / another proxy that already handles login).
    """
    if not (AUTH_USER and AUTH_PASS):
        return
    ok = credentials is not None and (
        secrets.compare_digest(credentials.username, AUTH_USER)
        and secrets.compare_digest(credentials.password, AUTH_PASS)
    )
    if not ok:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
def _row(m: dict) -> str:
    flag = ""
    if m.get("spamVerdict") == "FAIL":
        flag += " <span style='color:#b00'>[spam]</span>"
    if m.get("virusVerdict") == "FAIL":
        flag += " <span style='color:#b00'>[virus]</span>"
    return (
        "<tr>"
        f"<td>{html.escape(m.get('recipient', ''))}</td>"
        f"<td>{html.escape(m.get('sender', ''))}</td>"
        f"<td><a href='/message/{html.escape(m['messageId'])}'>"
        f"{html.escape(m.get('subject', '(no subject)'))}</a>{flag}</td>"
        f"<td>{html.escape(m.get('receivedAt', '').split('#')[0])}</td>"
        "</tr>"
    )


PAGE = """<!doctype html><meta charset=utf-8>
<meta http-equiv="refresh" content="10">
<title>demoworldfun inbox</title>
<style>
 body{{font:14px system-ui,sans-serif;margin:2rem;max-width:1000px}}
 table{{border-collapse:collapse;width:100%}}
 th,td{{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #ddd}}
 th{{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#666}}
 a{{text-decoration:none;color:#0645ad}}
 .muted{{color:#888}}
</style>
<h2>demoworldfun.net &mdash; inbox{title_extra}</h2>
<p class=muted>Auto-refreshes every 10s.</p>
<table><tr><th>To</th><th>From</th><th>Subject</th><th>Received (UTC)</th></tr>
{rows}</table>"""


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    """Unauthenticated health check for container / load-balancer probes."""
    return "ok"


@app.get("/", response_class=HTMLResponse, dependencies=[Depends(require_auth)])
def inbox_all():
    resp = table.query(
        IndexName="global-index",
        KeyConditionExpression=Key("inbox").eq("ALL"),
        ScanIndexForward=False,
        Limit=100,
    )
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        rows=rows or "<tr><td colspan=4 class=muted>No mail yet.</td></tr>",
        title_extra="",
    )


@app.get("/inbox/{address}", response_class=HTMLResponse, dependencies=[Depends(require_auth)])
def inbox_for(address: str):
    resp = table.query(
        KeyConditionExpression=Key("recipient").eq(address.lower()),
        ScanIndexForward=False,
        Limit=100,
    )
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        rows=rows or "<tr><td colspan=4 class=muted>No mail.</td></tr>",
        title_extra=f" &mdash; {html.escape(address)}",
    )


@app.get("/message/{message_id}", response_class=HTMLResponse, dependencies=[Depends(require_auth)])
def view_message(message_id: str):
    key = f"{S3_PREFIX}{message_id}"
    raw = s3.get_object(Bucket=BUCKET_NAME, Key=key)["Body"].read()
    msg = message_from_bytes(raw, policy=default_policy)

    body = msg.get_body(preferencelist=("html", "plain"))
    if body is None:
        content, is_html = "(empty body)", False
    else:
        content = body.get_content()
        is_html = body.get_content_type() == "text/html"

    meta = (
        f"<b>From:</b> {html.escape(str(msg['from']))}<br>"
        f"<b>To:</b> {html.escape(str(msg['to']))}<br>"
        f"<b>Subject:</b> {html.escape(str(msg['subject']))}<hr>"
    )

    if is_html:
        # Render untrusted email HTML inside a sandboxed iframe:
        # no scripts, no same-origin access. Do not relax this.
        srcdoc = html.escape(content, quote=True)
        rendered = (
            "<iframe sandbox style='width:100%;height:70vh;border:1px solid #ccc' "
            f"srcdoc=\"{srcdoc}\"></iframe>"
        )
    else:
        rendered = f"<pre style='white-space:pre-wrap'>{html.escape(content)}</pre>"

    return (
        "<!doctype html><meta charset=utf-8>"
        "<body style='font:14px system-ui,sans-serif;margin:2rem'>"
        "<a href='/'>&larr; inbox</a><hr>"
        f"{meta}{rendered}"
    )
