"""
demoworldfun inbox viewer.

A small, portable FastAPI app that lists inbound emails indexed in DynamoDB
and renders message bodies from S3. Designed to be cloned and run by anyone:
all operational settings are environment variables, and AWS credentials are
supplied at deploy time (env vars locally, or an instance/task role on AWS) --
never entered through the UI.

Auth: a single optional login account, defined entirely by environment
variables. Enable it by setting AUTH_USER + AUTH_PASS_HASH_B64 + SESSION_SECRET.
Leave them unset to disable login (e.g. when fronted by Authentik / Cognito).
"""

import os
import html
import base64
import secrets

import bcrypt
import boto3
from boto3.dynamodb.conditions import Key
from email import message_from_bytes
from email.policy import default as default_policy
from fastapi import FastAPI, Depends, Request, Form
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

# ---------------------------------------------------------------------------
# Configuration (all via environment)
# ---------------------------------------------------------------------------
# Operational settings -- safe to set anywhere, not secret:
TABLE_NAME = os.environ["TABLE_NAME"]
BUCKET_NAME = os.environ["BUCKET_NAME"]
S3_PREFIX = os.environ.get("S3_PREFIX", "inbox/")
APP_TITLE = os.environ.get("APP_TITLE", "inbox")  # shown in the UI header

# Auth (optional). Auth turns on only when a user AND a password hash exist.
AUTH_USER = os.environ.get("AUTH_USER")
AUTH_PASS_HASH_B64 = os.environ.get("AUTH_PASS_HASH_B64")
SESSION_SECRET = os.environ.get("SESSION_SECRET")
SECURE_COOKIES = os.environ.get("SECURE_COOKIES", "").lower() in ("1", "true", "yes")

AUTH_ENABLED = bool(AUTH_USER and AUTH_PASS_HASH_B64)

if AUTH_ENABLED:
    # The stored hash is base64-encoded to avoid '$' interpolation headaches
    # in .env / docker-compose. Decode it back to the raw bcrypt hash bytes.
    try:
        _PW_HASH = base64.b64decode(AUTH_PASS_HASH_B64)
    except Exception as exc:  # pragma: no cover
        raise RuntimeError("AUTH_PASS_HASH_B64 is not valid base64") from exc
    if not SESSION_SECRET:
        raise RuntimeError(
            "Auth is enabled (AUTH_USER + AUTH_PASS_HASH_B64 set) but "
            "SESSION_SECRET is missing. Generate one with:\n"
            "  python3 -c \"import secrets; print(secrets.token_urlsafe(32))\""
        )

# AWS credentials come from the standard boto3 chain -- env vars locally, or an
# instance/task role on AWS. They are never read from or written to the UI.
ddb = boto3.resource("dynamodb")
table = ddb.Table(TABLE_NAME)
s3 = boto3.client("s3")

app = FastAPI(title=f"{APP_TITLE} inbox")
app.add_middleware(
    SessionMiddleware,
    secret_key=SESSION_SECRET or secrets.token_urlsafe(32),
    same_site="lax",
    https_only=SECURE_COOKIES,
)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
class NotAuthenticated(Exception):
    pass


@app.exception_handler(NotAuthenticated)
async def _to_login(request: Request, exc: NotAuthenticated):
    return RedirectResponse("/login", status_code=302)


def require_login(request: Request):
    """Dependency: allow through if auth is disabled or the session is logged in."""
    if not AUTH_ENABLED:
        return
    if not request.session.get("user"):
        raise NotAuthenticated()


def _verify(username: str, password: str) -> bool:
    if not AUTH_ENABLED:
        return False
    if not secrets.compare_digest(username, AUTH_USER):
        # Run a dummy check anyway to keep timing roughly constant.
        bcrypt.checkpw(b"x", bcrypt.hashpw(b"x", bcrypt.gensalt()))
        return False
    try:
        return bcrypt.checkpw(password.encode("utf-8"), _PW_HASH)
    except ValueError:
        return False


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


