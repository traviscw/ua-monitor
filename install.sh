#!/bin/bash
# UA Monitor Installer
# Pulls latest files from GitHub and configures the system

GITHUB_REPO="https://raw.githubusercontent.com/traviscw/ua-monitor/main"
INSTALL_DIR="/opt/ua_monitor"
LOG="/var/log/ua_monitor.log"

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ $*${NC}"; }
warn() { echo -e "${YELLOW}  ! $*${NC}"; }
err()  { echo -e "${RED}  ✗ $*${NC}"; exit 1; }
ask()  { echo -e "\n${YELLOW}$*${NC}"; }

# -----------------------------------------------------------------------
# Checks
# -----------------------------------------------------------------------

echo ""
echo "========================================"
echo "  UA Monitor Installer"
echo "========================================"
echo ""

[ "$EUID" -ne 0 ] && err "Please run as root: sudo bash install.sh"

command -v mysql  &>/dev/null || err "mysql client not found — is VoIPmonitor installed?"
command -v curl   &>/dev/null || err "curl not found — please install: apt install curl"

ok "Prerequisites OK"

# -----------------------------------------------------------------------
# Gather config
# -----------------------------------------------------------------------

ask "MySQL root password (for one-time DB setup):"
read -rsp "  > " MYSQL_ROOT_PASS
echo ""

ask "UA Monitor DB password (will be set for the ua_monitor MySQL user):"
read -rsp "  > " DB_PASS
echo ""

ask "Notification provider (slack / email / teams) [slack]:"
read -r NOTIFY_PROVIDER
NOTIFY_PROVIDER="${NOTIFY_PROVIDER:-slack}"

case "$NOTIFY_PROVIDER" in
    slack)
        ask "Slack webhook URL:"
        read -r SLACK_WEBHOOK
        [[ "$SLACK_WEBHOOK" == https://hooks.slack.com/* ]] || warn "Webhook URL looks unusual — double check it"
        ;;
    email)
        ask "Email address to send alerts to:"
        read -r EMAIL_TO
        ask "Email address to send alerts from:"
        read -r EMAIL_FROM
        ;;
    teams)
        ask "Microsoft Teams webhook URL:"
        read -r TEAMS_WEBHOOK
        ;;
    *)
        err "Unknown provider: $NOTIFY_PROVIDER — must be slack, email, or teams"
        ;;
esac

ask "Alert mode (ua_only / ip_only / ua_and_ip / ua_or_ip) [ua_or_ip]:"
read -r ALERT_MODE
ALERT_MODE="${ALERT_MODE:-ua_or_ip}"

ask "New device digest frequency (every_run / 30min / hourly / daily) [every_run]:"
read -r NEW_DEVICE_DIGEST
NEW_DEVICE_DIGEST="${NEW_DEVICE_DIGEST:-every_run}"

ask "Ignore IP octet count (0-3, 0 = disabled) [0]:"
read -r IGNORE_OCTET_COUNT
IGNORE_OCTET_COUNT="${IGNORE_OCTET_COUNT:-0}"

echo ""
echo "========================================"
echo "  Installing..."
echo "========================================"

# -----------------------------------------------------------------------
# Download files
# -----------------------------------------------------------------------

mkdir -p "$INSTALL_DIR"

FILES=(check_ua.sh notify.sh notify_slack.sh notify_email.sh notify_teams.sh query.sql suppress.conf cleanup.sh)

for f in "${FILES[@]}"; do
    curl -fsSL "${GITHUB_REPO}/${f}" -o "${INSTALL_DIR}/${f}" \
        || err "Failed to download ${f} from GitHub"
    ok "Downloaded $f"
done

# -----------------------------------------------------------------------
# Configure files
# -----------------------------------------------------------------------

# check_ua.sh
sed -i "s|DB_PASS=\"yourpassword\"|DB_PASS=\"${DB_PASS}\"|" "${INSTALL_DIR}/check_ua.sh"
sed -i "s|ALERT_MODE=\"ua_or_ip\"|ALERT_MODE=\"${ALERT_MODE}\"|" "${INSTALL_DIR}/check_ua.sh"
sed -i "s|NEW_DEVICE_DIGEST=\"every_run\"|NEW_DEVICE_DIGEST=\"${NEW_DEVICE_DIGEST}\"|" "${INSTALL_DIR}/check_ua.sh"
sed -i "s|IGNORE_OCTET_COUNT=0|IGNORE_OCTET_COUNT=${IGNORE_OCTET_COUNT}|" "${INSTALL_DIR}/check_ua.sh"

# notify.sh
sed -i "s|NOTIFY_PROVIDER=\"slack\"|NOTIFY_PROVIDER=\"${NOTIFY_PROVIDER}\"|" "${INSTALL_DIR}/notify.sh"

