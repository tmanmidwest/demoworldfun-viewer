#!/bin/bash
# =============================================================================
# deploy.sh — Deploy demoworldfun-viewer to AWS ECS Fargate (from scratch)
# =============================================================================
# Builds the image from GitHub, pushes to your own ECR, and stands up a public
# ALB + Fargate service. Stateless app — no EFS. Creates a scoped task role so
# the running container can read DynamoDB + S3 (read-only).
#
# Deploy in the SAME region as your SES/DynamoDB/S3 backend.
# =============================================================================

set -euo pipefail

# ── Constants you can change ──────────────────────────────────────────────────
APP_NAME="demoworldfun-viewer"
GITHUB_REPO="https://github.com/tmanmidwest/demoworldfun-viewer.git"
DEFAULT_DOMAIN="demoworldfun.net"
DEFAULT_PREFIX="inbox/"

# Derive a clean resource slug from a domain: first label, lowercased, sanitized.
# Must match the backend's build.sh so the names line up.
slugify() { echo "$1" | cut -d. -f1 | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'; }

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-viewer-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

# Idempotently ensure a CloudWatch log group exists. Fails loudly if it can't
# be created — a missing log group makes ECS tasks fail to start (the awslogs
# driver does NOT auto-create the group), which is hard to diagnose otherwise.
ensure_log_group() {
  local group="$1"

  if aws logs describe-log-groups \
      --log-group-name-prefix "$group" \
      --region "$REGION" \
      --query "logGroups[?logGroupName=='${group}'] | [0].logGroupName" \
      --output text 2>/dev/null | grep -qx "$group"; then
    return 0
  fi

  local create_err
  if ! create_err=$(aws logs create-log-group \
      --log-group-name "$group" \
      --region "$REGION" 2>&1); then
    if echo "$create_err" | grep -q "ResourceAlreadyExistsException"; then
      return 0
    fi
    error "Could not create CloudWatch log group '$group': $create_err"
  fi

  aws logs describe-log-groups \
    --log-group-name-prefix "$group" \
    --region "$REGION" \
    --query "logGroups[?logGroupName=='${group}'] | [0].logGroupName" \
    --output text 2>/dev/null | grep -qx "$group" \
    || error "Log group '$group' still does not exist after creation attempt."
}

SERVICE="${APP_NAME}-web"
FAMILY="${APP_NAME}-web"
CONTAINER="${APP_NAME}-web"
ECR_REPO="${APP_NAME}"
TG_NAME="${APP_NAME}-tg"
ALB_NAME="${APP_NAME}-alb"
TASK_ROLE_NAME="${APP_NAME}-task-role"
LOG_GROUP="/ecs/${APP_NAME}"

# ── AWS SESSION ───────────────────────────────────────────────────────────────
header "Validating AWS session"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session and try again."
ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $ACCOUNT_ID)"

REGION=$(aws configure get region 2>/dev/null || echo "")
[ -n "$REGION" ] || error "No default region configured. Run: aws configure set region us-east-1"
success "Region: $REGION"

# ── PRE-FLIGHT ────────────────────────────────────────────────────────────────
header "Pre-flight checks"
command -v docker >/dev/null 2>&1 || error "Docker not found."
docker info >/dev/null 2>&1       || error "Docker is not running. Start Docker Desktop."
command -v git    >/dev/null 2>&1 || error "Git not found."
success "Docker and Git ready"

# ── CONFIG PROMPTS ────────────────────────────────────────────────────────────
header "Configuration"
read -rp "  Domain          [$DEFAULT_DOMAIN]: " DOMAIN; DOMAIN="${DOMAIN:-$DEFAULT_DOMAIN}"
SLUG=$(slugify "$DOMAIN"); [ -n "$SLUG" ] || error "Couldn't derive a name from '$DOMAIN'."
DEF_TABLE="${SLUG}-messages"
DEF_BUCKET="${SLUG}-inbound-mail"
echo -e "  ${ARROW}  Suggesting names from '${DOMAIN}' — these must match your backend (override if needed)"
read -rp "  DynamoDB table  [$DEF_TABLE]: " TABLE_NAME;  TABLE_NAME="${TABLE_NAME:-$DEF_TABLE}"
read -rp "  S3 bucket       [$DEF_BUCKET]: " BUCKET_NAME; BUCKET_NAME="${BUCKET_NAME:-$DEF_BUCKET}"
read -rp "  S3 prefix       [$DEFAULT_PREFIX]: " S3_PREFIX;   S3_PREFIX="${S3_PREFIX:-$DEFAULT_PREFIX}"
read -rp "  App title       [$DOMAIN]: " APP_TITLE;    APP_TITLE="${APP_TITLE:-$DOMAIN}"

