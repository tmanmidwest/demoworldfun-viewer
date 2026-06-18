"""
demoworldfun inbox viewer.

A small, portable FastAPI app that lists inbound emails indexed in DynamoDB
and renders message bodies from S3. Designed to be cloned and run by anyone:
all operational settings are environment variables, and AWS credentials are
supplied at deploy time (env vars locally, or an instance/task role on AWS) --
never entered through the UI.

Auth: single sign-on via an OpenID Connect provider (e.g. Authentik). Configure
it with OIDC_DISCOVERY_URL + OIDC_CLIENT_ID + OIDC_CLIENT_SECRET + SESSION_SECRET
and users log in through the provider's Authorization Code flow. Optionally
restrict access to members of one or more provider groups via OIDC_ALLOWED_GROUPS.
For local dev or when fronted by another auth proxy, set AUTH_DISABLED=true.
"""

import os
import html
import secrets
from urllib.parse import urlencode

import boto3
from boto3.dynamodb.conditions import Key
from email import message_from_bytes
from email.policy import default as default_policy
from authlib.integrations.starlette_client import OAuth, OAuthError
from fastapi import FastAPI, Depends, Request
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

# Auth via OpenID Connect (Authentik). Disabled only with an explicit opt-out,
# so the app fails closed if you forget to configure it.
AUTH_DISABLED = os.environ.get("AUTH_DISABLED", "").lower() in ("1", "true", "yes")
AUTH_ENABLED = not AUTH_DISABLED

OIDC_DISCOVERY_URL = os.environ.get("OIDC_DISCOVERY_URL")
OIDC_CLIENT_ID = os.environ.get("OIDC_CLIENT_ID")
OIDC_CLIENT_SECRET = os.environ.get("OIDC_CLIENT_SECRET")
# Exact callback URL registered in Authentik. If unset, it is derived per
# request -- but behind an ALB/proxy you should set it explicitly so the scheme
# and host always match what the provider expects.
OIDC_REDIRECT_URI = os.environ.get("OIDC_REDIRECT_URI")
# Optional comma-separated allow-list of provider groups. Empty = any
# authenticated user the provider lets through.
OIDC_ALLOWED_GROUPS = [
    g.strip() for g in os.environ.get("OIDC_ALLOWED_GROUPS", "").split(",") if g.strip()
]

SESSION_SECRET = os.environ.get("SESSION_SECRET")
SECURE_COOKIES = os.environ.get("SECURE_COOKIES", "").lower() in ("1", "true", "yes")

oauth = OAuth()

