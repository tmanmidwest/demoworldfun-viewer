"""
demoworldfun inbox viewer.

A small, portable FastAPI app that lists inbound emails indexed in DynamoDB
and renders message bodies from S3.

Configuration is done through the UI at /settings and persisted to CONFIG_FILE:
the AWS wiring (region, table, index, bucket, prefix), AWS credentials, the app
title, and OIDC/Authentik single sign-on. Every setting is also seeded from a
matching environment variable on first boot, so an existing env-var deployment
keeps working. Only four "bootstrap" settings stay environment-only, because
each would be circular to set through the page it enables: ADMIN_TOKEN (unlocks
/settings), SESSION_SECRET (signs the session), SECURE_COOKIES (cookie transport
flag), and CONFIG_FILE (where settings are stored).

Auth: single sign-on via an OpenID Connect provider (e.g. Authentik), using the
Authorization Code flow, optionally restricted to members of given provider
groups. Access fails closed -- if SSO is enabled but not fully configured, the
inbox is blocked rather than served without a login. Set it up at /settings, or
turn SSO off there to run open (local dev, or behind another auth proxy).
"""

import os
import sys
import json
import html
import hashlib
import logging
import secrets
import tempfile
from urllib.parse import urlencode, parse_qs

import boto3
from boto3.dynamodb.conditions import Key
from email import message_from_bytes
from email.policy import default as default_policy
from authlib.integrations.starlette_client import OAuth, OAuthError
from fastapi import FastAPI, Depends, Request
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

log = logging.getLogger("viewer")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Almost everything is configured through the setup wizard at /settings and
# persisted to CONFIG_FILE. Nothing *has* to be set in the environment anymore:
# the admin key that unlocks the wizard is created in the in-app first-run setup
# (see the Admin key section) and shown once. These env settings remain optional:
#   - ADMIN_TOKEN    pins the admin key to a fixed value instead of generating one
#                    (declarative / power-user path). Leave it unset to use the
#                    generated key.
#   - SESSION_SECRET signs the session cookie (incl. the admin unlock). Set it so
#                    logins and the admin unlock survive a restart; otherwise a
#                    throwaway one is generated per process.
#   - SECURE_COOKIES sets the cookie Secure flag at middleware init (a transport
#                    fact -- are you behind HTTPS?); it isn't changeable per-save.
#   - CONFIG_FILE    is *where* UI settings are stored, so it can't be one of them.
SESSION_SECRET = os.environ.get("SESSION_SECRET")
SECURE_COOKIES = os.environ.get("SECURE_COOKIES", "").lower() in ("1", "true", "yes")
ADMIN_TOKEN = os.environ.get("ADMIN_TOKEN", "")

# Where UI-entered settings are persisted. The container is otherwise stateless,
# so on-prem this should point at a mounted volume that survives recreation
# (the Dockerfile defaults it to /data/config.json).
CONFIG_FILE = os.environ.get("CONFIG_FILE", "/data/config.json")


def _bool_env(name: str) -> bool:
    return os.environ.get(name, "").lower() in ("1", "true", "yes")


def _groups_list(value) -> list:
    """Normalise allowed-groups from a list (file) or comma string (env/form)."""
    if isinstance(value, list):
        items = value
    else:
        items = str(value or "").split(",")
    return [g.strip() for g in items if str(g).strip()]


# The mutable application configuration. Seeded from the environment (so an
# existing env-var deployment keeps working), then overlaid by whatever has been
# saved through the UI. This is the single source of truth the request handlers
# read at call time -- so a save takes effect without a restart.
CONFIG = {
    # Display
    "app_title": os.environ.get("APP_TITLE", "inbox"),
    # AWS wiring (the backend the viewer reads from)
    "aws_region": os.environ.get("AWS_REGION")
                  or os.environ.get("AWS_DEFAULT_REGION", ""),
    "table_name": os.environ.get("TABLE_NAME", ""),
    "dynamodb_index": os.environ.get("DYNAMODB_INDEX", "global-index"),
    "bucket_name": os.environ.get("BUCKET_NAME", ""),
    "s3_prefix": os.environ.get("S3_PREFIX", "inbox/"),
    # AWS credentials. Blank = fall back to the standard boto3 chain (ambient
    # env vars, a mounted ~/.aws, or an instance/task role).
    "aws_access_key_id": os.environ.get("AWS_ACCESS_KEY_ID", ""),
    "aws_secret_access_key": os.environ.get("AWS_SECRET_ACCESS_KEY", ""),
    "aws_session_token": os.environ.get("AWS_SESSION_TOKEN", ""),
    # Auth (OIDC / Authentik)
    "auth_disabled": _bool_env("AUTH_DISABLED"),
    "oidc_discovery_url": os.environ.get("OIDC_DISCOVERY_URL", ""),
    "oidc_client_id": os.environ.get("OIDC_CLIENT_ID", ""),
    "oidc_client_secret": os.environ.get("OIDC_CLIENT_SECRET", ""),
    "oidc_redirect_uri": os.environ.get("OIDC_REDIRECT_URI", ""),
    "oidc_allowed_groups": _groups_list(os.environ.get("OIDC_ALLOWED_GROUPS", "")),
}

# Fields the UI is allowed to persist. The env-only bootstrap quartet
# (ADMIN_TOKEN / SESSION_SECRET / SECURE_COOKIES / CONFIG_FILE) is intentionally
# NOT here.
_PERSISTED_KEYS = tuple(CONFIG.keys())

# Secret fields: masked in the UI, and a blank form field means "keep existing".
_SECRET_KEYS = ("oidc_client_secret", "aws_secret_access_key", "aws_session_token")


# ---------------------------------------------------------------------------
# Admin key -- gates the setup wizard / settings pages
# ---------------------------------------------------------------------------
# The wizard configures OIDC, which is the app's own login, so it can't be
# protected by that login. It's gated by an "admin key" instead:
#   - If ADMIN_TOKEN is set, that IS the admin key (nothing generated or stored).
#   - Otherwise, on a brand-new install the app has NO key yet. The first time you
#     open it you're taken to an in-app first-run setup that generates the key on
#     demand and shows it ONCE in the browser (no log digging needed). Only a hash
#     is stored on the volume; the plaintext is never written to disk and can't be
#     shown again. Lost it? Regenerate from the CLI (the only recovery):
#         docker exec <container> python app.py reset-admin-key
ADMIN_KEY_FILE = os.environ.get(
    "ADMIN_KEY_FILE",
    os.path.join(os.path.dirname(CONFIG_FILE) or ".", "admin.key"),
)

_ADMIN_ENV_MODE = bool(ADMIN_TOKEN)   # admin key supplied via env, not generated
_ADMIN_KEY_HASH = ""                  # stored hash (generated-key mode)
_ADMIN_KEY_PLAINTEXT = None           # in-memory only, until revealed; never on disk
_ADMIN_KEY_REVEALED = True            # env mode has nothing to reveal


def _hash_admin_key(key: str) -> str:
    return hashlib.sha256(("viewer-admin-key:" + key).encode("utf-8")).hexdigest()