def _nav() -> str:
    if AUTH_ENABLED:
        return "<a href='/logout' style='float:right;font-size:13px'>Log out</a>"
    return ""


PAGE = """<!doctype html><meta charset=utf-8>
<meta http-equiv="refresh" content="10">
<title>{title} inbox</title>
<style>
 body{{font:14px system-ui,sans-serif;margin:2rem;max-width:1000px}}
 table{{border-collapse:collapse;width:100%}}
 th,td{{text-align:left;padding:.4rem .6rem;border-bottom:1px solid #ddd}}
 th{{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#666}}
 a{{text-decoration:none;color:#0645ad}}
 .muted{{color:#888}}
</style>
{nav}
<h2>{title} &mdash; inbox{title_extra}</h2>
<p class=muted>Auto-refreshes every 10s.</p>
<table><tr><th>To</th><th>From</th><th>Subject</th><th>Received (UTC)</th></tr>
{rows}</table>"""


LOGIN_PAGE = """<!doctype html><meta charset=utf-8>
<title>{title} &mdash; log in</title>
<style>
 body{{font:14px system-ui,sans-serif;display:flex;justify-content:center;
       align-items:center;min-height:90vh;margin:0}}
 .card{{border:1px solid #ddd;border-radius:8px;padding:2rem;width:280px}}
 h2{{margin:0 0 1rem}}
 input{{width:100%;padding:.5rem;margin:.3rem 0;box-sizing:border-box;
        border:1px solid #ccc;border-radius:4px}}
 button{{width:100%;padding:.6rem;margin-top:.6rem;border:0;border-radius:4px;
         background:#0645ad;color:#fff;font-size:14px;cursor:pointer}}
 .err{{color:#b00;font-size:13px;min-height:1.2em}}
</style>
<div class=card>
 <h2>{title}</h2>
 <form method=post action=/login>
  <div class=err>{error}</div>
  <input name=username placeholder=Username autofocus autocomplete=username>
  <input name=password type=password placeholder=Password autocomplete=current-password>
  <button type=submit>Log in</button>
 </form>
</div>"""


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    """Unauthenticated health check for container / load-balancer probes."""
    return "ok"


@app.get("/login", response_class=HTMLResponse)
def login_form(request: Request, error: str = ""):
    if not AUTH_ENABLED or request.session.get("user"):
        return RedirectResponse("/", status_code=302)
    msg = "Invalid username or password." if error else ""
    return LOGIN_PAGE.format(title=html.escape(APP_TITLE), error=html.escape(msg))


@app.post("/login")
def login_submit(request: Request,
                 username: str = Form(...),
                 password: str = Form(...)):
    if not AUTH_ENABLED:
        return RedirectResponse("/", status_code=302)
    if _verify(username, password):
        request.session["user"] = username
        return RedirectResponse("/", status_code=302)
    return RedirectResponse("/login?error=1", status_code=302)


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/login", status_code=302)


@app.get("/", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def inbox_all():
    resp = table.query(
        IndexName="global-index",
        KeyConditionExpression=Key("inbox").eq("ALL"),
        ScanIndexForward=False,
        Limit=100,
    )
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        title=html.escape(APP_TITLE),
        nav=_nav(),
        rows=rows or "<tr><td colspan=4 class=muted>No mail yet.</td></tr>",
        title_extra="",
    )


@app.get("/inbox/{address}", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def inbox_for(address: str):
    resp = table.query(
        KeyConditionExpression=Key("recipient").eq(address.lower()),
        ScanIndexForward=False,
        Limit=100,
    )
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        title=html.escape(APP_TITLE),
        nav=_nav(),
        rows=rows or "<tr><td colspan=4 class=muted>No mail.</td></tr>",
        title_extra=f" &mdash; {html.escape(address)}",
    )


@app.get("/message/{message_id}", response_class=HTMLResponse, dependencies=[Depends(require_login)])
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