if AUTH_ENABLED:
    missing = [
        name for name, val in (
            ("OIDC_DISCOVERY_URL", OIDC_DISCOVERY_URL),
            ("OIDC_CLIENT_ID", OIDC_CLIENT_ID),
            ("OIDC_CLIENT_SECRET", OIDC_CLIENT_SECRET),
            ("SESSION_SECRET", SESSION_SECRET),
        ) if not val
    ]
    if missing:
        raise RuntimeError(
            "OIDC auth is enabled but these are missing: "
            + ", ".join(missing)
            + ".\nSet them, or set AUTH_DISABLED=true to run without login.\n"
            "Generate SESSION_SECRET with:\n"
            "  python3 -c \"import secrets; print(secrets.token_urlsafe(32))\""
        )
    oauth.register(
        name="oidc",
        server_metadata_url=OIDC_DISCOVERY_URL,
        client_id=OIDC_CLIENT_ID,
        client_secret=OIDC_CLIENT_SECRET,
        client_kwargs={"scope": "openid email profile"},
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


def _callback_uri(request: Request) -> str:
    """The OIDC redirect URI: explicit env value, else derived from the request."""
    return OIDC_REDIRECT_URI or str(request.url_for("auth_callback"))


def _group_allowed(userinfo: dict) -> bool:
    """True if no group restriction is set, or the user is in an allowed group."""
    if not OIDC_ALLOWED_GROUPS:
        return True
    user_groups = userinfo.get("groups") or []
    return any(g in OIDC_ALLOWED_GROUPS for g in user_groups)


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------
def _row(m: dict) -> str:
    flag = ""
    if m.get("spamVerdict") == "FAIL":
        flag += " <span style='color:#b00'>[spam]</span>"
    if m.get("virusVerdict") == "FAIL":
        flag += " <span style='color:#b00'>[virus]</span>"
    mid = html.escape(m["messageId"])
    is_read = bool(m.get("read"))

    # Carry this item's primary key in the link so opening it marks exactly
    # this row read (no scan needed). receivedAt is the full sort key value.
    qs = urlencode({"r": m.get("recipient", ""), "t": m.get("receivedAt", "")})
    href = html.escape(f"/message/{m['messageId']}?{qs}", quote=True)

    dot = ("<span title=read style='color:#bbb'>○</span>" if is_read
           else "<span title=unread style='color:#0645ad'>●</span>")
    subj = html.escape(m.get("subject", "(no subject)"))
    subj_weight = "" if is_read else "font-weight:600"
    return (
        f"<tr class='{'read' if is_read else 'unread'}'>"
        f"<td style='text-align:center'>{dot}</td>"
        f"<td>{html.escape(m.get('recipient', ''))}</td>"
        f"<td>{html.escape(m.get('sender', ''))}</td>"
        f"<td><a href='{href}' style='{subj_weight}'>{subj}</a>{flag}</td>"
        f"<td>{html.escape(m.get('receivedAt', '').split('#')[0])}</td>"
        f"<td>{_delete_button(mid)}</td>"
        "</tr>"
    )


def _delete_button(message_id: str) -> str:
    # A small POST form. Confirm dialog guards against accidental clicks.
    return (
        f"<form method=post action='/message/{message_id}/delete' style='margin:0' "
        "onsubmit=\"return confirm('Delete this message permanently?')\">"
        "<button type=submit style='border:0;background:none;color:#b00;"
        "cursor:pointer;font-size:13px;padding:0'>Delete</button></form>"
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
 tr.read td{{color:#999}}
 tr.read a{{color:#7a93c0}}
</style>
{nav}
<h2>{title} &mdash; inbox{title_extra}</h2>
<p class=muted>Auto-refreshes every 10s.</p>
<table><tr><th></th><th>To</th><th>From</th><th>Subject</th><th>Received (UTC)</th><th></th></tr>
{rows}</table>"""


LOGIN_PAGE = """<!doctype html><meta charset=utf-8>
<title>{title} &mdash; log in</title>
<style>
 body{{font:14px system-ui,sans-serif;display:flex;justify-content:center;
       align-items:center;min-height:90vh;margin:0}}
 .card{{border:1px solid #ddd;border-radius:8px;padding:2rem;width:280px;
        text-align:center}}
 h2{{margin:0 0 1.2rem}}
 a.btn{{display:block;padding:.6rem;border-radius:4px;background:#0645ad;
        color:#fff;font-size:14px;text-decoration:none}}
 .err{{color:#b00;font-size:13px;min-height:1.2em;margin-bottom:.4rem}}
</style>
<div class=card>
 <h2>{title}</h2>
 <div class=err>{error}</div>
 <a class=btn href=/login>Sign in with SSO</a>
</div>"""


LOGGED_OUT_PAGE = """<!doctype html><meta charset=utf-8>
<title>{title} &mdash; signed out</title>
<style>
 body{{font:14px system-ui,sans-serif;display:flex;justify-content:center;
       align-items:center;min-height:90vh;margin:0}}
 .card{{border:1px solid #ddd;border-radius:8px;padding:2rem;width:280px;
        text-align:center}}
 h2{{margin:0 0 .4rem}}
 p{{color:#666;margin:0 0 1.2rem}}
 a.btn{{display:block;padding:.6rem;border-radius:4px;background:#0645ad;
        color:#fff;font-size:14px;text-decoration:none}}
</style>
<div class=card>
 <h2>{title}</h2>
 <p>You've been signed out of this app.</p>
 <a class=btn href=/login>Sign in again</a>
</div>"""


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/healthz", response_class=PlainTextResponse)
def healthz():
    """Unauthenticated health check for container / load-balancer probes."""
    return "ok"


@app.get("/login")
async def login(request: Request, error: str = ""):
    """Start the OIDC Authorization Code flow (or show an error after a failure)."""
    if not AUTH_ENABLED or request.session.get("user"):
        return RedirectResponse("/", status_code=302)
    if error:
        messages = {
            "denied": "Your account is not permitted to access this app.",
            "failed": "Sign-in failed. Please try again.",
        }
        msg = messages.get(error, "Sign-in failed. Please try again.")
        return HTMLResponse(
            LOGIN_PAGE.format(title=html.escape(APP_TITLE), error=html.escape(msg))
        )
    return await oauth.oidc.authorize_redirect(request, _callback_uri(request))


@app.get("/auth/callback", name="auth_callback")
async def auth_callback(request: Request):
    """OIDC redirect target: exchange the code, enforce group policy, log in."""
    if not AUTH_ENABLED:
        return RedirectResponse("/", status_code=302)
    try:
        token = await oauth.oidc.authorize_access_token(request)
    except OAuthError:
        return RedirectResponse("/login?error=failed", status_code=302)

    userinfo = token.get("userinfo") or {}
    if not _group_allowed(userinfo):
        return RedirectResponse("/login?error=denied", status_code=302)

    request.session["user"] = (
        userinfo.get("preferred_username")
        or userinfo.get("email")
        or userinfo.get("sub")
    )
    return RedirectResponse("/", status_code=302)


@app.get("/logout")
def logout(request: Request):
    # Clear this app's session, then land on a static page instead of /login --
    # otherwise /login would immediately re-launch the OIDC flow and the still-
    # live SSO session would sign the user straight back in. The provider's own
    # session is intentionally left intact (local logout only).
    request.session.clear()
    return RedirectResponse("/logged-out", status_code=302)


@app.get("/logged-out", response_class=HTMLResponse, name="logged_out")
def logged_out():
    return LOGGED_OUT_PAGE.format(title=html.escape(APP_TITLE))


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
        rows=rows or "<tr><td colspan=6 class=muted>No mail yet.</td></tr>",
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
        rows=rows or "<tr><td colspan=6 class=muted>No mail.</td></tr>",
        title_extra=f" &mdash; {html.escape(address)}",
    )


@app.get("/message/{message_id}", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def view_message(message_id: str, r: str = "", t: str = ""):
    # Best-effort: mark this inbox row read. 'r'/'t' are the item's primary key,
    # carried from the inbox link. Needs dynamodb:UpdateItem; if the role lacks
    # it (or the key wasn't passed) the view still renders fine.
    if r and t:
        try:
            table.update_item(
                Key={"recipient": r, "receivedAt": t},
                UpdateExpression="SET #read = :true",
                ExpressionAttributeNames={"#read": "read"},  # 'read' is reserved
                ExpressionAttributeValues={":true": True},
            )
        except Exception:
            pass

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
        "<a href='/'>&larr; inbox</a>"
        f"<span style='float:right'>{_delete_button(html.escape(message_id))}</span>"
        "<hr>"
        f"{meta}{rendered}"
    )


@app.post("/message/{message_id}/delete", dependencies=[Depends(require_login)])
def delete_message(message_id: str):
    """Permanently remove a message: the raw email in S3 and all index rows."""
    # 1. Delete the raw email object from S3
    try:
        s3.delete_object(Bucket=BUCKET_NAME, Key=f"{S3_PREFIX}{message_id}")
    except Exception:
        pass  # already gone / expired — fall through to index cleanup

    # 2. Delete every DynamoDB index row referencing this messageId.
    #    A message may have one row per recipient. Walk the global feed
    #    (small at demo volume) and delete matches.
    start_key = None
    while True:
        kwargs = dict(
            IndexName="global-index",
            KeyConditionExpression=Key("inbox").eq("ALL"),
        )
        if start_key:
            kwargs["ExclusiveStartKey"] = start_key
        resp = table.query(**kwargs)
        for it in resp.get("Items", []):
            if it.get("messageId") == message_id:
                table.delete_item(Key={
                    "recipient": it["recipient"],
                    "receivedAt": it["receivedAt"],
                })
        start_key = resp.get("LastEvaluatedKey")
        if not start_key:
            break

    # 303 -> browser re-requests the inbox with GET
    return RedirectResponse("/", status_code=303)
