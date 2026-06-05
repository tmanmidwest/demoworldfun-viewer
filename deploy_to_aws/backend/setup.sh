#!/bin/bash
# =============================================================================
# setup.sh — Prerequisite checker for the demoworldfun SES backend
# =============================================================================
# Run before build.sh. Checks only — creates nothing.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
PASS="${GREEN}✔${NC}"; FAIL="${RED}✖${NC}"; WARN="${YELLOW}⚠${NC}"; ARROW="${BLUE}▶${NC}"
header() { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }
pass()   { echo -e "  ${PASS}  $1"; }
fail()   { echo -e "  ${FAIL}  ${RED}$1${NC}"; FAILED=$((FAILED+1)); }
warn()   { echo -e "  ${WARN}  ${YELLOW}$1${NC}"; }
info()   { echo -e "  ${ARROW}  $1"; }
FAILED=0

# SES email receiving is only available in certain regions.
SES_RX_REGIONS="us-east-1 us-east-2 us-west-2 eu-west-1 eu-west-2 eu-central-1 ca-central-1 ap-southeast-1 ap-southeast-2 ap-northeast-1"

echo ""
echo -e "${BOLD}${BLUE}  demoworldfun SES backend — Setup Checker${NC}"

# ── TOOLS ─────────────────────────────────────────────────────────────────────
header "Required tools"
command -v aws    >/dev/null 2>&1 && pass "AWS CLI installed ($(aws --version 2>&1 | awk '{print $1}'))" || { fail "AWS CLI not found"; info "https://aws.amazon.com/cli/"; }
command -v python3>/dev/null 2>&1 && pass "Python 3 installed ($(python3 --version | awk '{print $2}'))" || fail "Python 3 not found"
command -v zip    >/dev/null 2>&1 && pass "zip installed" || { fail "zip not found"; info "Needed to package the Lambda"; }
if command -v dig >/dev/null 2>&1 || command -v host >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1; then
  pass "DNS lookup tool available (dig/host/nslookup)"
else
  warn "No dig/host/nslookup — build can't auto-verify the MX record (you can skip the check)"
fi

# ── AWS CREDS ─────────────────────────────────────────────────────────────────
header "AWS credentials"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null || echo "")
if [ -n "$CALLER" ]; then
  ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null || echo "?")
  REGION=$(aws configure get region 2>/dev/null || echo "")
  pass "Logged in to AWS (Account: $ACCOUNT)"
  if [ -n "$REGION" ]; then
    pass "Default region set: $REGION"
    if echo " $SES_RX_REGIONS " | grep -q " $REGION "; then
      pass "Region supports SES email receiving"
    else
      fail "Region '$REGION' does NOT support SES email receiving"
      info "Use one of: $SES_RX_REGIONS"
    fi
  else
    fail "No default region configured"
    info "Run: aws configure set region us-east-1"
  fi
else
  fail "Not logged in to AWS"; info "Run 'aws configure'"
fi
REGION="${REGION:-us-east-1}"

# ── PERMISSIONS ───────────────────────────────────────────────────────────────
header "AWS permissions"
aws ses describe-active-receipt-rule-set --region "$REGION" >/dev/null 2>&1 && pass "SES access confirmed" || fail "No SES access"
aws s3api list-buckets >/dev/null 2>&1 && pass "S3 access confirmed" || fail "No S3 access"
aws dynamodb list-tables --region "$REGION" >/dev/null 2>&1 && pass "DynamoDB access confirmed" || fail "No DynamoDB access"
aws lambda list-functions --region "$REGION" >/dev/null 2>&1 && pass "Lambda access confirmed" || fail "No Lambda access"
aws iam list-roles >/dev/null 2>&1 && pass "IAM access confirmed" || fail "No IAM access (needed to create the Lambda role)"

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
if [ "$FAILED" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}  All checks passed — ready to build.${NC}"
  echo ""
  echo -e "  Make sure you control DNS for your domain, then run ${BOLD}./build.sh${NC}."
  echo -e "  (You'll be asked to add a TXT + MX record partway through.)"
else
  echo -e "${BOLD}${RED}  ${FAILED} check(s) failed — fix the issues above first.${NC}"
fi
echo ""
