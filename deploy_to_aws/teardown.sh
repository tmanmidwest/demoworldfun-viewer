#!/bin/bash
# =============================================================================
# teardown.sh — Delete all demoworldfun-viewer AWS resources
# =============================================================================
# Reads .demoworldfun-viewer-state (or rediscovers by name). No EFS to clean up
# (the viewer is stateless). Does NOT touch your SES/DynamoDB/S3 backend.
# =============================================================================

set -euo pipefail

APP_NAME="demoworldfun-viewer"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-viewer-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }
skip()    { echo -e "  ${YELLOW}↷  Skipping: $1${NC}"; }

header "Validating AWS session"
aws sts get-caller-identity >/dev/null 2>&1 \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
success "Logged in"

SERVICE="${APP_NAME}-web"
TG_NAME="${APP_NAME}-tg"
ALB_NAME="${APP_NAME}-alb"
ECR_REPO="${APP_NAME}"
TASK_ROLE_NAME="${APP_NAME}-task-role"

if [ -f "$STATE_FILE" ]; then
  # shellcheck source=/dev/null
  source "$STATE_FILE"
else
  warn "No state file — discovering resources by name..."
  REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
  LOG_GROUP="/ecs/${APP_NAME}"
  VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text --region "$REGION" 2>/dev/null || echo "")
  ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")
  ALB_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
  ECS_SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
fi

echo ""
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  demoworldfun-viewer — Complete Teardown${NC}"
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Permanently deletes the viewer's AWS resources:"
echo -e "    • ECS service and cluster"
echo -e "    • Application Load Balancer + target group + listeners"
echo -e "    • Security groups"
echo -e "    • CloudWatch log group"
echo -e "    • ECR repository and images"
echo -e "    • IAM task role (${TASK_ROLE_NAME})"
echo ""
echo -e "  ${GREEN}Your SES pipeline (DynamoDB table, S3 bucket) is NOT touched.${NC}"
echo ""
read -rp "  Type 'delete' to confirm: " confirm
[ "$confirm" = "delete" ] || { echo "Aborted. Nothing deleted."; exit 0; }
echo ""

# ── ECS SERVICE ───────────────────────────────────────────────────────────────
header "ECS service"
aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" --desired-count 0 --region "$REGION" >/dev/null 2>&1 || warn "Service not found"
aws ecs delete-service --cluster "$APP_NAME" --service "$SERVICE" --force --region "$REGION" >/dev/null 2>&1 || warn "Service not found — skipping"
log "Waiting for service to drain..."
attempt=0
while [ $attempt -lt 24 ]; do
  ACTIVE=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
    --query 'services[?status!=`INACTIVE`] | length(@)' --output text --region "$REGION" 2>/dev/null || echo "0")
  [ "$ACTIVE" = "0" ] || [ "$ACTIVE" = "None" ] || [ -z "$ACTIVE" ] && break
  echo -ne "  Active services: ${ACTIVE}\r"; sleep 5; attempt=$((attempt + 1))
done
echo ""; success "ECS service deleted"

# ── ECS CLUSTER ───────────────────────────────────────────────────────────────
header "ECS cluster"
aws ecs delete-cluster --cluster "$APP_NAME" --region "$REGION" >/dev/null 2>&1 || warn "Cluster not found"
success "ECS cluster deleted"

# ── TASK DEFINITIONS ──────────────────────────────────────────────────────────
header "Task definitions"
TASK_DEF_ARNS=$(aws ecs list-task-definitions --family-prefix "${APP_NAME}-web" \
  --query 'taskDefinitionArns[*]' --output text --region "$REGION" 2>/dev/null || echo "")
if [ -n "$TASK_DEF_ARNS" ]; then
  for arn in $TASK_DEF_ARNS; do
    aws ecs deregister-task-definition --task-definition "$arn" --region "$REGION" >/dev/null 2>&1 || true
  done
  success "Task definitions deregistered"
else
  skip "No task definitions found"
fi

# ── ECR ───────────────────────────────────────────────────────────────────────
header "ECR repository"
aws ecr delete-repository --repository-name "$ECR_REPO" --force --region "$REGION" >/dev/null 2>&1 \
  && success "ECR repository deleted" || warn "ECR repository not found — skipping"

# ── ALB ───────────────────────────────────────────────────────────────────────
header "Application Load Balancer"
if [ -n "${ALB_ARN:-}" ]; then
  for arn in $(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
        --query 'Listeners[*].ListenerArn' --output text --region "$REGION" 2>/dev/null || echo ""); do
    aws elbv2 delete-listener --listener-arn "$arn" --region "$REGION" >/dev/null 2>&1 || true
  done
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$REGION" >/dev/null 2>&1 || warn "ALB not found"
  log "Waiting for ALB to finish deleting..."
  attempt=0
  while [ $attempt -lt 20 ]; do
    STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
      --query 'LoadBalancers[0].State.Code' --output text --region "$REGION" 2>/dev/null || echo "deleted")
    [ "$STATE" = "deleted" ] || [ "$STATE" = "None" ] || [ -z "$STATE" ] && break
    echo -n "."; sleep 5; attempt=$((attempt + 1))
  done
  echo ""
fi
success "ALB deleted"
aws elbv2 delete-target-group --target-group-arn "${TG_ARN:-}" --region "$REGION" >/dev/null 2>&1 \
  && success "Target group deleted" || warn "Target group not found — skipping"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
header "Security groups"
sleep 10   # let ENIs detach after ALB removal
aws ec2 delete-security-group --group-id "${ECS_SG_ID:-}" --region "$REGION" >/dev/null 2>&1 \
  && success "ECS SG deleted" || warn "ECS SG not found — skipping"
aws ec2 delete-security-group --group-id "${ALB_SG_ID:-}" --region "$REGION" >/dev/null 2>&1 \
  && success "ALB SG deleted" || warn "ALB SG not found — skipping"

# ── IAM TASK ROLE ─────────────────────────────────────────────────────────────
header "IAM task role"
aws iam delete-role-policy --role-name "$TASK_ROLE_NAME" --policy-name "${APP_NAME}-readonly" >/dev/null 2>&1 || true
aws iam delete-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1 \
  && success "Task role deleted" || warn "Task role not found — skipping"
warn "Left ecsTaskExecutionRole in place (shared by other ECS apps)."

# ── CLOUDWATCH LOGS ───────────────────────────────────────────────────────────
header "CloudWatch log group"
aws logs delete-log-group --log-group-name "${LOG_GROUP:-/ecs/${APP_NAME}}" --region "$REGION" >/dev/null 2>&1 \
  && success "Log group deleted" || warn "Log group not found — skipping"

rm -f "$STATE_FILE"; success "State file removed"

echo ""
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Teardown complete. Viewer resources deleted.${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Your SES backend is untouched. Run ${BOLD}./deploy.sh${NC} to redeploy."
echo ""
