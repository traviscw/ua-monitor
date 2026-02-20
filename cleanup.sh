#!/bin/bash
# /opt/ua_monitor/cleanup.sh
# Removes stale devices and trims log tables
# Run weekly via cron:
#   0 3 * * 0 /opt/ua_monitor/cleanup.sh

DB_USER="ua_monitor"
DB_PASS="yourpassword"
LOG="/var/log/ua_monitor.log"
RETENTION_DAYS=90

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

mysql_run() {
    mysql -u"$DB_USER" -p"$DB_PASS" -N -s -e "$1" ua_monitor 2>/dev/null
}

# FIX: split into two separate queries — ROW_COUNT() in same -e call
# is unreliable across MySQL/MariaDB versions
mysql_run "
    DELETE FROM device_ua
    WHERE last_seen < NOW() - INTERVAL ${RETENTION_DAYS} DAY;
"
DELETED=$(mysql_run "SELECT ROW_COUNT();")

# FIX: trim digest_log so it doesn't grow forever
mysql_run "
    DELETE FROM digest_log
    WHERE sent_at < NOW() - INTERVAL ${RETENTION_DAYS} DAY;
"

log "CLEANUP: Removed $DELETED stale devices (not seen in ${RETENTION_DAYS} days)"
echo "Removed $DELETED stale devices"