# notify_slack.sh
if [ "$NOTIFY_PROVIDER" = "slack" ]; then
    sed -i "s|SLACK_WEBHOOK=\"https://hooks.slack.com/services/XXXX/XXXX/XXXX\"|SLACK_WEBHOOK=\"${SLACK_WEBHOOK}\"|" "${INSTALL_DIR}/notify_slack.sh"
fi

# notify_email.sh
if [ "$NOTIFY_PROVIDER" = "email" ]; then
    sed -i "s|EMAIL_TO=\"admin@yourdomain.com\"|EMAIL_TO=\"${EMAIL_TO}\"|" "${INSTALL_DIR}/notify_email.sh"
    sed -i "s|EMAIL_FROM=\"ua-monitor@yourdomain.com\"|EMAIL_FROM=\"${EMAIL_FROM}\"|" "${INSTALL_DIR}/notify_email.sh"
fi

# notify_teams.sh
if [ "$NOTIFY_PROVIDER" = "teams" ]; then
    sed -i "s|TEAMS_WEBHOOK=\"https://outlook.office.com/webhook/XXXX\"|TEAMS_WEBHOOK=\"${TEAMS_WEBHOOK}\"|" "${INSTALL_DIR}/notify_teams.sh"
fi

# cleanup.sh
sed -i "s|DB_PASS=\"yourpassword\"|DB_PASS=\"${DB_PASS}\"|" "${INSTALL_DIR}/cleanup.sh"

ok "Files configured"

# -----------------------------------------------------------------------
# Permissions
# -----------------------------------------------------------------------

chmod 700 "${INSTALL_DIR}/check_ua.sh"
chmod 700 "${INSTALL_DIR}/notify.sh"
chmod 700 "${INSTALL_DIR}/notify_slack.sh"
chmod 700 "${INSTALL_DIR}/notify_email.sh"
chmod 700 "${INSTALL_DIR}/notify_teams.sh"
chmod 700 "${INSTALL_DIR}/cleanup.sh"
chmod 600 "${INSTALL_DIR}/suppress.conf"
chmod 600 "${INSTALL_DIR}/query.sql"

touch "$LOG"
chmod 640 "$LOG"

ok "Permissions set"

# -----------------------------------------------------------------------
# Database setup
# -----------------------------------------------------------------------

# Download and apply setup.sql
curl -fsSL "${GITHUB_REPO}/setup.sql" -o /tmp/ua_monitor_setup.sql \
    || err "Failed to download setup.sql from GitHub"

# Substitute password placeholder
sed -i "s|yourpassword|${DB_PASS}|g" /tmp/ua_monitor_setup.sql

mysql -u root -p"${MYSQL_ROOT_PASS}" < /tmp/ua_monitor_setup.sql 2>/dev/null \
    || err "Database setup failed — check your MySQL root password"

rm -f /tmp/ua_monitor_setup.sql
ok "Database configured"

# -----------------------------------------------------------------------
# Seed
# -----------------------------------------------------------------------

echo ""
echo "  Seeding device database (scanning last 24 hours)..."
"${INSTALL_DIR}/check_ua.sh" --seed
ok "Seed complete"

# -----------------------------------------------------------------------
# Cron
# -----------------------------------------------------------------------

echo ""
ask "Install cron jobs? (y/n) [y]:"
read -r INSTALL_CRON
INSTALL_CRON="${INSTALL_CRON:-y}"

if [[ "$INSTALL_CRON" =~ ^[Yy]$ ]]; then
    # Check if cron entries already exist
    crontab -l 2>/dev/null | grep -q "ua_monitor" && warn "Cron entries already exist — skipping" || {
        (crontab -l 2>/dev/null; echo "*/5 * * * * ${INSTALL_DIR}/check_ua.sh") | crontab -
        (crontab -l 2>/dev/null; echo "0 3 * * 0 ${INSTALL_DIR}/cleanup.sh") | crontab -
        ok "Cron jobs installed"
    }
fi

# -----------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------

echo ""
echo "========================================"
echo -e "${GREEN}  UA Monitor installed successfully!${NC}"
echo "========================================"
echo ""
echo "  Install dir:  $INSTALL_DIR"
echo "  Log file:     $LOG"
echo "  Provider:     $NOTIFY_PROVIDER"
echo "  Alert mode:   $ALERT_MODE"
echo "  Digest:       $NEW_DEVICE_DIGEST"
echo ""
echo "  Useful commands:"
echo "    tail -f $LOG"
echo "    ${INSTALL_DIR}/check_ua.sh"
echo ""