# Verify the backend exists before doing anything expensive
log "Verifying backend resources exist in $REGION..."
aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" >/dev/null 2>&1 \
  || error "DynamoDB table '$TABLE_NAME' not found in $REGION. Wrong region, or backend not set up."
aws s3api head-bucket --bucket "$BUCKET_NAME" >/dev/null 2>&1 \
  || error "S3 bucket '$BUCKET_NAME' not found or not accessible."
success "Backend verified: table + bucket reachable"

# ── AUTH ──────────────────────────────────────────────────────────────────────
header "Login (OIDC / Authentik SSO)"
OIDC_DISCOVERY_URL=""; OIDC_CLIENT_ID=""; OIDC_CLIENT_SECRET=""
OIDC_REDIRECT_URI=""; OIDC_ALLOWED_GROUPS=""; SESSION_SECRET=""; AUTH_DISABLED=""
echo -e "  This deploys a ${BOLD}public URL${NC}. SSO login is strongly recommended."
read -rp "  Set up SSO login? [Y/n] " want_auth; want_auth="${want_auth:-Y}"
if [[ "$want_auth" =~ ^[Yy]$ ]]; then
  echo -e "  Create an OAuth2/OpenID provider + application in Authentik first."
  read -rp "  OIDC discovery URL (…/.well-known/openid-configuration): " OIDC_DISCOVERY_URL
  read -rp "  OIDC client ID: " OIDC_CLIENT_ID
  read -rsp "  OIDC client secret: " OIDC_CLIENT_SECRET; echo
  read -rp "  Allowed groups (comma-separated, blank = any user): " OIDC_ALLOWED_GROUPS
  read -rp "  App callback base URL (e.g. http://your-alb-dns or https://host): " base_url
  base_url="${base_url%/}"
  [ -n "$base_url" ] && OIDC_REDIRECT_URI="${base_url}/auth/callback"
  SESSION_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  [ -n "$OIDC_DISCOVERY_URL" ] && [ -n "$OIDC_CLIENT_ID" ] && [ -n "$OIDC_CLIENT_SECRET" ] \
    || error "OIDC discovery URL, client ID, and client secret are all required."
  [ -n "$OIDC_REDIRECT_URI" ] \
    || error "Callback base URL is required so the redirect URI matches Authentik."
  success "SSO configured (redirect URI: $OIDC_REDIRECT_URI)"
else
  AUTH_DISABLED="true"
  warn "No login — the viewer will be open to anyone with the URL. Dummy data only!"
fi
# ALB listener is HTTP:80 in this script. OAuth really wants HTTPS: if your
# callback base URL is https://, set this to true (and add an HTTPS listener).
case "$OIDC_REDIRECT_URI" in
  https://*) SECURE_COOKIES="true" ;;
  *)         SECURE_COOKIES="false" ;;
esac

