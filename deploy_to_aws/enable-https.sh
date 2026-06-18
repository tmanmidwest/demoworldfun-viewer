#!/bin/bash
# =============================================================================
# enable-https.sh — Add HTTPS (ACM + ALB :443) and lock the ALB to Cloudflare
# =============================================================================
# Turns the HTTP-only ALB that deploy.sh builds into an HTTPS endpoint fronted
# by Cloudflare (proxied CNAME, SSL mode "Full (strict)"). It:
#
#   1. Requests (or reuses) an ACM cert for your custom domain (DNS-validated)
#   2. Adds an HTTPS:443 listener using that cert
#   3. Rewrites the HTTP:80 listener to redirect → HTTPS:443
#   4. Restricts the ALB security group to Cloudflare's IP ranges and removes
#      the world-open :80 rule, so nobody can bypass Cloudflare
#
# Safe to re-run: every step checks for what already exists. Run it AFTER
# deploy.sh has stood up the ALB.
#
#   ./enable-https.sh inbox.trevorcombs.com            # uses default region
#   ./enable-https.sh inbox.trevorcombs.com us-east-1  # or pass the region
#
# After it finishes, add the proxied CNAME in Cloudflare, set the zone's SSL
# mode to Full (strict), then re-run deploy.sh with the https:// callback base
# (it sets OIDC_REDIRECT_URI + SECURE_COOKIES for you).
# =============================================================================

set -euo pipefail

APP_NAME="demoworldfun-viewer"
SSL_POLICY="ELBSecurityPolicy-TLS13-1-2-2021-06"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
CHECKMARK="${GREEN}✔${NC}"; ARROW="${BLUE}▶${NC}"; WARNING="${YELLOW}⚠${NC}"

log()     { echo -e "${ARROW}  $1"; }
success() { echo -e "${CHECKMARK}  $1"; }
warn()    { echo -e "${WARNING}  ${YELLOW}$1${NC}"; }
error()   { echo -e "${RED}✖  ERROR: $1${NC}" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${BLUE}── $1 ${NC}"; }

# ── Inputs ────────────────────────────────────────────────────────────────────
HOST="${1:-}"
[ -n "$HOST" ] || error "Usage: ./enable-https.sh <hostname> [region]   e.g. ./enable-https.sh inbox.trevorcombs.com"

# ── AWS session + region ──────────────────────────────────────────────────────
header "Validating AWS session"
CALLER=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || error "Not logged in to AWS. Run 'aws configure' or refresh your session."
ACCOUNT_ID=$(echo "$CALLER" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
success "Logged in (Account: $ACCOUNT_ID)"

REGION="${2:-${AWS_REGION:-${AWS_DEFAULT_REGION:-}}}"
[ -n "$REGION" ] || REGION=$(aws configure get region 2>/dev/null || echo "")
[ -n "$REGION" ] || error "No region given/configured. e.g. ./enable-https.sh $HOST us-east-1"
success "Region: $REGION   Domain: $HOST"

# ── Discover the ALB, target group, and ALB security group (by name) ──────────
header "Discovering ALB resources for '${APP_NAME}'"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "${APP_NAME}-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_ARN" = "None" ] && ALB_ARN=""
[ -n "$ALB_ARN" ] || error "ALB '${APP_NAME}-alb' not found in $REGION. Run deploy.sh first (or pass the right region)."

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text --region "$REGION")
TG_ARN=$(aws elbv2 describe-target-groups --names "${APP_NAME}-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$TG_ARN" = "None" ] && TG_ARN=""
[ -n "$TG_ARN" ] || error "Target group '${APP_NAME}-tg' not found in $REGION."

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text --region "$REGION")
ALB_SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values="${APP_NAME}-alb-sg" Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text --region "$REGION" 2>/dev/null || echo "")
[ "$ALB_SG_ID" = "None" ] && ALB_SG_ID=""
[ -n "$ALB_SG_ID" ] || error "ALB security group '${APP_NAME}-alb-sg' not found in $REGION."
success "ALB: $ALB_DNS"
success "Target group + ALB SG ($ALB_SG_ID) found"

# ── 1. ACM certificate (reuse if one already exists for this domain) ──────────
header "ACM certificate for $HOST"
CERT_ARN=$(aws acm list-certificates --region "$REGION" \
  --query "CertificateSummaryList[?DomainName=='${HOST}'].CertificateArn | [0]" \
  --output text 2>/dev/null || echo "")
[ "$CERT_ARN" = "None" ] && CERT_ARN=""
if [ -z "$CERT_ARN" ]; then
  log "Requesting a new DNS-validated certificate..."
  CERT_ARN=$(aws acm request-certificate --domain-name "$HOST" \
    --validation-method DNS --region "$REGION" --query CertificateArn --output text)
  success "Requested: $CERT_ARN"
else
  success "Reusing existing cert: $CERT_ARN"
fi

# Wait for the validation record to be populated, then print it.
log "Fetching the DNS validation record..."
RR=""
for _ in $(seq 1 15); do
  RR=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json 2>/dev/null || echo "null")
  [ "$RR" != "null" ] && [ -n "$RR" ] && break
  sleep 4
done
if [ "$RR" = "null" ] || [ -z "$RR" ]; then
  warn "Validation record not available yet. Re-run this script in a minute."
