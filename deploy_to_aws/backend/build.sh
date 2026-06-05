#!/bin/bash
# =============================================================================
# build.sh — Provision the demoworldfun SES receiving backend
# =============================================================================
# Creates: S3 bucket (+ policy + lifecycle), DynamoDB table (+ GSI + TTL),
# Lambda indexer (+ role), SES domain identity, and the catch-all receipt rule.
#
# The ONE manual step is DNS: the script prints a TXT + MX record, pauses while
# you add them at your DNS provider, then verifies before finishing.
#
# Run this in a region that supports SES email receiving (see setup.sh).
# =============================================================================

set -euo pipefail

# ── Defaults (override at the prompts) ────────────────────────────────────────
DEFAULT_DOMAIN="demoworldfun.net"
DEFAULT_BUCKET="demoworldfun-inbound-mail"
DEFAULT_TABLE="demoworldfun-messages"
DEFAULT_PREFIX="inbox/"
DEFAULT_RETENTION="30"
# Fixed resource names (one backend per account; matches the viewer suite)
RULESET="demoworldfun-rules"
RULE="catch-all"
LAMBDA_FN="demoworldfun-index"
ROLE="demoworldfun-index-role"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-backend-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

# ── AWS SESSION ───────────────────────────────────────────────────────────────
header "Validating AWS session"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
success "Logged in (Account: $ACCOUNT_ID)"
REGION=$(aws configure get region 2>/dev/null || echo "")
[ -n "$REGION" ] || error "No default region. Run: aws configure set region us-east-1"
success "Region: $REGION"

command -v zip >/dev/null 2>&1 || error "zip not found (needed to package the Lambda)."

# ── CONFIG ────────────────────────────────────────────────────────────────────
header "Configuration"
read -rp "  Domain to receive mail for  [$DEFAULT_DOMAIN]: " DOMAIN;   DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
read -rp "  S3 bucket name              [$DEFAULT_BUCKET]: " BUCKET;   BUCKET="${BUCKET:-$DEFAULT_BUCKET}"
read -rp "  DynamoDB table name         [$DEFAULT_TABLE]: " TABLE;     TABLE="${TABLE:-$DEFAULT_TABLE}"
read -rp "  S3 key prefix               [$DEFAULT_PREFIX]: " PREFIX;   PREFIX="${PREFIX:-$DEFAULT_PREFIX}"
while :; do
  read -rp "  Retention (days, applies to messages + raw email) [$DEFAULT_RETENTION]: " RETENTION
  RETENTION="${RETENTION:-$DEFAULT_RETENTION}"
  [[ "$RETENTION" =~ ^[0-9]+$ ]] && [ "$RETENTION" -ge 1 ] && break
  warn "Enter a whole number of days, 1 or more."
done
echo ""
echo -e "  Domain:     ${BOLD}$DOMAIN${NC}"
echo -e "  Bucket:     ${BOLD}$BUCKET${NC}"
echo -e "  Table:      ${BOLD}$TABLE${NC}"
echo -e "  Prefix:     ${BOLD}$PREFIX${NC}"
echo -e "  Retention:  ${BOLD}$RETENTION days${NC}"
echo -e "  Region:     ${BOLD}$REGION${NC}"
read -rp "  Proceed? [Y/n] " ok; ok="${ok:-Y}"; [[ "$ok" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

MX_ENDPOINT="inbound-smtp.${REGION}.amazonaws.com"

# ── S3 BUCKET ─────────────────────────────────────────────────────────────────
header "S3 bucket"
if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  warn "Bucket already exists — reusing: $BUCKET"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" >/dev/null
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
  fi
  success "Created bucket: $BUCKET"
fi
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true >/dev/null
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/bucket-policy.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowSESPuts",
    "Effect": "Allow",
    "Principal": { "Service": "ses.amazonaws.com" },
    "Action": "s3:PutObject",
    "Resource": "arn:aws:s3:::${BUCKET}/*",
    "Condition": {
      "StringEquals": { "AWS:SourceAccount": "${ACCOUNT_ID}" },
      "StringLike": { "AWS:SourceArn": "arn:aws:ses:${REGION}:${ACCOUNT_ID}:receipt-rule-set/${RULESET}:receipt-rule/*" }
    }
  }] }
EOF
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "file://$TMP/bucket-policy.json"
cat > "$TMP/lifecycle.json" <<EOF
{ "Rules": [{ "ID": "expire-inbound-mail", "Filter": { "Prefix": "${PREFIX}" },
             "Status": "Enabled", "Expiration": { "Days": ${RETENTION} } }] }
EOF
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration "file://$TMP/lifecycle.json"
success "Bucket policy + ${RETENTION}-day lifecycle applied"

