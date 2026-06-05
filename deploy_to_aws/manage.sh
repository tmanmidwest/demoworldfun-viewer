#!/bin/bash
# =============================================================================
# manage.sh — demoworldfun-viewer day-to-day management
# =============================================================================
#   ./manage.sh status | stop | start | restart | logs | url
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"
STATE_FILE=".demoworldfun-viewer-state"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

aws sts get-caller-identity >/dev/null 2>&1 \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
[ -f "$STATE_FILE" ] || error "No state file ($STATE_FILE). Deploy first with ./deploy.sh, or run ./restore-state.sh"
# shellcheck source=/dev/null
source "$STATE_FILE"

wait_healthy() {
  local attempt=0
  while [ $attempt -lt 30 ]; do
    RUNNING=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
      --query 'services[0].runningCount' --output text --region "$REGION" 2>/dev/null || echo "0")
    HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text --region "$REGION" 2>/dev/null || echo "unknown")
    echo -ne "  Running tasks: ${RUNNING} | ALB health: ${HEALTH}\r"
    [ "$RUNNING" = "1" ] && [ "$HEALTH" = "healthy" ] && { echo ""; return; }
    sleep 10; attempt=$((attempt + 1))
  done
  echo ""
}

case "${1:-help}" in
  status)
    echo ""; echo -e "${BOLD}  demoworldfun-viewer — Status${NC}"
    echo -e "  ─────────────────────────────────────────"
    SVC=$(aws ecs describe-services --cluster "$APP_NAME" --services "$SERVICE" \
      --region "$REGION" --query 'services[0]' --output json 2>/dev/null)
    DESIRED=$(echo "$SVC" | python3 -c "import sys,json; print(json.load(sys.stdin)['desiredCount'])" 2>/dev/null || echo "?")
    RUNNING=$(echo "$SVC" | python3 -c "import sys,json; print(json.load(sys.stdin)['runningCount'])" 2>/dev/null || echo "?")
    STATUS=$(echo "$SVC"  | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "?")
    HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --region "$REGION" \
      --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "unknown")
    if [ "$RUNNING" = "0" ] && [ "$DESIRED" = "0" ]; then APP_STATUS="${YELLOW}Stopped${NC}";
    elif [ "$RUNNING" = "$DESIRED" ] && [ "$HEALTH" = "healthy" ]; then APP_STATUS="${GREEN}Running${NC}";
    else APP_STATUS="${YELLOW}Starting / Unhealthy${NC}"; fi
    echo -e "  App status:    $(echo -e "$APP_STATUS")"
    echo -e "  ECS status:    $STATUS"
    echo -e "  Running tasks: $RUNNING / $DESIRED desired"
    echo -e "  ALB health:    $HEALTH"
    echo -e "  Region:        $REGION"
    echo ""; echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"; echo ""
    ;;
  stop)
    echo ""; log "Stopping (desired count → 0). DynamoDB/S3 data is untouched."
    aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" \
      --desired-count 0 --region "$REGION" >/dev/null
    success "Stopped. No Fargate compute charges now."
    warn "The ALB still runs (~\$0.50/day). Run ./teardown.sh to remove everything."
    echo -e "  Resume with ${BOLD}./manage.sh start${NC}."; echo ""
    ;;
  start)
    echo ""; log "Starting..."
    aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" \
      --desired-count 1 --region "$REGION" >/dev/null
    log "Waiting for healthy (~2 min)..."; echo ""; wait_healthy
    success "Running!"; echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"; echo ""
    ;;
  restart)
    echo ""; log "Forcing new deployment (re-pulls :latest)..."
    aws ecs update-service --cluster "$APP_NAME" --service "$SERVICE" \
      --force-new-deployment --region "$REGION" >/dev/null
    log "Waiting for healthy..."; echo ""; wait_healthy
    success "Restarted."; echo -e "  ${BOLD}URL:${NC}  http://${ALB_DNS}/"; echo ""
    ;;
  logs)
    echo ""; log "Streaming ${LOG_GROUP} (Ctrl+C to stop)..."; echo ""
    aws logs tail "$LOG_GROUP" --follow --region "$REGION"
    ;;
  url)
    echo ""; echo -e "  ${BOLD}App URL:${NC}  http://${ALB_DNS}/"
    echo -e "  ${BOLD}Health:${NC}   http://${ALB_DNS}/healthz"; echo ""
    ;;
  *)
    echo ""; echo -e "${BOLD}  demoworldfun-viewer — Management${NC}"; echo ""
    echo -e "  ${BOLD}./manage.sh status${NC}   Show status and URL"
    echo -e "  ${BOLD}./manage.sh stop${NC}     Pause (compute charges stop)"
    echo -e "  ${BOLD}./manage.sh start${NC}    Resume"
    echo -e "  ${BOLD}./manage.sh restart${NC}  Force restart / re-pull image"
    echo -e "  ${BOLD}./manage.sh logs${NC}     Stream live logs"
    echo -e "  ${BOLD}./manage.sh url${NC}      Print the URL"; echo ""
    echo -e "  ${BOLD}./deploy.sh${NC} deploy   ${BOLD}./update.sh${NC} update   ${BOLD}./teardown.sh${NC} delete"; echo ""
    ;;
esac