# ── NETWORKING ────────────────────────────────────────────────────────────────
header "Networking (default VPC)"
VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")
[ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ] || error "No default VPC in $REGION."
read -r SUBNET_1 SUBNET_2 _ < <(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[*].SubnetId' --output text --region "$REGION")
[ -n "$SUBNET_1" ] && [ -n "$SUBNET_2" ] || error "Need at least 2 subnets in the default VPC."
success "VPC $VPC_ID (subnets: $SUBNET_1, $SUBNET_2)"

# ── SECURITY GROUPS ───────────────────────────────────────────────────────────
header "Security groups"
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "None")
if [ "$ALB_SG_ID" = "None" ] || [ -z "$ALB_SG_ID" ]; then
  ALB_SG_ID=$(aws ec2 create-security-group --group-name "${APP_NAME}-alb-sg" \
    --description "ALB SG for $APP_NAME" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
success "ALB SG: $ALB_SG_ID"

ECS_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-ecs-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "None")
if [ "$ECS_SG_ID" = "None" ] || [ -z "$ECS_SG_ID" ]; then
  ECS_SG_ID=$(aws ec2 create-security-group --group-name "${APP_NAME}-ecs-sg" \
    --description "ECS SG for $APP_NAME" --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$ECS_SG_ID" \
    --protocol tcp --port 8000 --source-group "$ALB_SG_ID" --region "$REGION" >/dev/null
fi
success "ECS SG: $ECS_SG_ID"

# ── ECR + IMAGE ───────────────────────────────────────────────────────────────
header "Container image"
aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" >/dev/null
IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"
success "ECR repo: $IMAGE"

log "Logging Docker into ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
success "Docker logged into ECR"

log "Cloning source and building (linux/amd64 for Fargate)..."
BUILD_DIR=$(mktemp -d); trap 'rm -rf "$BUILD_DIR"' EXIT
git clone "$GITHUB_REPO" "$BUILD_DIR" --depth 1 --quiet
docker buildx build --platform linux/amd64 --push -t "$IMAGE" "$BUILD_DIR"
success "Image built and pushed"

# ── IAM ROLES ─────────────────────────────────────────────────────────────────
header "IAM roles"

# Execution role (pull image, write logs) — shared AWS-managed policy
if ! aws iam get-role --role-name ecsTaskExecutionRole >/dev/null 2>&1; then
  log "Creating ecsTaskExecutionRole..."
  aws iam create-role --role-name ecsTaskExecutionRole \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name ecsTaskExecutionRole \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy >/dev/null
fi
EXEC_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/ecsTaskExecutionRole"
success "Execution role: ecsTaskExecutionRole"

# Task role (what the RUNNING container uses) — scoped read-only to this data
log "Creating/updating task role with DynamoDB + S3 access (read + delete)..."
aws iam get-role --role-name "$TASK_ROLE_NAME" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$TASK_ROLE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null

cat > "${BUILD_DIR}/task-policy.json" <<EOF
{ "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["dynamodb:Query", "dynamodb:DeleteItem"],
      "Resource": [
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}",
        "arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}/index/global-index"
      ] },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::${BUCKET_NAME}/*" }
  ] }
EOF
aws iam put-role-policy --role-name "$TASK_ROLE_NAME" \
  --policy-name "${APP_NAME}-readonly" \
  --policy-document "file://${BUILD_DIR}/task-policy.json"
TASK_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TASK_ROLE_NAME}"
success "Task role: $TASK_ROLE_NAME"

# ── LOG GROUP ─────────────────────────────────────────────────────────────────
header "CloudWatch log group"
ensure_log_group "$LOG_GROUP"
success "Log group: $LOG_GROUP"

# ── LOAD BALANCER ─────────────────────────────────────────────────────────────
header "Application Load Balancer"
TG_ARN=$(aws elbv2 create-target-group --name "$TG_NAME" \
  --protocol HTTP --port 8000 --vpc-id "$VPC_ID" --target-type ip \
  --health-check-path /healthz --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null \
  || aws elbv2 describe-target-groups --names "$TG_NAME" \
       --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION")
success "Target group: $TG_ARN"

ALB_ARN=$(aws elbv2 create-load-balancer --name "$ALB_NAME" \
  --subnets "$SUBNET_1" "$SUBNET_2" --security-groups "$ALB_SG_ID" \
  --scheme internet-facing --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null \
  || aws elbv2 describe-load-balancers --names "$ALB_NAME" \
       --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION")
log "Waiting for ALB to become available..."
aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" --region "$REGION"
ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
success "ALB: $ALB_DNS"

aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --region "$REGION" >/dev/null 2>&1 || true
success "HTTP:80 listener forwarding to the app"

# ── ECS CLUSTER + TASK DEF + SERVICE ──────────────────────────────────────────
header "ECS cluster, task, service"
aws ecs create-cluster --cluster-name "$APP_NAME" --region "$REGION" >/dev/null 2>&1 || true

log "Registering task definition (with task role + env)..."
export FAMILY EXEC_ROLE_ARN TASK_ROLE_ARN CONTAINER IMAGE LOG_GROUP REGION \
       AWS_DEFAULT_REGION="$REGION" TABLE_NAME BUCKET_NAME S3_PREFIX APP_TITLE \
       OIDC_DISCOVERY_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_REDIRECT_URI \
       OIDC_ALLOWED_GROUPS SESSION_SECRET AUTH_DISABLED SECURE_COOKIES
python3 - > "${BUILD_DIR}/taskdef.json" <<'PY'
import json, os
keys = ["AWS_DEFAULT_REGION","TABLE_NAME","BUCKET_NAME","S3_PREFIX","APP_TITLE",
        "OIDC_DISCOVERY_URL","OIDC_CLIENT_ID","OIDC_CLIENT_SECRET","OIDC_REDIRECT_URI",
        "OIDC_ALLOWED_GROUPS","SESSION_SECRET","AUTH_DISABLED","SECURE_COOKIES"]
td = {
  "family": os.environ["FAMILY"],
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256", "memory": "512",
  "executionRoleArn": os.environ["EXEC_ROLE_ARN"],
  "taskRoleArn": os.environ["TASK_ROLE_ARN"],
  "containerDefinitions": [{
    "name": os.environ["CONTAINER"],
    "image": os.environ["IMAGE"],
    "essential": True,
    "portMappings": [{"containerPort": 8000, "protocol": "tcp"}],
    "environment": [{"name": k, "value": os.environ[k]} for k in keys if os.environ.get(k, "") != ""],
    "healthCheck": {
      "command": ["CMD-SHELL",
        "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:8000/healthz').status==200 else 1)\""],
      "interval": 30, "timeout": 5, "retries": 3, "startPeriod": 15
    },
    "logConfiguration": {"logDriver": "awslogs", "options": {
      "awslogs-group": os.environ["LOG_GROUP"],
      "awslogs-region": os.environ["REGION"],
      "awslogs-stream-prefix": "ecs"
    }}
  }]
}
print(json.dumps(td))
PY
aws ecs register-task-definition --cli-input-json "file://${BUILD_DIR}/taskdef.json" \
  --region "$REGION" >/dev/null
success "Task definition registered: $FAMILY"

if aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
     --query 'services[0].status' --output text --region "$REGION" 2>/dev/null | grep -q ACTIVE; then
  log "Service exists — updating..."
  aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" \
    --task-definition "$FAMILY" --force-new-deployment --region "$REGION" >/dev/null
else
  log "Creating service..."
  aws ecs create-service --cluster "$APP_NAME" --service-name "$SERVICE" \
    --task-definition "$FAMILY" --desired-count 1 --launch-type FARGATE \
    --health-check-grace-period-seconds 60 \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_1,$SUBNET_2],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=$CONTAINER,containerPort=8000" \
    --region "$REGION" >/dev/null
fi
success "Service deploying"

# ── STATE FILE (resource IDs + non-secret config only) ────────────────────────
cat > "$STATE_FILE" <<EOF
# demoworldfun-viewer deployment state — written by deploy.sh
# Resource IDs and non-secret config. No passwords/secrets live here.
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
CONTAINER_IMAGE=$IMAGE
TABLE_NAME=$TABLE_NAME
BUCKET_NAME=$BUCKET_NAME
S3_PREFIX=$S3_PREFIX
APP_TITLE=$APP_TITLE
EOF
success "State written to $STATE_FILE"

# ── WAIT FOR HEALTHY ──────────────────────────────────────────────────────────
header "Waiting for the app to become healthy (3-5 min)"
echo ""
attempt=0
while [ $attempt -lt 40 ]; do
  RUNNING=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text --region "$REGION" 2>/dev/null || echo "0")
  HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region "$REGION" 2>/dev/null || echo "unknown")
  echo -ne "  Running tasks: ${RUNNING} | ALB target health: ${HEALTH}\r"
  [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ] && { echo ""; break; }
  sleep 10; attempt=$((attempt + 1))
done
echo ""

echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Deployment complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"
[ -z "$AUTH_DISABLED" ] && echo -e "  ${BOLD}Login:${NC}  SSO via ${OIDC_DISCOVERY_URL}"
echo ""
echo -e "  Manage it with ${BOLD}./manage.sh status${NC}, update with ${BOLD}./update.sh${NC}."
echo ""