# ── DYNAMODB ──────────────────────────────────────────────────────────────────
header "DynamoDB table"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  warn "Table already exists — reusing: $TABLE"
else
  aws dynamodb create-table --table-name "$TABLE" --billing-mode PAY_PER_REQUEST \
    --attribute-definitions \
      AttributeName=recipient,AttributeType=S \
      AttributeName=receivedAt,AttributeType=S \
      AttributeName=inbox,AttributeType=S \
    --key-schema \
      AttributeName=recipient,KeyType=HASH \
      AttributeName=receivedAt,KeyType=RANGE \
    --global-secondary-indexes '[{
      "IndexName":"global-index",
      "KeySchema":[{"AttributeName":"inbox","KeyType":"HASH"},{"AttributeName":"receivedAt","KeyType":"RANGE"}],
      "Projection":{"ProjectionType":"ALL"}}]' \
    --region "$REGION" >/dev/null
  log "Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  success "Created table: $TABLE (with global-index)"
fi
aws dynamodb update-time-to-live --table-name "$TABLE" \
  --time-to-live-specification "Enabled=true, AttributeName=ttl" --region "$REGION" >/dev/null 2>&1 || true
success "TTL enabled on 'ttl' attribute"

# ── LAMBDA ROLE ───────────────────────────────────────────────────────────────
header "Lambda execution role"
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
fi
cat > "$TMP/lambda-inline.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["dynamodb:PutItem"],
      "Resource": "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE}" },
    { "Effect": "Allow", "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::${BUCKET}/*" }
  ] }
EOF
aws iam put-role-policy --role-name "$ROLE" --policy-name "${LAMBDA_FN}-inline" \
  --policy-document "file://$TMP/lambda-inline.json"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE}"
success "Role ready: $ROLE"

# ── LAMBDA FUNCTION ───────────────────────────────────────────────────────────
header "Lambda indexer"
cat > "$TMP/index_function.py" <<'PYEOF'
import os, time, boto3
from datetime import datetime, timezone

ddb = boto3.resource("dynamodb")
table = ddb.Table(os.environ["TABLE_NAME"])
S3_PREFIX = os.environ.get("S3_PREFIX", "inbox/")
TTL_DAYS = int(os.environ.get("TTL_DAYS", "30"))

def handler(event, context):
    for record in event.get("Records", []):
        ses = record["ses"]
        mail = ses["mail"]
        receipt = ses["receipt"]
        message_id = mail["messageId"]
        headers = mail.get("commonHeaders", {})
        sender = (headers.get("from") or ["unknown"])[0]
        subject = headers.get("subject") or "(no subject)"
        recipients = receipt.get("recipients") or mail.get("destination") or []
        received_at = datetime.now(timezone.utc).isoformat()
        ttl = int(time.time()) + TTL_DAYS * 86400
        s3_key = f"{S3_PREFIX}{message_id}"
        spam = receipt.get("spamVerdict", {}).get("status")
        virus = receipt.get("virusVerdict", {}).get("status")
        for rcpt in recipients:
            rcpt = rcpt.lower()
            table.put_item(Item={
                "recipient": rcpt,
                "receivedAt": f"{received_at}#{message_id}",
                "inbox": "ALL",
                "messageId": message_id,
                "sender": sender,
                "subject": subject,
                "s3Key": s3_key,
                "spamVerdict": spam,
                "virusVerdict": virus,
                "ttl": ttl,
            })
    return {"disposition": "CONTINUE"}
PYEOF
( cd "$TMP" && zip -q index_function.zip index_function.py )

if aws lambda get-function --function-name "$LAMBDA_FN" --region "$REGION" >/dev/null 2>&1; then
  log "Function exists — updating code + config..."
  aws lambda update-function-code --function-name "$LAMBDA_FN" \
    --zip-file "fileb://$TMP/index_function.zip" --region "$REGION" >/dev/null
  aws lambda wait function-updated --function-name "$LAMBDA_FN" --region "$REGION"
  aws lambda update-function-configuration --function-name "$LAMBDA_FN" \
    --environment "Variables={TABLE_NAME=$TABLE,S3_PREFIX=$PREFIX,TTL_DAYS=$RETENTION}" --region "$REGION" >/dev/null
else
  log "Creating function (retrying while the new role propagates)..."
  attempt=0
  until aws lambda create-function --function-name "$LAMBDA_FN" \
      --runtime python3.12 --handler index_function.handler \
      --zip-file "fileb://$TMP/index_function.zip" --role "$ROLE_ARN" \
      --timeout 30 --memory-size 128 \
      --environment "Variables={TABLE_NAME=$TABLE,S3_PREFIX=$PREFIX,TTL_DAYS=$RETENTION}" \
      --region "$REGION" >/dev/null 2>&1; do
    attempt=$((attempt+1)); [ $attempt -ge 10 ] && error "Lambda create failed after retries (role propagation?)."
    sleep 5
  done
fi
success "Lambda ready: $LAMBDA_FN (TTL_DAYS=$RETENTION)"

# Allow SES to invoke it (idempotent)
aws lambda remove-permission --function-name "$LAMBDA_FN" --statement-id ses-invoke --region "$REGION" >/dev/null 2>&1 || true
aws lambda add-permission --function-name "$LAMBDA_FN" --statement-id ses-invoke \
  --action lambda:InvokeFunction --principal ses.amazonaws.com \
  --source-account "$ACCOUNT_ID" \
  --source-arn "arn:aws:ses:${REGION}:${ACCOUNT_ID}:receipt-rule-set/${RULESET}:receipt-rule/${RULE}" \
  --region "$REGION" >/dev/null
