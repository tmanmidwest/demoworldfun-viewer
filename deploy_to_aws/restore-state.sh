#!/bin/bash
# =============================================================================
# restore-state.sh — Rebuild .demoworldfun-viewer-state from live AWS resources
# =============================================================================
# Read-only discovery (creates nothing) so manage.sh / update.sh / teardown.sh
# work from a second machine. Auth/config are NOT needed here — they live in the
# running task definition, not this file.
#
#   ./restore-state.sh            # uses your default region
#   ./restore-state.sh us-east-1  # or pass the region you deployed to
# =============================================================================

set -euo pipefail

APP_NAME="demoworldfun-viewer"
SERVICE="${APP_NAME}-web"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-viewer-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

header "Validating AWS session"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
success "Logged in (Account: $ACCOUNT_ID)"

REGION="${1:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "$REGION" ] || REGION=$(aws configure get region 2>/dev/null || echo "")
[ -n "$REGION" ] || error "No region given/configured. e.g. ./restore-state.sh us-east-1"
aws ec2 describe-regions --region-names "$REGION" >/dev/null 2>&1 || error "Invalid region: $REGION"
success "Region: $REGION"

if [ -f "$STATE_FILE" ]; then
  warn "A state file already exists."
  read -rp "  Overwrite with freshly discovered values? [y/N] " c
  [[ "$c" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

header "Discovering resources for '${APP_NAME}' in ${REGION}"

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$VPC_ID" = "None" ] && VPC_ID=""
SUBNET_1=""; SUBNET_2=""
if [ -n "$VPC_ID" ]; then
  read -r SUBNET_1 SUBNET_2 _ < <(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
    --query 'Subnets[*].SubnetId' --output text --region "$REGION" 2>/dev/null || echo "")
fi
[ -n "$VPC_ID" ] && success "VPC: $VPC_ID (subnets: ${SUBNET_1:-?}, ${SUBNET_2:-?})" || warn "Default VPC not found"

ALB_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_SG_ID" = "None" ] && ALB_SG_ID=""
ECS_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ECS_SG_ID" = "None" ] && ECS_SG_ID=""
[ -n "$ALB_SG_ID" ] && success "ALB SG: $ALB_SG_ID" || warn "ALB SG not found"
[ -n "$ECS_SG_ID" ] && success "ECS SG: $ECS_SG_ID" || warn "ECS SG not found"

ALB_ARN=$(aws elbv2 describe-load-balancers --names "${APP_NAME}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_ARN" = "None" ] && ALB_ARN=""
ALB_DNS=""
if [ -n "$ALB_ARN" ]; then
  ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" --query 'LoadBalancers[0].DNSName' --output text --region "$REGION" 2>/dev/null || echo "")
  [ "$ALB_DNS" = "None" ] && ALB_DNS=""
fi
[ -n "$ALB_ARN" ] && success "ALB: ${ALB_DNS:-$ALB_ARN}" || warn "ALB not found"

TG_ARN=$(aws elbv2 describe-target-groups --names "${APP_NAME}-tg" --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$TG_ARN" = "None" ] && TG_ARN=""
[ -n "$TG_ARN" ] && success "Target group: $TG_ARN" || warn "Target group not found"

LOG_GROUP="/ecs/${APP_NAME}"
TASK_ROLE_NAME="${APP_NAME}-task-role"
CONTAINER_IMAGE=""
aws ecr describe-repositories --repository-names "$APP_NAME" --region "$REGION" >/dev/null 2>&1 \
  && CONTAINER_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}:latest"

# Pull non-secret config back out of the running task definition (if present)
TABLE_NAME=""; BUCKET_NAME=""; S3_PREFIX=""; APP_TITLE=""
TD=$(aws ecs describe-task-definition --task-definition "${APP_NAME}-web" \
  --query 'taskDefinition.containerDefinitions[0].environment' --output json --region "$REGION" 2>/dev/null || echo "[]")
if [ "$TD" != "[]" ]; then
  getenv() { echo "$TD" | python3 -c "import sys,json; d={e['name']:e['value'] for e in json.load(sys.stdin)}; print(d.get('$1',''))"; }
  TABLE_NAME=$(getenv TABLE_NAME); BUCKET_NAME=$(getenv BUCKET_NAME)
  S3_PREFIX=$(getenv S3_PREFIX);   APP_TITLE=$(getenv APP_TITLE)
fi

if [ -z "$ALB_ARN" ] || [ -z "$TG_ARN" ]; then
  echo ""
  error "Couldn't find the ALB / target group in '$REGION'. Either it isn't deployed,
  or it's in another region. Re-run with the deploy region, e.g. ./restore-state.sh us-east-1"
fi

header "Writing $STATE_FILE"
cat > "$STATE_FILE" <<EOF
# demoworldfun-viewer state — regenerated by restore-state.sh (read-only discovery)
APP_NAME=$APP_NAME
SERVICE=$SERVICE
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
VPC_ID=$VPC_ID
SUBNET_1=$SUBNET_1
SUBNET_2=$SUBNET_2
ALB_SG_ID=$ALB_SG_ID
ECS_SG_ID=$ECS_SG_ID
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
TG_ARN=$TG_ARN
LOG_GROUP=$LOG_GROUP
TASK_ROLE_NAME=$TASK_ROLE_NAME
CONTAINER_IMAGE=$CONTAINER_IMAGE
TABLE_NAME=$TABLE_NAME
BUCKET_NAME=$BUCKET_NAME
S3_PREFIX=$S3_PREFIX
APP_TITLE=$APP_TITLE
EOF
success "State file written"

echo ""
echo -e "${BOLD}${GREEN}  State restored.${NC}  App URL: http://${ALB_DNS}/"
echo -e "  You can now run ${BOLD}./manage.sh status${NC} from this machine."
echo ""
