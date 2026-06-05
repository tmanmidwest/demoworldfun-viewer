#!/bin/bash
# =============================================================================
# teardown.sh — Remove the demoworldfun SES receiving backend
# =============================================================================
# Reverses build.sh. REFUSES to run if the viewer is still deployed (it reads
# this backend). Tear the viewer down first, or set FORCE=1 to override.
#
# Reads .demoworldfun-backend-state, or rediscovers from it / defaults.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-backend-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

# Viewer resource names (from the viewer suite) — used to detect a live viewer
VIEWER_CLUSTER="demoworldfun-viewer"
VIEWER_SERVICE="demoworldfun-viewer-web"
VIEWER_ROLE="demoworldfun-viewer-task-role"

header "Validating AWS session"
aws sts get-caller-identity >/dev/null 2>&1 \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
success "Logged in"

# ── LOAD STATE ────────────────────────────────────────────────────────────────
if [ -f "$STATE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  warn "No state file — using defaults; pass values via env if you customized them."
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  DOMAIN="${DOMAIN:-demoworldfun.net}"
  BUCKET="${BUCKET:-demoworldfun-inbound-mail}"
  TABLE="${TABLE:-demoworldfun-messages}"
  RULESET="${RULESET:-demoworldfun-rules}"
  RULE="${RULE:-catch-all}"
  LAMBDA_FN="${LAMBDA_FN:-demoworldfun-index}"
  ROLE="${ROLE:-demoworldfun-index-role}"
  MX_ENDPOINT="${MX_ENDPOINT:-inbound-smtp.${REGION}.amazonaws.com}"
fi

# ── VIEWER GUARD ──────────────────────────────────────────────────────────────
header "Checking for a live viewer"
viewer_present() {
  aws iam get-role --role-name "$VIEWER_ROLE" >/dev/null 2>&1 && return 0
  local st
  st=$(aws ecs describe-services --cluster "$VIEWER_CLUSTER" --services "$VIEWER_SERVICE" \
    --query 'services[0].status' --output text --region "$REGION" 2>/dev/null || echo "")
  [ "$st" = "ACTIVE" ] && return 0
  return 1
}
if viewer_present; then
  if [ "${FORCE:-}" = "1" ]; then
    warn "Viewer detected, but FORCE=1 — proceeding. The viewer will start erroring."
  else
    error "The viewer is still deployed — it reads this backend (table '$TABLE', bucket '$BUCKET').
  Tearing the backend out now would break it. Run the viewer's ./teardown.sh first.
  (To override anyway: FORCE=1 ./teardown.sh)"
  fi
else
  success "No live viewer found — safe to remove the backend"
fi

# ── CONFIRM ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  demoworldfun SES backend — Teardown${NC}"
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Permanently deletes:"
echo -e "    • SES receipt rule set ($RULESET) and the catch-all rule"
echo -e "    • SES domain identity ($DOMAIN)"
echo -e "    • Lambda function ($LAMBDA_FN) and its IAM role ($ROLE)"
echo -e "    • DynamoDB table ($TABLE) — all indexed messages"
echo -e "    • S3 bucket ($BUCKET) — all stored raw emails"
echo ""
echo -e "  ${RED}${BOLD}All received email data will be gone. This cannot be undone.${NC}"
echo ""
read -rp "  Type 'delete' to confirm: " confirm
[ "$confirm" = "delete" ] || { echo "Aborted. Nothing deleted."; exit 0; }
echo ""

# ── SES RECEIPT RULE SET ──────────────────────────────────────────────────────
header "SES receipt rule set"
ACTIVE=$(aws ses describe-active-receipt-rule-set --query 'Metadata.Name' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ACTIVE" = "$RULESET" ] && aws ses set-active-receipt-rule-set --region "$REGION" >/dev/null 2>&1 || true
aws ses delete-receipt-rule-set --rule-set-name "$RULESET" --region "$REGION" >/dev/null 2>&1 \
  && success "Rule set deleted" || warn "Rule set not found — skipping"

# ── LAMBDA + ROLE ─────────────────────────────────────────────────────────────
header "Lambda + role"
aws lambda delete-function --function-name "$LAMBDA_FN" --region "$REGION" >/dev/null 2>&1 \
  && success "Lambda deleted" || warn "Lambda not found — skipping"
aws iam delete-role-policy --role-name "$ROLE" --policy-name "${LAMBDA_FN}-inline" >/dev/null 2>&1 || true
aws iam detach-role-policy --role-name "$ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 \
  && success "Lambda role deleted" || warn "Role not found — skipping"

# ── DYNAMODB ──────────────────────────────────────────────────────────────────
header "DynamoDB table"
aws dynamodb delete-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1 \
  && success "Table deletion started" || warn "Table not found — skipping"

# ── S3 ────────────────────────────────────────────────────────────────────────
header "S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  log "Emptying bucket..."
  aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
  aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null 2>&1 \
    && success "Bucket deleted" || warn "Bucket could not be deleted (check for versioned objects)"
else
  warn "Bucket not found — skipping"
fi

# ── SES IDENTITY ──────────────────────────────────────────────────────────────
header "SES domain identity"
aws ses delete-identity --identity "$DOMAIN" --region "$REGION" >/dev/null 2>&1 \
  && success "Identity deleted" || warn "Identity not found — skipping"

# ── STATE + DNS REMINDER ──────────────────────────────────────────────────────
rm -f "$STATE_FILE"; success "State file removed"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Backend teardown complete.${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Remove these DNS records by hand${NC} (AWS can't touch your DNS):"
echo -e "    • TXT  _amazonses.${DOMAIN}"
echo -e "    • MX   ${DOMAIN}  →  10 ${MX_ENDPOINT}"
echo ""