success "SES granted permission to invoke the Lambda"

# ── DOMAIN VERIFICATION + DNS (the manual step) ───────────────────────────────
header "Domain verification (DNS)"
VTOKEN=$(aws ses verify-domain-identity --domain "$DOMAIN" \
  --query 'VerificationToken' --output text --region "$REGION")
echo ""
echo -e "  ${BOLD}Add these two records at your DNS provider for ${DOMAIN}:${NC}"
echo ""
echo -e "  ${BOLD}1) TXT${NC}  (domain verification)"
echo -e "       Name:  _amazonses.${DOMAIN}"
echo -e "       Value: ${VTOKEN}"
echo ""
echo -e "  ${BOLD}2) MX${NC}   (route mail to SES)"
echo -e "       Name:  ${DOMAIN}"
echo -e "       Value: 10 ${MX_ENDPOINT}"
echo ""
read -rp "  Press Enter once you've added both records... " _

# Verify domain (poll, with re-prompt)
log "Checking domain verification..."
verify_status() {
  aws ses get-identity-verification-attributes --identities "$DOMAIN" \
    --query "VerificationAttributes.\"$DOMAIN\".VerificationStatus" --output text --region "$REGION" 2>/dev/null || echo "Pending"
}
while :; do
  attempt=0
  while [ $attempt -lt 20 ]; do
    [ "$(verify_status)" = "Success" ] && break 2
    echo -ne "  Waiting for verification (DNS can take a few minutes)... \r"
    sleep 15; attempt=$((attempt+1))
  done
  echo ""
  read -rp "  Still pending. [r]echeck, [c]ontinue anyway, or [a]bort? " choice
  case "$choice" in
    c|C) warn "Continuing without confirmed verification — mail won't be accepted until it verifies."; break ;;
    a|A) error "Aborted. Resources created so far remain; re-run build.sh to resume, or teardown.sh to remove." ;;
    *)   ;;
  esac
done
[ "$(verify_status)" = "Success" ] && success "Domain verified: $DOMAIN"

# Best-effort MX check
if command -v dig >/dev/null 2>&1; then
  log "Checking MX record..."
  attempt=0
  while [ $attempt -lt 12 ]; do
    dig +short MX "$DOMAIN" 2>/dev/null | grep -qi "$MX_ENDPOINT" && { success "MX resolves to SES"; break; }
    echo -ne "  Waiting for MX to propagate...\r"; sleep 15; attempt=$((attempt+1))
  done
  echo ""
  [ $attempt -ge 12 ] && warn "MX not visible yet — it may still be propagating. Mail will flow once it does."
fi

# ── RECEIPT RULE ──────────────────────────────────────────────────────────────
header "SES receipt rule (catch-all)"
aws ses create-receipt-rule-set --rule-set-name "$RULESET" --region "$REGION" >/dev/null 2>&1 \
  || warn "Rule set exists — reusing"
aws ses set-active-receipt-rule-set --rule-set-name "$RULESET" --region "$REGION" >/dev/null
cat > "$TMP/receipt-rule.json" <<EOF
{ "Name": "${RULE}", "Enabled": true, "ScanEnabled": true, "TlsPolicy": "Optional",
  "Recipients": ["${DOMAIN}"],
  "Actions": [
    { "S3Action": { "BucketName": "${BUCKET}", "ObjectKeyPrefix": "${PREFIX}" } },
    { "LambdaAction": { "FunctionArn": "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${LAMBDA_FN}", "InvocationType": "Event" } }
  ] }
EOF
aws ses create-receipt-rule --rule-set-name "$RULESET" --rule "file://$TMP/receipt-rule.json" --region "$REGION" >/dev/null 2>&1 \
  || { aws ses delete-receipt-rule --rule-set-name "$RULESET" --rule-name "$RULE" --region "$REGION" >/dev/null 2>&1 || true;
       aws ses create-receipt-rule --rule-set-name "$RULESET" --rule "file://$TMP/receipt-rule.json" --region "$REGION" >/dev/null; }
success "Catch-all rule active: any address @${DOMAIN} → S3 + Lambda"

# ── STATE FILE ────────────────────────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
# demoworldfun SES backend state — written by build.sh
APP=demoworldfun-backend
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
DOMAIN=$DOMAIN
BUCKET=$BUCKET
TABLE=$TABLE
PREFIX=$PREFIX
RETENTION=$RETENTION
RULESET=$RULESET
RULE=$RULE
LAMBDA_FN=$LAMBDA_FN
ROLE=$ROLE
MX_ENDPOINT=$MX_ENDPOINT
EOF
success "State written to $STATE_FILE"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Backend built!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Send a test email to ${BOLD}anything@${DOMAIN}${NC}, then check:"
echo -e "    aws s3 ls s3://${BUCKET}/${PREFIX}"
echo -e "  The viewer (deployed separately) reads table '${TABLE}' + bucket '${BUCKET}'."
echo ""