def _read_admin_key_file():
    try:
        with open(ADMIN_KEY_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (FileNotFoundError, OSError, ValueError):
        return None


def _write_admin_key_file(hash_hex: str, revealed: bool) -> None:
    directory = os.path.dirname(ADMIN_KEY_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".adminkey-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump({"hash": hash_hex, "revealed": revealed}, fh)
        os.chmod(tmp, 0o600)
        os.replace(tmp, ADMIN_KEY_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _new_admin_key() -> str:
    return secrets.token_urlsafe(30)


def init_admin_key() -> None:
    """Resolve the admin key at startup -- but never generate one here. In env mode
    it's ADMIN_TOKEN; otherwise load any stored hash. On a brand-new install there
    is no key yet; it's created on demand by the first-run setup in the UI."""
    global _ADMIN_KEY_HASH, _ADMIN_KEY_REVEALED
    if _ADMIN_ENV_MODE:
        _ADMIN_KEY_REVEALED = True
        return
    saved = _read_admin_key_file()
    if saved and saved.get("hash"):
        _ADMIN_KEY_HASH = saved["hash"]
        _ADMIN_KEY_REVEALED = bool(saved.get("revealed", True))
    else:
        log.info("No admin key yet -- open the app to run first-time setup.")


def admin_key_is_set() -> bool:
    """True once an admin key exists (env-pinned, or generated and stored)."""
    return _ADMIN_ENV_MODE or bool(_ADMIN_KEY_HASH)


def generate_admin_key() -> str:
    """Create the admin key on demand during first-run setup. Stores the hash,
    holds the plaintext in memory for its one-time reveal. Returns plaintext."""
    global _ADMIN_KEY_HASH, _ADMIN_KEY_PLAINTEXT, _ADMIN_KEY_REVEALED
    key = _new_admin_key()
    _ADMIN_KEY_HASH = _hash_admin_key(key)
    _ADMIN_KEY_PLAINTEXT = key
    _ADMIN_KEY_REVEALED = False
    _write_admin_key_file(_ADMIN_KEY_HASH, revealed=False)
    log.info("Admin key created via first-time setup.")
    return key


def reset_admin_key() -> str:
    """Generate a new admin key, store its hash, mark delivered. Returns plaintext."""
    global _ADMIN_KEY_HASH, _ADMIN_KEY_PLAINTEXT, _ADMIN_KEY_REVEALED
    key = _new_admin_key()
    _ADMIN_KEY_HASH = _hash_admin_key(key)
    _ADMIN_KEY_PLAINTEXT = None
    _ADMIN_KEY_REVEALED = True
    _write_admin_key_file(_ADMIN_KEY_HASH, revealed=True)
    return key


def check_admin_key(entered: str) -> bool:
    """Constant-time check of an entered key against the env token or stored hash."""
    if _ADMIN_ENV_MODE:
        return secrets.compare_digest(entered or "", ADMIN_TOKEN)
    if not _ADMIN_KEY_HASH:
        return False
    return secrets.compare_digest(_hash_admin_key(entered or ""), _ADMIN_KEY_HASH)


def admin_key_pending_reveal() -> bool:
    """True when a freshly generated key is waiting to be shown once."""
    return (not _ADMIN_ENV_MODE) and (not _ADMIN_KEY_REVEALED) and bool(_ADMIN_KEY_PLAINTEXT)


def mark_admin_key_revealed() -> None:
    """Record that the key has been shown; drop the in-memory plaintext for good."""
    global _ADMIN_KEY_PLAINTEXT, _ADMIN_KEY_REVEALED
    _ADMIN_KEY_REVEALED = True
    _ADMIN_KEY_PLAINTEXT = None
    if _ADMIN_KEY_HASH:
        _write_admin_key_file(_ADMIN_KEY_HASH, revealed=True)


def app_title() -> str:
    return CONFIG["app_title"] or "inbox"

oauth = OAuth()


def _load_persisted_config() -> None:
    """Overlay any saved config file onto CONFIG (env values are the fallback)."""
    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as fh:
            saved = json.load(fh)
    except FileNotFoundError:
        return
    except (OSError, ValueError) as exc:
        log.warning("Ignoring unreadable config file %s: %s", CONFIG_FILE, exc)
        return
    for key in _PERSISTED_KEYS:
        if key in saved:
            CONFIG[key] = (
                _groups_list(saved[key]) if key == "oidc_allowed_groups"
                else saved[key]
            )


def _save_persisted_config() -> None:
    """Atomically write the persisted subset of CONFIG to CONFIG_FILE (0600)."""
    data = {k: CONFIG[k] for k in _PERSISTED_KEYS}
    directory = os.path.dirname(CONFIG_FILE) or "."
    os.makedirs(directory, exist_ok=True)
    # Write to a temp file in the same dir, then rename -- never leaves a
    # half-written config that a concurrent reader could pick up.
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".config-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
        os.chmod(tmp, 0o600)  # the file holds secrets (OIDC + AWS credentials)
        os.replace(tmp, CONFIG_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def auth_enabled() -> bool:
    """Intent to require login. Independent of whether OIDC is fully wired --
    so an incomplete config blocks access (fails closed) rather than opening it."""
    return not CONFIG["auth_disabled"]


def oidc_ready() -> bool:
    """True when the OIDC client is registered and login can actually proceed."""
    return "oidc" in getattr(oauth, "_registry", {})


def configure_oauth() -> None:
    """(Re)build the OAuth client from CONFIG. Safe to call after every save."""
    global oauth
    oauth = OAuth()  # fresh registry; avoids 're-registering' errors
    if auth_enabled() and all((
        CONFIG["oidc_discovery_url"],
        CONFIG["oidc_client_id"],
        CONFIG["oidc_client_secret"],
    )):
        oauth.register(
            name="oidc",
            server_metadata_url=CONFIG["oidc_discovery_url"],
            client_id=CONFIG["oidc_client_id"],
            client_secret=CONFIG["oidc_client_secret"],
            client_kwargs={"scope": "openid email profile"},
        )
    elif auth_enabled():
        log.warning(
            "SSO login is enabled but OIDC is not fully configured -- access is "
            "blocked until it is set at /settings (or SSO is turned off there)."
        )


# AWS clients, (re)built from CONFIG. ``table`` is the DynamoDB Table used by the
# request handlers; ``s3`` the S3 client. Both are None until AWS is configured.
ddb = None
table = None
s3 = None
AWS_ERROR = ""  # last failure building the clients, surfaced in /settings


def build_aws_clients() -> None:
    """(Re)build the boto3 clients from CONFIG. Safe to call after every save.

    Credentials in CONFIG are used when present; otherwise boto3 falls back to
    its standard chain (ambient env vars, a mounted ~/.aws, or an instance/task
    role) -- so this stays compatible with credential-less deployments.
    """
    global ddb, table, s3, AWS_ERROR
    kwargs = {}
    if CONFIG["aws_region"]:
        kwargs["region_name"] = CONFIG["aws_region"]
    if CONFIG["aws_access_key_id"] and CONFIG["aws_secret_access_key"]:
        kwargs["aws_access_key_id"] = CONFIG["aws_access_key_id"]
        kwargs["aws_secret_access_key"] = CONFIG["aws_secret_access_key"]
        if CONFIG["aws_session_token"]:
            kwargs["aws_session_token"] = CONFIG["aws_session_token"]
    try:
        session = boto3.session.Session(**kwargs)
        s3 = session.client("s3")
        ddb = session.resource("dynamodb")
        table = ddb.Table(CONFIG["table_name"]) if CONFIG["table_name"] else None
        AWS_ERROR = ""
    except Exception as exc:  # e.g. NoRegionError before a region is set
        ddb = table = s3 = None
        AWS_ERROR = str(exc)
        log.warning("Could not build AWS clients yet: %s", exc)


def aws_ready() -> bool:
    """True when the clients exist and a table + bucket are configured."""
    return bool(table is not None and s3 is not None and CONFIG["bucket_name"])


def _test_aws():
    """Exercise the exact operations the app needs, using the current config.

    Returns (ok, [(check, ok, detail), ...]). Deliberately mirrors the app's
    real access pattern -- a Query on the feed index, then a HeadObject (same
    permission as GetObject) on a real key -- so it validates the *permissions*
    the viewer actually uses, not broader ones like ListBucket/DescribeTable.
    """
    if not aws_ready():
        detail = AWS_ERROR or "set region, table and bucket first"
        return False, [("AWS clients", False, detail)]
    checks = []
    ok_all = True
    sample_id = None
    try:
        resp = table.query(
            IndexName=CONFIG["dynamodb_index"],
            KeyConditionExpression=Key("inbox").eq("ALL"),
            ScanIndexForward=False,
            Limit=1,
        )
        items = resp.get("Items", [])
        sample_id = items[0].get("messageId") if items else None
        checks.append(("DynamoDB Query (feed index)", True,
                       f"{len(items)} row(s) returned"))
    except Exception as exc:
        ok_all = False
        checks.append(("DynamoDB Query (feed index)", False, str(exc)))
    if sample_id:
        try:
            s3.head_object(Bucket=CONFIG["bucket_name"],
                           Key=f"{CONFIG['s3_prefix']}{sample_id}")
            checks.append(("S3 GetObject (message body)", True, "object reachable"))
        except Exception as exc:
            ok_all = False
            checks.append(("S3 GetObject (message body)", False, str(exc)))
    else:
        checks.append(("S3 GetObject (message body)", True,
                       "skipped — no messages to test against"))
    return ok_all, checks


_load_persisted_config()
configure_oauth()
build_aws_clients()
init_admin_key()  # loads env/stored key; never generates (first-run setup does)

app = FastAPI(title="inbox")
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
    if not auth_enabled():
        return
    if not request.session.get("user"):
        raise NotAuthenticated()


def _callback_uri(request: Request) -> str:
    """The OIDC redirect URI: explicit configured value, else derived from the
    request. Behind a proxy set it explicitly so scheme/host match the provider."""
    return CONFIG["oidc_redirect_uri"] or str(request.url_for("auth_callback"))


def _group_allowed(userinfo: dict) -> bool:
    """True if no group restriction is set, or the user is in an allowed group."""
    allowed = CONFIG["oidc_allowed_groups"]
    if not allowed:
        return True
    user_groups = userinfo.get("groups") or []
    return any(g in allowed for g in user_groups)


def admin_ok(request: Request) -> bool:
    """Whether this session has unlocked the settings page with the admin key."""
    return bool(request.session.get("is_admin"))


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
    # Checkbox carries this row's messageId for bulk delete. The value is
    # attribute-quoted, so escape with quote=True.
    checkbox = (
        f"<input type=checkbox class=rowcheck name=ids "
        f"value=\"{html.escape(m['messageId'], quote=True)}\">"
    )
    return (
        f"<tr class='{'read' if is_read else 'unread'}'>"
        f"<td style='text-align:center'>{checkbox}</td>"
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
    links = ["<a href='/settings' style='font-size:13px'>Settings</a>"]
    if auth_enabled():
        links.append("<a href='/logout' style='font-size:13px'>Log out</a>")
    return (
        "<div style='float:right;display:flex;gap:1rem'>" + "".join(links) + "</div>"
    )


PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
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
 .toolbar{{display:flex;align-items:center;gap:.6rem;margin:.2rem 0 1rem}}
 .toolbar button{{font-size:13px;padding:.35rem .7rem;border:1px solid #ccc;
   border-radius:4px;background:#fff;cursor:pointer}}
 .toolbar button.danger{{color:#b00;border-color:#e0b4b4}}
 .toolbar button:disabled{{color:#bbb;border-color:#eee;cursor:default}}
 /* Phone: reflow each table row into a stacked card (sender + subject
    prominent; recipient/date/delete secondary). Desktop table unchanged. */
 @media (max-width:600px){{
  body{{margin:1rem}}
  thead{{display:none}}
  table,tbody,tr,td{{display:block}}
  tr{{display:flex;flex-wrap:wrap;align-items:baseline;gap:.15rem .5rem;
      border:1px solid #ddd;border-radius:8px;padding:.6rem .7rem;margin-bottom:.6rem}}
  td{{border:0;padding:0}}
  td:nth-child(1){{order:0}}                                   /* checkbox */
  td:nth-child(2){{order:1}}                                   /* read dot */
  td:nth-child(4){{order:2;flex:1;font-weight:600}}            /* From */
  td:nth-child(6){{order:3;color:#888;font-size:12px}}         /* Received */
  td:nth-child(5){{order:4;width:100%}}                        /* Subject */
  td:nth-child(3){{order:5;color:#888;font-size:12px}}         /* To */
  td:nth-child(3)::before{{content:'to: '}}
  td:nth-child(7){{order:6;margin-left:auto}}                  /* Delete */
 }}
</style>
{nav}
<h2>{title} &mdash; inbox{title_extra}</h2>
<p class=muted>Auto-refreshes every 10s (paused while you have messages selected).</p>
<form method=post action='/messages/delete' id=bulk>
 <div class=toolbar>
  <button type=submit id=delsel class=danger disabled
    onclick="return confirm('Delete the selected messages permanently?')">Delete selected</button>
  <button type=submit name=all value=1 class=danger
    onclick="return confirm('Delete ALL messages permanently?')">Delete all</button>
  <span class=muted id=selcount></span>
 </div>
 <table><thead><tr>
  <th><input type=checkbox id=checkall title='Select all'></th>
  <th></th><th>To</th><th>From</th><th>Subject</th><th>Received (UTC)</th><th></th>
 </tr></thead>
 <tbody>{rows}</tbody></table>
</form>
<script>
 // Auto-refresh, but only while nothing is selected -- so a reload never wipes
 // an in-progress selection. A plain <meta refresh> couldn't be paused.
 var timer = setTimeout(function(){{ location.reload(); }}, 10000);
 var checks = function(){{ return [].slice.call(document.querySelectorAll('.rowcheck')); }};
 var checkall = document.getElementById('checkall');
 var delsel = document.getElementById('delsel');
 var count = document.getElementById('selcount');
 function sync(){{
   var n = checks().filter(function(c){{ return c.checked; }}).length;
   delsel.disabled = n === 0;
   count.textContent = n ? n + ' selected' : '';
   if (checkall) checkall.checked = n > 0 && n === checks().length;
   if (n > 0 && timer) {{ clearTimeout(timer); timer = null; }}  // pause refresh
 }}
 if (checkall) checkall.addEventListener('change', function(){{
   checks().forEach(function(c){{ c.checked = checkall.checked; }});
   sync();
 }});
 document.addEventListener('change', function(e){{
   if (e.target.classList.contains('rowcheck')) sync();
 }});
 sync();
</script>"""


LOGIN_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
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
<meta name="viewport" content="width=device-width, initial-scale=1">
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


# First-run welcome: generate the admin key on demand (no logs needed).
SETUP_START_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; first-time setup</title>
<style>
 body{{font:14px system-ui,sans-serif;margin:0;display:flex;justify-content:center}}
 .wrap{{max-width:560px;padding:2.4rem 1.2rem}}
 h2{{margin:0 0 .4rem}}
 p{{color:#444;line-height:1.5}}
 ol{{color:#444;line-height:1.6;padding-left:1.2rem}}
 button{{margin-top:1rem;padding:.7rem 1.3rem;border:0;border-radius:4px;
         background:#0645ad;color:#fff;font-size:15px;cursor:pointer}}
 .muted{{color:#777;font-size:12px;margin-top:1.2rem}}
</style>
<div class=wrap>
 <h2>Welcome to {title}</h2>
 <p>Let's secure this install. First we'll create an <b>admin key</b> &mdash; it
    unlocks setup and settings. After that you'll configure the AWS backend and
    (optionally) single sign-on.</p>
 <ol>
  <li>Generate your admin key (shown once &mdash; save it in a password manager).</li>
  <li>Set up the AWS backend.</li>
  <li>Set up single sign-on, or run without a login.</li>
 </ol>
 <form method=post action='/setup/generate'>
  <button type=submit>Generate my admin key &rarr;</button>
 </form>
 <p class=muted>The key is generated here in the app &mdash; no need to read any
    logs. Only a hash is stored; the key itself is shown to you one time.</p>
</div>"""


# One-time reveal of the freshly generated admin key.
KEY_REVEAL_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; save your admin key</title>
<style>
 body{{font:14px system-ui,sans-serif;margin:0;display:flex;justify-content:center}}
 .wrap{{max-width:560px;padding:2rem 1.2rem}}
 h2{{margin:0 0 .3rem}}
 .key{{font:16px ui-monospace,Menlo,Consolas,monospace;background:#0b1021;color:#eef;
       padding:1rem;border-radius:8px;word-break:break-all;user-select:all;margin:1rem 0}}
 .warn{{background:#fffbe6;border:1px solid #ecd9a0;border-radius:8px;
        padding:.8rem 1rem;font-size:13px;color:#7a5c00;margin:1rem 0}}
 button{{padding:.6rem 1.2rem;border:0;border-radius:4px;background:#0645ad;
         color:#fff;font-size:14px;cursor:pointer}}
 code{{background:#f4f4f4;padding:.1rem .3rem;border-radius:3px}}
 .muted{{color:#777;font-size:12px}}
</style>
<div class=wrap>
 <h2>Welcome &mdash; here's your admin key</h2>
 <p>This key unlocks setup and settings. <b>It is shown only once.</b> Copy it into
    your password manager now.</p>
 <div class=key>{key}</div>
 <div class=warn>
  <b>Security:</b> if you did <i>not</i> just install this app, someone else may
  have seen this key. Reset it immediately:
  <br><code>docker exec &lt;container&gt; python app.py reset-admin-key</code>
 </div>
 <form method=post action='/setup/key'>
  <button type=submit>I've saved it &mdash; start setup &rarr;</button>
 </form>
 <p class=muted>Lost it later? It can't be recovered &mdash; regenerate it with the
    same command above.</p>
</div>"""


UNLOCK_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; unlock settings</title>
<style>
 body{{font:14px system-ui,sans-serif;display:flex;justify-content:center;
       align-items:center;min-height:90vh;margin:0}}
 .card{{border:1px solid #ddd;border-radius:8px;padding:2rem;width:320px}}
 h2{{margin:0 0 1rem;text-align:center}}
 label{{display:block;font-size:13px;color:#444;margin:0 0 .3rem}}
 input{{width:100%;box-sizing:border-box;padding:.5rem;border:1px solid #ccc;
        border-radius:4px;font-size:14px}}
 button{{margin-top:1rem;width:100%;padding:.6rem;border:0;border-radius:4px;
         background:#0645ad;color:#fff;font-size:14px;cursor:pointer}}
 .err{{color:#b00;font-size:13px;min-height:1.2em;margin:.4rem 0}}
 .hint{{color:#888;font-size:12px;margin-top:.8rem}}
 code{{background:#f4f4f4;padding:.1rem .3rem;border-radius:3px;word-break:break-all}}
</style>
<form class=card method=post action='/settings/unlock'>
 <h2>Unlock settings</h2>
 <div class=err>{error}</div>
 <label for=token>Admin key</label>
 <input id=token name=token type=password autofocus autocomplete=off>
 <button type=submit>Unlock</button>
 <p class=hint>{source_hint}</p>
</form>"""


# Shared stylesheet for the wizard/settings pages. Kept as a plain value (not a
# format template) so its CSS braces need no escaping -- it's injected via {css}.
SET_CSS = """<style>
 body{font:14px system-ui,sans-serif;margin:2rem;max-width:680px}
 a{color:#0645ad;text-decoration:none}
 h2{margin:.2rem 0}
 fieldset{border:1px solid #ddd;border-radius:8px;padding:1rem 1.2rem;margin:1.2rem 0}
 legend{font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#666;padding:0 .4rem}
 label{display:block;font-size:13px;color:#333;margin:.9rem 0 .3rem;font-weight:600}
 .hint{font-weight:400;color:#888;font-size:12px}
 input[type=text],input[type=url],input[type=password]{width:100%;box-sizing:border-box;
   padding:.5rem;border:1px solid #ccc;border-radius:4px;font-size:14px}
 .row{display:flex;align-items:center;gap:.5rem;margin:.4rem 0}
 .row label{margin:0;font-weight:600}
 button{padding:.55rem 1.1rem;border:0;border-radius:4px;background:#0645ad;
        color:#fff;font-size:14px;cursor:pointer}
 .ok{color:#0a7a34;font-size:13px;min-height:1.2em;font-weight:600}
 .warn{background:#fffbe6;border:1px solid #ecd9a0;border-radius:6px;
       padding:.6rem .8rem;font-size:13px;color:#7a5c00;margin:.6rem 0}
 code{background:#f4f4f4;padding:.1rem .3rem;border-radius:3px;word-break:break-all}
 .grid2{display:grid;grid-template-columns:1fr 1fr;gap:0 1rem}
 @media (max-width:560px){.grid2{grid-template-columns:1fr}}
 .test{border:1px solid #ddd;border-radius:8px;padding:.6rem .9rem;margin:.6rem 0;font-size:13px}
 .test .pass{color:#0a7a34} .test .fail{color:#b00}
 .test li{margin:.25rem 0;list-style:none} .test ul{padding-left:0;margin:.3rem 0}
 .buttons{display:flex;gap:.6rem;flex-wrap:wrap;margin-top:1rem;align-items:center}
 .buttons .secondary{background:#fff;color:#0645ad;border:1px solid #0645ad;
   text-decoration:none;display:inline-block;padding:.5rem 1.1rem;border-radius:4px}
 .topnav{font-size:13px;margin-bottom:.4rem}
 .steps{display:flex;gap:.6rem;font-size:12px;color:#aaa;margin:.5rem 0 1rem}
 .steps b{color:#0645ad} .steps .done{color:#0a7a34}
 .cards{display:flex;flex-direction:column;gap:.8rem;margin:1.2rem 0}
 .scard{border:1px solid #ddd;border-radius:8px;padding:.9rem 1.1rem;display:flex;
   justify-content:space-between;align-items:center;gap:1rem}
 .scard .meta{font-size:12px;color:#777;margin-top:.25rem}
 .badge{font-size:11px;padding:.1rem .55rem;border-radius:999px;margin-left:.3rem;
   vertical-align:middle}
 .badge.good{background:#e6f5ec;color:#0a7a34}
 .badge.bad{background:#fdecec;color:#b00}
 .badge.off{background:#eee;color:#666}
</style>"""


# Fields shared by the AWS step (General + AWS backend fieldsets).
_AWS_FIELDS_HTML = """
 <fieldset>
  <legend>General</legend>
  <label for=apptitle>App title
   <span class=hint>shown in the header and browser tab</span></label>
  <input id=apptitle name=app_title type=text value="{app_title}">
 </fieldset>
 <fieldset>
  <legend>AWS backend (DynamoDB + S3)</legend>
  <div class=grid2>
   <div><label for=region>Region</label>
    <input id=region name=aws_region type=text value="{aws_region}" placeholder="us-east-1"></div>
   <div><label for=index>DynamoDB index <span class=hint>the feed GSI</span></label>
    <input id=index name=dynamodb_index type=text value="{dynamodb_index}" placeholder="global-index"></div>
   <div><label for=table>DynamoDB table</label>
    <input id=table name=table_name type=text value="{table_name}" placeholder="demoworldfun-messages"></div>
   <div><label for=bucket>S3 bucket</label>
    <input id=bucket name=bucket_name type=text value="{bucket_name}" placeholder="demoworldfun-inbound-mail"></div>
   <div><label for=prefix>S3 prefix</label>
    <input id=prefix name=s3_prefix type=text value="{s3_prefix}" placeholder="inbox/"></div>
  </div>
  <label for=akid>Access key ID
   <span class=hint>leave all three credential fields blank to use an instance/task
     role or a mounted ~/.aws instead</span></label>
  <input id=akid name=aws_access_key_id type=text value="{aws_access_key_id}" autocomplete=off>
  <label for=asak>Secret access key <span class=hint>{aws_secret_hint}</span></label>
  <input id=asak name=aws_secret_access_key type=password value=""
    autocomplete=off placeholder="{aws_secret_placeholder}">
  <label for=astok>Session token
   <span class=hint>only for temporary/SSO credentials; {aws_token_hint}</span></label>
  <input id=astok name=aws_session_token type=password value=""
    autocomplete=off placeholder="{aws_token_placeholder}">
  <p class=hint>The IAM identity needs, at minimum:
     <code>dynamodb:Query</code>, <code>UpdateItem</code>, <code>DeleteItem</code>
     on the table + its index, and <code>s3:GetObject</code>, <code>DeleteObject</code>
     on the bucket. Use &ldquo;Test connection&rdquo; to verify.</p>
 </fieldset>"""


_SSO_FIELDS_HTML = """
 <fieldset>
  <legend>Single sign-on (OpenID Connect / Authentik)</legend>
  <div class=row>
   <input id=enable name=auth_enabled type=checkbox value=1 {enabled_checked}>
   <label for=enable>Require SSO login</label>
  </div>
  <p class=hint>When unchecked, the app runs with no login (anyone who can reach it
     sees the inbox). Leave it on for anything beyond a trusted LAN.</p>
  <label for=disc>Discovery URL
   <span class=hint>Authentik: Provider &rarr; OpenID Configuration URL</span></label>
  <input id=disc name=oidc_discovery_url type=url value="{discovery}"
    placeholder="https://authtime.example.com/application/o/&lt;slug&gt;/.well-known/openid-configuration">
  <label for=cid>Client ID</label>
  <input id=cid name=oidc_client_id type=text value="{client_id}" autocomplete=off>
  <label for=csec>Client secret <span class=hint>{secret_hint}</span></label>
  <input id=csec name=oidc_client_secret type=password value=""
    autocomplete=off placeholder="{secret_placeholder}">
  <label for=redir>Redirect URI
   <span class=hint>Must EXACTLY match the one registered in Authentik</span></label>
  <input id=redir name=oidc_redirect_uri type=url value="{redirect_uri}"
    placeholder="{redirect_suggestion}">
  <p class=hint>This app's callback path is <code>/auth/callback</code> &mdash; based on
     how you reached this page, likely <code>{redirect_suggestion}</code>.</p>
  <label for=groups>Allowed groups
   <span class=hint>comma-separated; blank = any authenticated user</span></label>
  <input id=groups name=oidc_allowed_groups type=text value="{allowed_groups}">
 </fieldset>"""


OVERVIEW_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; settings</title>{css}
<div class=topnav><a href='/'>&larr; inbox</a> &nbsp;·&nbsp; <a href='/settings/lock'>Lock settings</a></div>
<h2>{title} &mdash; settings</h2>
<div class=ok>{status}</div>
{state_banner}
<div class=cards>
 <div class=scard>
  <div><b>AWS backend</b>{aws_badge}<div class=meta>{aws_meta}</div></div>
  <a class=secondary href='/settings/aws'>{aws_action}</a>
 </div>
 <div class=scard>
  <div><b>Single sign-on</b>{sso_badge}<div class=meta>{sso_meta}</div></div>
  <a class=secondary href='/settings/sso'>{sso_action}</a>
 </div>
</div>
<fieldset>
 <legend>Admin key</legend>
 <p class=hint>{admin_key_note}</p>
</fieldset>"""


AWS_STEP_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; AWS backend</title>{css}
<div class=topnav><a href='/settings'>&larr; settings</a> &nbsp;·&nbsp; <a href='/'>inbox</a></div>
<h2>AWS backend</h2>
<div class=steps><b>1 &middot; AWS backend</b><span>&rarr;</span><span>2 &middot; Single sign-on</span></div>
<div class=ok>{status}</div>
{state_banner}
{aws_test}
<form method=post action='/settings/aws'>""" + _AWS_FIELDS_HTML + """
 <div class=buttons>
  <button type=submit name=action value=test class=secondary>Test connection</button>
  <button type=submit name=action value=save>Save</button>
  <button type=submit name=action value=continue>Save &amp; continue &rarr;</button>
 </div>
</form>"""


SSO_STEP_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; single sign-on</title>{css}
<div class=topnav><a href='/settings'>&larr; settings</a> &nbsp;·&nbsp; <a href='/'>inbox</a></div>
<h2>Single sign-on</h2>
<div class=steps><span class=done>1 &middot; AWS backend &#10003;</span><span>&rarr;</span><b>2 &middot; Single sign-on</b></div>
<div class=ok>{status}</div>
{state_banner}
<form method=post action='/settings/sso'>""" + _SSO_FIELDS_HTML + """
 <div class=buttons>
  <button type=submit name=action value=save>Save</button>
  <button type=submit name=action value=finish>Save &amp; finish &rarr;</button>
 </div>
</form>"""


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
    # Brand-new install: there's no admin key yet, so nothing is configured --
    # send the first visitor into first-run setup rather than an SSO dead-end.
    if not admin_key_is_set():
        return RedirectResponse("/setup", status_code=302)
    if not auth_enabled() or request.session.get("user"):
        return RedirectResponse("/", status_code=302)
    if not oidc_ready():
        # SSO is on but not fully configured -- don't 500 on oauth.oidc; point an
        # admin at the settings page instead. Access stays blocked meanwhile.
        return HTMLResponse(
            LOGIN_PAGE.format(
                title=html.escape(app_title()),
                error=html.escape(
                    "SSO is enabled but not configured yet. An administrator can "
                    "set it up at /settings."
                ),
            )
        )
    if error:
        messages = {
            "denied": "Your account is not permitted to access this app.",
            "failed": "Sign-in failed. Please try again.",
        }
        msg = messages.get(error, "Sign-in failed. Please try again.")
        return HTMLResponse(
            LOGIN_PAGE.format(title=html.escape(app_title()), error=html.escape(msg))
        )
    try:
        return await oauth.oidc.authorize_redirect(request, _callback_uri(request))
    except Exception:
        # Reaching the provider failed -- almost always a wrong discovery URL or
        # an unreachable Authentik. Show a helpful message instead of a raw 500;
        # an admin can fix the discovery URL at /settings.
        log.exception("Could not start OIDC flow (check the discovery URL)")
        return HTMLResponse(
            LOGIN_PAGE.format(
                title=html.escape(app_title()),
                error=html.escape(
                    "Could not reach the SSO provider. An administrator should "
                    "check the discovery URL at /settings."
                ),
            ),
            status_code=502,
        )


@app.get("/auth/callback", name="auth_callback")
async def auth_callback(request: Request):
    """OIDC redirect target: exchange the code, enforce group policy, log in."""
    if not auth_enabled() or not oidc_ready():
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
    return LOGGED_OUT_PAGE.format(title=html.escape(app_title()))


# ---------------------------------------------------------------------------
# Settings / setup wizard (AWS + OIDC configured through the UI)
# ---------------------------------------------------------------------------
# Access is gated by the admin KEY, NOT by SSO -- SSO is the very thing configured
# here, so it can't protect its own setup page. The key is created by the in-app
# first-run setup (shown once) or pinned via ADMIN_TOKEN; see the Admin key section.
def _admin_guard(request: Request):
    """Return None if allowed, else a Response to send instead (setup / unlock)."""
    if admin_ok(request):
        return None
    if not admin_key_is_set():
        return RedirectResponse("/setup", status_code=302)   # first-run: make a key
    if admin_key_pending_reveal():
        return RedirectResponse("/setup/key", status_code=302)  # show it once
    return RedirectResponse("/settings/unlock", status_code=302)


def _redirect_suggestion(request: Request) -> str:
    try:
        return str(request.url_for("auth_callback"))
    except Exception:
        return "https://your-app-host/auth/callback"


@app.get("/setup", response_class=HTMLResponse)
def setup_start(request: Request):
    """First-run welcome: create the admin key in the UI (no logs needed)."""
    if admin_ok(request):
        return RedirectResponse("/settings", status_code=302)
    if admin_key_pending_reveal():
        return RedirectResponse("/setup/key", status_code=302)
    if admin_key_is_set():
        # Key already exists (env-pinned or set on a prior run) -> just unlock.
        return RedirectResponse("/settings/unlock", status_code=302)
    return HTMLResponse(SETUP_START_PAGE.format(title=html.escape(app_title())))


@app.post("/setup/generate")
async def setup_generate(request: Request):
    """Generate the admin key on demand, then reveal it once."""
    if _ADMIN_ENV_MODE or (admin_key_is_set() and not admin_key_pending_reveal()):
        # Already have a key; don't clobber it -> go unlock instead.
        return RedirectResponse("/settings/unlock", status_code=303)
    if not admin_key_pending_reveal():
        generate_admin_key()
    return RedirectResponse("/setup/key", status_code=303)


@app.get("/setup/key", response_class=HTMLResponse)
def setup_key_form(request: Request):
    """One-time reveal of the freshly generated admin key."""
    if admin_key_pending_reveal():
        return HTMLResponse(
            KEY_REVEAL_PAGE.format(
                title=html.escape(app_title()),
                key=html.escape(_ADMIN_KEY_PLAINTEXT or "", quote=True),
            )
        )
    # Nothing to reveal: not created yet, already shown, env-pinned, or lost on a restart.
    if admin_ok(request):
        return RedirectResponse("/settings", status_code=302)
    if not admin_key_is_set():
        return RedirectResponse("/setup", status_code=302)
    return RedirectResponse("/settings/unlock", status_code=302)


@app.post("/setup/key")
async def setup_key_ack(request: Request):
    """'I've saved it' -> mark revealed, unlock this session, start the wizard."""
    if admin_key_pending_reveal():
        mark_admin_key_revealed()
        request.session["is_admin"] = True
        return RedirectResponse("/settings", status_code=303)
    return RedirectResponse("/settings/unlock", status_code=303)


@app.get("/settings/unlock", response_class=HTMLResponse)
def settings_unlock_form(request: Request, error: str = ""):
    if admin_ok(request):
        return RedirectResponse("/settings", status_code=302)
    if admin_key_pending_reveal():
        return RedirectResponse("/setup/key", status_code=302)
    msg = "Incorrect admin key." if error else ""
    return HTMLResponse(
        UNLOCK_PAGE.format(
            title=html.escape(app_title()),
            error=html.escape(msg),
            source_hint=_unlock_source_hint(),
        )
    )


@app.post("/settings/unlock")
async def settings_unlock(request: Request):
    fields = parse_qs((await request.body()).decode("utf-8"))
    key = fields.get("token", [""])[0]
    if check_admin_key(key):
        request.session["is_admin"] = True
        return RedirectResponse("/settings", status_code=303)
    return RedirectResponse("/settings/unlock?error=1", status_code=303)


def _unlock_source_hint() -> str:
    if _ADMIN_ENV_MODE:
        return "This is the <code>ADMIN_TOKEN</code> set in the container environment."
    return ("The key created during first-time setup. Lost it? Run "
            "<code>docker exec &lt;container&gt; python app.py reset-admin-key</code>.")


@app.get("/settings/lock")
def settings_lock(request: Request):
    request.session.pop("is_admin", None)
    return RedirectResponse("/", status_code=302)


def _secret_ui(key: str):
    """(hint, placeholder) for a masked secret field: blank keeps the saved value."""
    if CONFIG[key]:
        return "a value is saved &mdash; leave blank to keep it", "•••••••• (unchanged)"
    return "not set yet", "paste value"


def _test_block_html(checks) -> str:
    if not checks:
        return ""
    items = []
    for name, ok, detail in checks:
        mark = "<span class=pass>PASS</span>" if ok else "<span class=fail>FAIL</span>"
        items.append(
            f"<li>{mark} &nbsp;{html.escape(name)} "
            f"<span class=hint>&mdash; {html.escape(detail)}</span></li>"
        )
    return ("<div class=test><b>AWS connection test</b><ul>"
            + "".join(items) + "</ul></div>")


def _esc_cfg(key: str) -> str:
    return html.escape(CONFIG[key], quote=True)


def _nothing_configured() -> bool:
    """True on a brand-new install: no AWS wiring and no OIDC set up yet."""
    return not any((
        CONFIG["table_name"], CONFIG["bucket_name"], CONFIG["aws_region"],
        CONFIG["oidc_discovery_url"],
    ))


def _render_overview(request: Request, status: str = "") -> HTMLResponse:
    # AWS status
    if aws_ready():
        aws_badge = "<span class='badge good'>Configured</span>"
        aws_meta = " &middot; ".join(filter(None, [
            html.escape(CONFIG["aws_region"] or "?region"),
            html.escape(CONFIG["table_name"] or "?table"),
            html.escape(CONFIG["bucket_name"] or "?bucket"),
        ]))
        aws_action = "Edit"
    else:
        aws_badge = "<span class='badge bad'>Not set up</span>"
        aws_meta = html.escape(AWS_ERROR) if AWS_ERROR else "region, table and bucket needed"
        aws_action = "Set up"

    # SSO status
    if not auth_enabled():
        sso_badge = "<span class='badge off'>Disabled</span>"
        sso_meta = "no login required &mdash; anyone who can reach the app sees the inbox"
        sso_action = "Set up"
    elif oidc_ready():
        sso_badge = "<span class='badge good'>Enabled</span>"
        host = ""
        try:
            from urllib.parse import urlparse
            host = urlparse(CONFIG["oidc_discovery_url"]).netloc
        except Exception:
            pass
        sso_meta = "login via " + (html.escape(host) or "OIDC provider")
        sso_action = "Edit"
    else:
        sso_badge = "<span class='badge bad'>Incomplete</span>"
        sso_meta = "SSO is on but not fully configured &mdash; the inbox is blocked"
        sso_action = "Finish"

    if _ADMIN_ENV_MODE:
        admin_note = ("The admin key is pinned via <code>ADMIN_TOKEN</code> in the "
                      "container environment.")
    else:
        admin_note = ("Created during first-time setup and shown once. Lost it? It "
                      "can't be recovered &mdash; issue a new one with "
                      "<code>docker exec &lt;container&gt; python app.py reset-admin-key</code>.")

    banner = ""
    if not _nothing_configured() and auth_enabled() and not oidc_ready():
        banner = ("<div class=warn>SSO is on but incomplete, so the inbox is blocked. "
                  "Finish the SSO step or turn SSO off.</div>")

    page = OVERVIEW_PAGE.format(
        title=html.escape(app_title()), status=html.escape(status),
        css=SET_CSS,
        state_banner=banner,
        aws_badge=aws_badge, aws_meta=aws_meta, aws_action=aws_action,
        sso_badge=sso_badge, sso_meta=sso_meta, sso_action=sso_action,
        admin_key_note=admin_note,
    )
    return HTMLResponse(page)


def _render_aws_step(request: Request, status: str = "", checks=None) -> HTMLResponse:
    banner = ""
    if not aws_ready():
        why = f" ({html.escape(AWS_ERROR)})" if AWS_ERROR else ""
        banner = ("<div class=warn>AWS backend is <b>not configured yet</b>"
                  f"{why}. Fill in the region, table and bucket below.</div>")
    sec_hint, sec_ph = _secret_ui("aws_secret_access_key")
    tok_hint, tok_ph = _secret_ui("aws_session_token")
    page = AWS_STEP_PAGE.format(
        title=html.escape(app_title()), status=html.escape(status),
        css=SET_CSS,
        state_banner=banner, aws_test=_test_block_html(checks),
        app_title=_esc_cfg("app_title"), aws_region=_esc_cfg("aws_region"),
        dynamodb_index=_esc_cfg("dynamodb_index"), table_name=_esc_cfg("table_name"),
        bucket_name=_esc_cfg("bucket_name"), s3_prefix=_esc_cfg("s3_prefix"),
        aws_access_key_id=_esc_cfg("aws_access_key_id"),
        aws_secret_hint=sec_hint, aws_secret_placeholder=sec_ph,
        aws_token_hint=tok_hint, aws_token_placeholder=tok_ph,
    )
    return HTMLResponse(page)


def _render_sso_step(request: Request, status: str = "") -> HTMLResponse:
    banner = ""
    if auth_enabled() and not oidc_ready():
        banner = ("<div class=warn>SSO is <b>on</b> but not fully configured, so the "
                  "inbox is blocked until you finish here (or turn SSO off).</div>")
    elif not auth_enabled():
        banner = ("<div class=warn>SSO is <b>off</b> &mdash; the inbox is open to "
                  "anyone who can reach this app.</div>")
    sec_hint, sec_ph = _secret_ui("oidc_client_secret")
    page = SSO_STEP_PAGE.format(
        title=html.escape(app_title()), status=html.escape(status),
        css=SET_CSS,
        state_banner=banner,
        enabled_checked="checked" if auth_enabled() else "",
        discovery=_esc_cfg("oidc_discovery_url"), client_id=_esc_cfg("oidc_client_id"),
        secret_hint=sec_hint, secret_placeholder=sec_ph,
        redirect_uri=_esc_cfg("oidc_redirect_uri"),
        redirect_suggestion=html.escape(_redirect_suggestion(request), quote=True),
        allowed_groups=html.escape(", ".join(CONFIG["oidc_allowed_groups"]), quote=True),
    )
    return HTMLResponse(page)


@app.get("/settings", response_class=HTMLResponse)
def settings_overview(request: Request, done: str = ""):
    blocked = _admin_guard(request)
    if blocked is not None:
        return blocked
    # Brand-new install: drop straight into the wizard at step 1.
    if _nothing_configured():
        return RedirectResponse("/settings/aws", status_code=302)
    status = "Setup complete." if done else ""
    return _render_overview(request, status=status)


def _save_aws_from_form(fields) -> None:
    one = lambda k: fields.get(k, [""])[0].strip()  # noqa: E731
    CONFIG["app_title"] = one("app_title") or "inbox"
    CONFIG["aws_region"] = one("aws_region")
    CONFIG["table_name"] = one("table_name")
    CONFIG["dynamodb_index"] = one("dynamodb_index") or "global-index"
    CONFIG["bucket_name"] = one("bucket_name")
    CONFIG["s3_prefix"] = one("s3_prefix")
    CONFIG["aws_access_key_id"] = one("aws_access_key_id")
    for key in ("aws_secret_access_key", "aws_session_token"):
        v = one(key)
        if v:
            CONFIG[key] = v
    _save_persisted_config()
    build_aws_clients()


def _save_sso_from_form(fields) -> None:
    one = lambda k: fields.get(k, [""])[0].strip()  # noqa: E731
    CONFIG["auth_disabled"] = not bool(fields.get("auth_enabled"))
    CONFIG["oidc_discovery_url"] = one("oidc_discovery_url")
    CONFIG["oidc_client_id"] = one("oidc_client_id")
    CONFIG["oidc_redirect_uri"] = one("oidc_redirect_uri")
    CONFIG["oidc_allowed_groups"] = _groups_list(one("oidc_allowed_groups"))
    v = one("oidc_client_secret")
    if v:
        CONFIG["oidc_client_secret"] = v
    _save_persisted_config()
    configure_oauth()


@app.get("/settings/aws", response_class=HTMLResponse)
def settings_aws_form(request: Request):
    blocked = _admin_guard(request)
    if blocked is not None:
        return blocked
    return _render_aws_step(request)


@app.post("/settings/aws")
async def settings_aws_save(request: Request):
    blocked = _admin_guard(request)
    if blocked is not None:
        return blocked
    fields = parse_qs((await request.body()).decode("utf-8"))
    action = fields.get("action", [""])[0]
    _save_aws_from_form(fields)
    if action == "continue":
        return RedirectResponse("/settings/sso", status_code=303)
    if action == "test":
        ok, checks = _test_aws()
        msg = "Saved. Connection OK." if ok else "Saved, but the test found problems:"
        return _render_aws_step(request, status=msg, checks=checks)
    return _render_aws_step(request, status="Saved.")


@app.get("/settings/sso", response_class=HTMLResponse)
def settings_sso_form(request: Request):
    blocked = _admin_guard(request)
    if blocked is not None:
        return blocked
    return _render_sso_step(request)


@app.post("/settings/sso")
async def settings_sso_save(request: Request):
    blocked = _admin_guard(request)
    if blocked is not None:
        return blocked
    fields = parse_qs((await request.body()).decode("utf-8"))
    action = fields.get("action", [""])[0]
    _save_sso_from_form(fields)
    if action == "finish":
        return RedirectResponse("/settings?done=1", status_code=303)
    status = "Saved."
    if auth_enabled() and not oidc_ready():
        status = "Saved, but SSO is still incomplete — see the notice above."
    return _render_sso_step(request, status=status)


BACKEND_PROBLEM_PAGE = """<!doctype html><meta charset=utf-8>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} &mdash; backend problem</title>
<style>
 body{{font:14px system-ui,sans-serif;margin:2rem;max-width:640px}}
 a{{color:#0645ad}}
 .card{{border:1px solid #ecd9a0;background:#fffbe6;border-radius:8px;
        padding:1rem 1.2rem;color:#5c4a00}}
 code{{background:#00000010;padding:.1rem .3rem;border-radius:3px;word-break:break-word}}
</style>
{nav}
<h2>{title}</h2>
<div class=card>{body}</div>"""


def _backend_page(body: str, status_code: int) -> HTMLResponse:
    return HTMLResponse(
        BACKEND_PROBLEM_PAGE.format(
            title=html.escape(app_title()), nav=_nav(), body=body
        ),
        status_code=status_code,
    )


def _backend_unconfigured() -> HTMLResponse:
    why = f" <p>Last error: <code>{html.escape(AWS_ERROR)}</code></p>" if AWS_ERROR else ""
    return _backend_page(
        "<p>The AWS backend isn't configured yet, so there's no inbox to show.</p>"
        "<p>An administrator can set the region, DynamoDB table, and S3 bucket at "
        "<a href='/settings'>Settings</a>.</p>" + why,
        status_code=503,
    )


def _backend_error(exc: Exception) -> HTMLResponse:
    """A backend call failed at request time -- almost always wrong credentials
    or a missing IAM permission. Show the error and point at the test button,
    rather than a raw 500."""
    log.warning("Backend read failed: %s", exc)
    return _backend_page(
        "<p>Couldn't read the AWS backend.</p>"
        f"<p>The backend returned: <code>{html.escape(str(exc))}</code></p>"
        "<p>Verify the credentials and IAM permissions at "
        "<a href='/settings'>Settings</a> with &ldquo;Save &amp; test AWS&rdquo;.</p>",
        status_code=502,
    )


@app.get("/", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def inbox_all():
    # Brand-new install: send the first visitor through first-run setup.
    if not admin_key_is_set():
        return RedirectResponse("/setup", status_code=302)
    if not aws_ready():
        return _backend_unconfigured()
    try:
        resp = table.query(
            IndexName=CONFIG["dynamodb_index"],
            KeyConditionExpression=Key("inbox").eq("ALL"),
            ScanIndexForward=False,
            Limit=100,
        )
    except Exception as exc:
        return _backend_error(exc)
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        title=html.escape(app_title()),
        nav=_nav(),
        rows=rows or "<tr><td colspan=7 class=muted>No mail yet.</td></tr>",
        title_extra="",
    )


@app.get("/inbox/{address}", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def inbox_for(address: str):
    if not aws_ready():
        return _backend_unconfigured()
    try:
        resp = table.query(
            KeyConditionExpression=Key("recipient").eq(address.lower()),
            ScanIndexForward=False,
            Limit=100,
        )
    except Exception as exc:
        return _backend_error(exc)
    rows = "".join(_row(m) for m in resp.get("Items", []))
    return PAGE.format(
        title=html.escape(app_title()),
        nav=_nav(),
        rows=rows or "<tr><td colspan=7 class=muted>No mail.</td></tr>",
        title_extra=f" &mdash; {html.escape(address)}",
    )


@app.get("/message/{message_id}", response_class=HTMLResponse, dependencies=[Depends(require_login)])
def view_message(message_id: str, r: str = "", t: str = ""):
    if not aws_ready():
        return _backend_unconfigured()
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

    key = f"{CONFIG['s3_prefix']}{message_id}"
    raw = s3.get_object(Bucket=CONFIG["bucket_name"], Key=key)["Body"].read()
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
        # Render untrusted email HTML inside a sandboxed iframe. Scripts and
        # same-origin access stay OFF -- the email still can't run code or read
        # this app's session. We allow ONLY popups, so links open in a new tab:
        #   - allow-popups                    -> target=_blank links can open
        #   - allow-popups-to-escape-sandbox  -> the opened tab is a normal page
        # A prepended <base target=_blank> makes every link open in a new tab,
        # even ones the email didn't tag (modern browsers imply rel=noopener).
        # The injected <meta viewport> + reset caps images and tables to the
        # box width so fixed-width (e.g. 600px) emails fit on a phone instead
        # of overflowing. width!important overrides inline widths on wide
        # layout tables; images scale down and keep their aspect ratio.
        head = (
            # Doctype first forces standards mode so width:100% resolves against
            # the iframe viewport (in quirks mode a wide table won't shrink).
            "<!doctype html>"
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<base target="_blank">'
            '<style>'
            'html{-webkit-text-size-adjust:100%}'
            'body{margin:0}'
            # Cap images and fixed-width layout tables to the box so a desktop
            # (e.g. 600px) email fits on a phone. A broken image is the one case
            # that can still overflow (it falls back to its width attribute and
            # ignores max-width) -- allow that to scroll rather than clipping the
            # surrounding text.
            'img{max-width:100%!important;height:auto}'
            'table{max-width:100%!important}'
            '</style>'
        )
        srcdoc = html.escape(head + content, quote=True)
        rendered = (
            "<iframe sandbox='allow-popups allow-popups-to-escape-sandbox' "
            "style='width:100%;height:70vh;border:1px solid #ccc' "
            f"srcdoc=\"{srcdoc}\"></iframe>"
        )
    else:
        rendered = f"<pre style='white-space:pre-wrap;overflow-wrap:anywhere'>{html.escape(content)}</pre>"

    return (
        "<!doctype html><meta charset=utf-8>"
        "<meta name='viewport' content='width=device-width, initial-scale=1'>"
        "<body style='font:14px system-ui,sans-serif;margin:2rem;overflow-wrap:anywhere'>"
        "<style>@media(max-width:600px){body{margin:1rem}}</style>"
        "<a href='/'>&larr; inbox</a>"
        + ("<a href='/logout' style='margin-left:1rem;font-size:13px'>Log out</a>"
           if auth_enabled() else "")
        + f"<span style='float:right'>{_delete_button(html.escape(message_id))}</span>"
        "<hr>"
        f"{meta}{rendered}"
    )


def _purge_messages(message_ids=None):
    """Permanently remove messages: raw emails in S3 and all index rows.

    Walks the global feed ONCE (small at demo volume). If message_ids is None,
    everything is deleted; otherwise only rows whose messageId is in the set.
    Doing it in a single pass keeps "delete all" and multi-select linear rather
    than re-scanning the feed per message. S3 objects are deleted once per
    distinct messageId (a message can have one index row per recipient).
    """
    deleted_from_s3 = set()
    start_key = None
    while True:
        kwargs = dict(
            IndexName=CONFIG["dynamodb_index"],
            KeyConditionExpression=Key("inbox").eq("ALL"),
        )
        if start_key:
            kwargs["ExclusiveStartKey"] = start_key
        resp = table.query(**kwargs)
        for it in resp.get("Items", []):
            mid = it.get("messageId")
            if message_ids is not None and mid not in message_ids:
                continue
            # One DeleteItem per row -- uses the same dynamodb:DeleteItem
            # permission the single-message delete already relies on, so no
            # extra IAM (BatchWriteItem) is needed to run this.
            table.delete_item(Key={
                "recipient": it["recipient"],
                "receivedAt": it["receivedAt"],
            })
            if mid and mid not in deleted_from_s3:
                deleted_from_s3.add(mid)
                try:
                    s3.delete_object(
                        Bucket=CONFIG["bucket_name"],
                        Key=f"{CONFIG['s3_prefix']}{mid}",
                    )
                except Exception:
                    pass  # already gone / expired — index cleanup still runs
        start_key = resp.get("LastEvaluatedKey")
        if not start_key:
            break


@app.post("/message/{message_id}/delete", dependencies=[Depends(require_login)])
def delete_message(message_id: str):
    """Permanently remove a single message: the raw email in S3 and index rows."""
    if not aws_ready():
        return _backend_unconfigured()
    _purge_messages({message_id})
    # 303 -> browser re-requests the inbox with GET
    return RedirectResponse("/", status_code=303)


@app.post("/messages/delete", dependencies=[Depends(require_login)])
async def delete_messages(request: Request):
    """Bulk delete: the selected messageIds, or every message when 'all' is set."""
    if not aws_ready():
        return _backend_unconfigured()
    # Parse the urlencoded form body directly so we don't need python-multipart
    # (nothing else in this app parses form bodies). parse_qs returns each
    # field as a list, so 'ids' naturally collects every checked box.
    fields = parse_qs((await request.body()).decode("utf-8"))
    if fields.get("all"):
        _purge_messages(None)  # delete everything
    else:
        ids = set(fields.get("ids", []))
        if ids:
            _purge_messages(ids)
    return RedirectResponse("/", status_code=303)


# ---------------------------------------------------------------------------
# CLI: `python app.py reset-admin-key`
# ---------------------------------------------------------------------------
# Run inside the container to recover admin access if the key is lost:
#   docker exec <container> python app.py reset-admin-key
def _cli_main(argv) -> int:
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "reset-admin-key":
        if _ADMIN_ENV_MODE:
            print("ADMIN_TOKEN is set in the environment, so the admin key is that "
                  "value.\nChange it in your compose/stack env instead -- nothing to "
                  "reset here.")
            return 1
        new_key = reset_admin_key()
        print("\nNew admin key (save it now -- it will not be shown again):\n")
        print("    " + new_key + "\n")
        print("Go to the app's /settings and unlock with this key.")
        return 0
    print("Usage: python app.py reset-admin-key")
    return 2


if __name__ == "__main__":
    sys.exit(_cli_main(sys.argv))