else
  V_NAME=$(echo "$RR" | python3 -c "import sys,json; print(json.load(sys.stdin)['Name'])")
  V_VALUE=$(echo "$RR" | python3 -c "import sys,json; print(json.load(sys.stdin)['Value'])")
  echo ""
  echo -e "  ${BOLD}Add this CNAME in Cloudflare (set it to DNS-only / grey cloud):${NC}"
  echo -e "    ${BOLD}Name:${NC}  $V_NAME"
  echo -e "    ${BOLD}Value:${NC} $V_VALUE"
  echo ""
fi

# Poll until the cert is ISSUED (the user adds the record above in parallel).
STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
  --query 'Certificate.Status' --output text)
if [ "$STATUS" != "ISSUED" ]; then
  log "Waiting for the certificate to validate (add the record above; ~2-10 min)..."
  for _ in $(seq 1 60); do
    STATUS=$(aws acm describe-certificate --certificate-arn "$CERT_ARN" --region "$REGION" \
      --query 'Certificate.Status' --output text)
    [ "$STATUS" = "ISSUED" ] && break
    [ "$STATUS" = "FAILED" ] && error "Certificate validation FAILED. Check the CNAME in Cloudflare."
    printf '.'
    sleep 20
  done
  echo ""
fi
[ "$STATUS" = "ISSUED" ] || error "Certificate still '$STATUS'. Add the validation CNAME and re-run."
success "Certificate ISSUED"

# ── 2. HTTPS:443 listener ─────────────────────────────────────────────────────
header "HTTPS :443 listener"
L443=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query "Listeners[?Port==\`443\`].ListenerArn | [0]" --output text 2>/dev/null || echo "")
[ "$L443" = "None" ] && L443=""
if [ -z "$L443" ]; then
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
    --protocol HTTPS --port 443 \
    --certificates CertificateArn="$CERT_ARN" \
    --ssl-policy "$SSL_POLICY" \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
    --region "$REGION" >/dev/null
  success "Created HTTPS:443 listener → app"
else
  # Ensure the existing listener uses our cert.
  aws elbv2 modify-listener --listener-arn "$L443" \
    --certificates CertificateArn="$CERT_ARN" --ssl-policy "$SSL_POLICY" \
    --region "$REGION" >/dev/null
  success "HTTPS:443 listener already present (cert refreshed)"
fi

# ── 3. Redirect HTTP:80 → HTTPS:443 ───────────────────────────────────────────
header "HTTP :80 → HTTPS redirect"
L80=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$REGION" \
  --query "Listeners[?Port==\`80\`].ListenerArn | [0]" --output text 2>/dev/null || echo "")
[ "$L80" = "None" ] && L80=""
if [ -n "$L80" ]; then
  aws elbv2 modify-listener --listener-arn "$L80" --region "$REGION" \
    --default-actions 'Type=redirect,RedirectConfig={Protocol=HTTPS,Port=443,StatusCode=HTTP_301}' >/dev/null
  success "HTTP:80 now 301-redirects to HTTPS"
else
  warn "No HTTP:80 listener found — skipping redirect."
fi

# ── 4. Lock the ALB security group to Cloudflare IPs ──────────────────────────
header "Restrict ALB to Cloudflare IP ranges"
CF_IPS=$(curl -fsS https://www.cloudflare.com/ips-v4 2>/dev/null || echo "")
[ -n "$CF_IPS" ] || error "Couldn't fetch Cloudflare IP list from https://www.cloudflare.com/ips-v4"
count=0
for cidr in $CF_IPS; do
  for port in 80 443; do
    # Duplicate rules are fine — swallow the duplicate error.
    aws ec2 authorize-security-group-ingress --group-id "$ALB_SG_ID" \
      --protocol tcp --port "$port" --cidr "$cidr" --region "$REGION" >/dev/null 2>&1 || true
  done
  count=$((count + 1))
done
success "Allowed Cloudflare ranges on :80 and :443 ($count CIDRs)"

# Remove the world-open :80 rule deploy.sh created (ignore if already gone).
if aws ec2 revoke-security-group-ingress --group-id "$ALB_SG_ID" \
    --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null 2>&1; then
  success "Removed open-to-world :80 rule (0.0.0.0/0)"
else
  warn "No open :80 rule to remove (already restricted)."
fi
warn "Direct ALB access over the raw *.elb.amazonaws.com name will now fail — that's intended; reach the app through Cloudflare."

# ── Next steps ────────────────────────────────────────────────────────────────
header "Done — finish in Cloudflare + redeploy"
cat <<EOF

  ${BOLD}1. Cloudflare DNS${NC}
     Add a record:  ${BOLD}${HOST%%.*}${NC} → CNAME → ${BOLD}${ALB_DNS}${NC}  (Proxied / orange cloud)

  ${BOLD}2. Cloudflare SSL/TLS${NC}
     Set the zone's encryption mode to ${BOLD}Full (strict)${NC}.

  ${BOLD}3. Authentik${NC}
     Set the provider's redirect URI to:  ${BOLD}https://${HOST}/auth/callback${NC}

  ${BOLD}4. Redeploy the app${NC}
     Re-run ./deploy.sh and give it ${BOLD}https://${HOST}${NC} as the callback base URL.
     (That sets OIDC_REDIRECT_URI and flips SECURE_COOKIES=true.)

  Then browse to:  ${BOLD}https://${HOST}/${NC}

EOF
