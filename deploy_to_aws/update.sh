#!/bin/bash
# =============================================================================
# update.sh — Rebuild demoworldfun-viewer from GitHub and redeploy
# =============================================================================
# Pulls latest source, builds linux/amd64, pushes :latest to ECR, forces a new
# ECS deployment. Auth/config persist (they live in the task definition's env).
# =============================================================================

set -euo pipefail

GITHUB_REPO="https://github.com/tmanmidwest/demoworldfun-viewer.git"

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
SESSION_USER=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'].split('/')[-1])")
success "Logged in as: $SESSION_USER (Account: $ACCOUNT_ID)"

[ -f "$STATE_FILE" ] || error "No state file ($STATE_FILE). Deploy first or run ./restore-state.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"

header "Pre-flight"
command -v docker >/dev/null 2>&1 || error "Docker not found."
docker info >/dev/null 2>&1       || error "Docker is not running."
command -v git    >/dev/null 2>&1 || error "Git not found."
SVC_STATUS=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
  --query 'services[0].status' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$SVC_STATUS" = "ACTIVE" ] || error "Service not active. Deploy first with ./deploy.sh"
success "Service active"

ECR_IMAGE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}:latest"

header "Pulling latest code"
BUILD_DIR=$(mktemp -d); trap 'rm -rf "$BUILD_DIR"' EXIT
git clone "$GITHUB_REPO" "$BUILD_DIR" --branch main --depth 1 --quiet
COMMIT_SHA=$(git -C "$BUILD_DIR" rev-parse --short HEAD)
COMMIT_MSG=$(git -C "$BUILD_DIR" log -1 --pretty=format:"%s")
success "Latest commit: ${COMMIT_SHA} — ${COMMIT_MSG}"
echo ""
read -rp "  Deploy this commit? [Y/n] " confirm; confirm="${confirm:-Y}"
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

header "Build & push"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com" 2>/dev/null
docker buildx build --platform linux/amd64 --push -t "$ECR_IMAGE" "$BUILD_DIR"
docker buildx build --platform linux/amd64 --push \
  -t "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${APP_NAME}:${COMMIT_SHA}" "$BUILD_DIR" --quiet
success "Pushed :latest and :${COMMIT_SHA}"

header "Redeploy"
aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" \
  --force-new-deployment --region "$REGION" >/dev/null
success "Deployment triggered"

header "Waiting for healthy (2-4 min)"
echo ""
attempt=0
while [ $attempt -lt 40 ]; do
  RUNNING=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text --region "$REGION" 2>/dev/null || echo "0")
  HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region "$REGION" 2>/dev/null || echo "unknown")
  echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
  [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ] && { echo ""; break; }
  sleep 10; attempt=$((attempt + 1))
done
echo ""
[ $attempt -eq 40 ] && { warn "Timed out. Check ./manage.sh status and ./manage.sh logs."; exit 1; }

echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  Update complete!${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}Deployed:${NC}  ${COMMIT_SHA} — ${COMMIT_MSG}"
echo -e "  ${BOLD}URL:${NC}       http://${ALB_DNS}/"
echo ""
