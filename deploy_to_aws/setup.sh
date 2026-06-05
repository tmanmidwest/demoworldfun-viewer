#!/bin/bash
# =============================================================================
# setup.sh — Pre-deployment prerequisite checker for demoworldfun-viewer
# =============================================================================
# Run this first before deploy.sh to confirm everything is in place.
# Safe to run multiple times — it checks only, never creates anything.
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS="${GREEN}✔${NC}"
FAIL="${RED}✖${NC}"
WARN="${YELLOW}⚠${NC}"
ARROW="${BLUE}▶${NC}"

header() { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }
pass()   { echo -e "  ${PASS}  $1"; }
fail()   { echo -e "  ${FAIL}  ${RED}$1${NC}"; FAILED=$((FAILED+1)); }
warn()   { echo -e "  ${WARN}  ${YELLOW}$1${NC}"; }
info()   { echo -e "  ${ARROW}  $1"; }

FAILED=0

# Backend resource names — must match what you created for the SES pipeline.
# Override by exporting these before running, e.g. TABLE_NAME=my-table ./setup.sh
TABLE_NAME="${TABLE_NAME:-demoworldfun-messages}"
BUCKET_NAME="${BUCKET_NAME:-demoworldfun-inbound-mail}"

echo ""
echo -e "${BOLD}${BLUE}  demoworldfun-viewer — Setup Checker${NC}"
echo -e "  Checking everything you need before running deploy.sh"

# ── REQUIRED TOOLS ────────────────────────────────────────────────────────────
header "Required tools"

if command -v aws >/dev/null 2>&1; then
  pass "AWS CLI installed ($(aws --version 2>&1 | awk '{print $1}'))"
else
  fail "AWS CLI not found"; info "Install from: https://aws.amazon.com/cli/"
fi

if command -v docker >/dev/null 2>&1; then
  pass "Docker installed ($(docker --version | awk '{print $3}' | tr -d ','))"
  if docker info >/dev/null 2>&1; then
    pass "Docker is running"
  else
    fail "Docker is installed but not running — start Docker Desktop"
  fi
else
  fail "Docker not found"
  info "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
fi

if docker buildx version >/dev/null 2>&1; then
  pass "Docker Buildx available (required for Apple Silicon Macs)"
else
  warn "Docker Buildx not found — may cause issues on Apple Silicon Macs"
  info "Update Docker Desktop to get Buildx automatically"
fi

if command -v git >/dev/null 2>&1; then
  pass "Git installed ($(git --version | awk '{print $3}'))"
else
  fail "Git not found"; info "On Mac: run 'xcode-select --install'"
fi

if command -v python3 >/dev/null 2>&1; then
  pass "Python 3 installed ($(python3 --version | awk '{print $2}'))"
else
  fail "Python 3 not found"; info "Install from: https://www.python.org/downloads/"
fi

# ── AWS CREDENTIALS ───────────────────────────────────────────────────────────
header "AWS credentials"

CALLER=$(aws sts get-caller-identity --output json 2>/dev/null || echo "")
if [ -n "$CALLER" ]; then
  ACCOUNT=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])" 2>/dev/null || echo "unknown")
  IDENT=$(echo "$CALLER"  | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])" 2>/dev/null || echo "unknown")
  REGION=$(aws configure get region 2>/dev/null || echo "")
  pass "Logged in to AWS"
  info "Account: $ACCOUNT"
  info "Identity: $IDENT"
  if [ -n "$REGION" ]; then
    pass "Default region set: $REGION"
  else
    fail "No default region configured"
    info "Run: aws configure set region us-east-1  (use the region your SES backend is in)"
  fi
else
  fail "Not logged in to AWS"; info "Run 'aws configure' to set up your credentials"
fi

REGION="${REGION:-us-east-1}"

# ── AWS PERMISSIONS ───────────────────────────────────────────────────────────
header "AWS permissions"
info "Checking required service access in ${REGION}..."

aws ecs list-clusters --region "$REGION" >/dev/null 2>&1 \
  && pass "ECS access confirmed" || fail "No ECS access"
aws ecr describe-repositories --region "$REGION" >/dev/null 2>&1 \
  && pass "ECR access confirmed" || fail "No ECR access"
aws ec2 describe-vpcs --region "$REGION" >/dev/null 2>&1 \
  && pass "EC2/VPC access confirmed" || fail "No EC2 access"
aws elbv2 describe-load-balancers --region "$REGION" >/dev/null 2>&1 \
  && pass "Elastic Load Balancing access confirmed" || fail "No ELB access"
aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1 \
  && pass "IAM access confirmed (ecsTaskExecutionRole exists)" \
  || { aws iam list-roles >/dev/null 2>&1 \
        && warn "IAM access ok; ecsTaskExecutionRole not yet created (deploy.sh will create it)" \
        || fail "No IAM access — you need permission to create roles"; }

# ── BACKEND RESOURCES (the SES pipeline this viewer reads) ────────────────────
header "Backend resources (must already exist)"
info "The viewer reads from the DynamoDB table and S3 bucket your SES pipeline writes."

if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1; then
  pass "DynamoDB table found: $TABLE_NAME"
  if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" \
       --query "Table.GlobalSecondaryIndexes[?IndexName=='global-index'] | length(@)" \
       --output text 2>/dev/null | grep -q '^1$'; then
    pass "GSI 'global-index' present"
  else
    warn "GSI 'global-index' not found on the table — the inbox feed needs it"
  fi
else
  fail "DynamoDB table '$TABLE_NAME' not found in $REGION"
  info "Wrong region, or the SES backend isn't set up yet."
  info "Override the name: TABLE_NAME=your-table ./setup.sh"
fi

if aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1; then
  pass "S3 bucket found: $BUCKET_NAME"
else
  fail "S3 bucket '$BUCKET_NAME' not found or not accessible"
  info "Override the name: BUCKET_NAME=your-bucket ./setup.sh"
fi

# ── GITHUB CONNECTIVITY ───────────────────────────────────────────────────────
header "GitHub connectivity"
if curl -sf "https://github.com/tmanmidwest/demoworldfun-viewer" >/dev/null 2>&1; then
  pass "GitHub repo reachable (tmanmidwest/demoworldfun-viewer)"
else
  warn "Could not reach the GitHub repo — check the URL/visibility or your connection"
fi

# ── DEFAULT VPC ───────────────────────────────────────────────────────────────
header "AWS networking"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
  pass "Default VPC found: $VPC_ID"
  SUBNET_COUNT=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets | length(@)' --output text --region "$REGION" 2>/dev/null || echo "0")
  if [ "$SUBNET_COUNT" -ge 2 ]; then
    pass "Default VPC has $SUBNET_COUNT subnets (need at least 2)"
  else
    fail "Default VPC only has $SUBNET_COUNT subnet(s) — need 2 in different AZs"
  fi
else
  fail "No default VPC found"
  info "Create one: EC2 → Your VPCs → Actions → Create Default VPC"
fi

# ── SUMMARY ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
if [ "$FAILED" -eq 0 ]; then
  echo -e "${BOLD}${GREEN}  All checks passed — you are ready to deploy!${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Run ${BOLD}./deploy.sh${NC} to deploy the viewer to your AWS account."
else
  echo -e "${BOLD}${RED}  ${FAILED} check(s) failed — fix the issues above first.${NC}"
  echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════${NC}"
fi
echo ""
