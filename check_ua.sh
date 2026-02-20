#!/bin/bash
# /opt/ua_monitor/check_ua.sh

DB_USER="ua_monitor"
DB_PASS="yourpassword"
LOG="/var/log/ua_monitor.log"
SUPPRESS_CONF="/opt/ua_monitor/suppress.conf"
NOTIFY_SCRIPT="/opt/ua_monitor/notify.sh"
LOOKBACK_MINUTES=6
SEED_MODE=false

# Alert mode options:
#   ua_only        — alert only when UA changes (ignore IP changes)
#   ip_only        — alert only when IP changes (ignore UA changes)
#   ua_and_ip      — alert only when BOTH UA and IP change together
#   ua_or_ip       — alert when either UA or IP changes (default)
ALERT_MODE="ua_or_ip"

# New device digest frequency:
#   every_run  — send at the end of every cron run
#   30min      — batch and send every 30 minutes
#   hourly     — batch and send every hour
#   daily      — batch and send once a day
NEW_DEVICE_DIGEST="every_run"

# How many octets to ignore when comparing IP changes (0 = disabled)
# 1 = ignore last octet only      (e.g. 192.168.1.100 -> 192.168.1.200 ignored)
# 2 = ignore last two octets      (e.g. 192.168.1.x -> 192.168.2.x ignored)
# 3 = ignore last three octets    (e.g. 192.x.x.x -> 192.x.x.x ignored)
# 0 = all IP changes are compared (default)
IGNORE_OCTET_COUNT=0

if [ "$1" = "--seed" ]; then
    SEED_MODE=true
    LOOKBACK_MINUTES=1440
    echo "Seed mode enabled — scanning last 24 hours, notifications suppressed"
fi

# Create temp files upfront and trap cleanup on any exit
CHANGE_TMPFILE=$(mktemp /tmp/ua_monitor_changes.XXXXXX)
trap 'rm -f "$CHANGE_TMPFILE"' EXIT

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"
}

mysql_run() {
    mysql -u"$DB_USER" -p"$DB_PASS" -N -s -e "$1" 2>/dev/null
}

mysql_query_file() {
    sed "s/LOOKBACK_MINUTES/${LOOKBACK_MINUTES}/" /opt/ua_monitor/query.sql | \
    mysql -u"$DB_USER" -p"$DB_PASS" -N -s 2>/dev/null
}

get_active_registrations() {
    # FIX: use original from_num/domain args, not SQL-escaped versions
    local from_num="$1"
    local domain="$2"
    local safe_num="${from_num//\'/\'\'}"
    local safe_domain="${domain//\'/\'\'}"

    mysql_run "
        SELECT
            INET_NTOA(rs.sipcallerip) AS ip,
            cu.ua,
            MAX(rs.created_at) AS last_seen,
            rs.expires
        FROM voipmonitor.register_state rs
        LEFT JOIN voipmonitor.cdr_ua cu ON cu.id = rs.ua_id
        WHERE rs.from_num = '${safe_num}'
          AND rs.to_domain = '${safe_domain}'
          AND rs.state = 1
          AND rs.created_at >= NOW() - INTERVAL 60 MINUTE
        GROUP BY INET_NTOA(rs.sipcallerip), cu.ua, rs.expires
        ORDER BY last_seen DESC;
    "
}

same_subnet() {
    local ip1="$1"
    local ip2="$2"
    local octets=$((4 - IGNORE_OCTET_COUNT))
    local prefix1 prefix2
    prefix1=$(echo "$ip1" | cut -d'.' -f1-${octets})
    prefix2=$(echo "$ip2" | cut -d'.' -f1-${octets})
    [ "$prefix1" = "$prefix2" ] && return 0 || return 1
}

should_alert() {
    local ip_changed="$1"
    local ua_changed="$2"

    case "$ALERT_MODE" in
        ua_only)
            [ "$ua_changed" = "true" ] && return 0 || return 1 ;;
        ip_only)
            [ "$ip_changed" = "true" ] && return 0 || return 1 ;;
        ua_and_ip)
            [ "$ua_changed" = "true" ] && [ "$ip_changed" = "true" ] && return 0 || return 1 ;;
        ua_or_ip)
            # FIX: braces prevent operator precedence bug with || and &&
            { [ "$ua_changed" = "true" ] || [ "$ip_changed" = "true" ]; } && return 0 || return 1 ;;
        *)
            return 0 ;;
    esac
}

should_suppress() {
    local from_num="$1"
    local domain="$2"
    local device_ip="$3"
    local old_ua="$4"
    local new_ua="$5"

    [ ! -f "$SUPPRESS_CONF" ] && return 1

    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        if [[ "$line" == DEVICE:* ]]; then
            local suppressed_device="${line#DEVICE:}"
            if [ "${from_num}@${domain}" = "$suppressed_device" ]; then
                log "SUPPRESSED (device match: ${from_num}@${domain})"
                return 0
            fi
        fi

        if [[ "$line" == DOMAIN:* ]]; then
            local suppressed_domain="${line#DOMAIN:}"
            if [ "$domain" = "$suppressed_domain" ]; then
                log "SUPPRESSED (domain match: $domain)"
                return 0
            fi
        fi

        if [[ "$line" == IP:* ]]; then
            local whitelisted_ip="${line#IP:}"
            if [ "$device_ip" = "$whitelisted_ip" ]; then
                log "SUPPRESSED (whitelisted IP $device_ip)"
                return 0
            fi
        fi

        if [[ "$line" == UA:* ]]; then
            local suppressed_ua="${line#UA:}"
            if [ "$old_ua" = "$suppressed_ua" ] || [ "$new_ua" = "$suppressed_ua" ]; then
                log "SUPPRESSED (UA match: $suppressed_ua)"
                return 0
            fi
        fi

        if [[ "$line" == UA_PREFIX:* ]]; then
            local prefix="${line#UA_PREFIX:}"
            if [[ "$old_ua" == ${prefix}* ]] || [[ "$new_ua" == ${prefix}* ]]; then
                log "SUPPRESSED (UA prefix match: $prefix)"
                return 0
            fi
        fi

        if [[ "$line" == UA_CHANGE:* ]]; then
            local change_pair="${line#UA_CHANGE:}"
            local from_ua="${change_pair%%->*}"
            local to_ua="${change_pair##*->}"
            if [ "$old_ua" = "$from_ua" ] && [ "$new_ua" = "$to_ua" ]; then
                log "SUPPRESSED (UA change: $from_ua -> $to_ua)"
                return 0
            fi
        fi

        if [[ "$line" == UA_CHANGE_PREFIX:* ]]; then
            local change_pair="${line#UA_CHANGE_PREFIX:}"
            local from_prefix="${change_pair%%->*}"
            local to_prefix="${change_pair##*->}"
            if [[ "$old_ua" == ${from_prefix}* ]] && [[ "$new_ua" == ${to_prefix}* ]]; then
                log "SUPPRESSED (UA change prefix match: $from_prefix -> $to_prefix)"
                return 0
            fi
        fi

    done < "$SUPPRESS_CONF"

    return 1
}

should_send_digest() {
    local last_digest
    last_digest=$(mysql_run "SELECT COALESCE(MAX(sent_at), '2000-01-01') FROM ua_monitor.digest_log;")

    case "$NEW_DEVICE_DIGEST" in
        every_run)
            return 0 ;;
        30min)
            mysql_run "SELECT IF(NOW() > DATE_ADD('${last_digest}', INTERVAL 30 MINUTE), 1, 0);" | grep -q "^1$" && return 0 || return 1 ;;
        hourly)
            mysql_run "SELECT IF(NOW() > DATE_ADD('${last_digest}', INTERVAL 1 HOUR), 1, 0);" | grep -q "^1$" && return 0 || return 1 ;;
        daily)
            mysql_run "SELECT IF(NOW() > DATE_ADD('${last_digest}', INTERVAL 1 DAY), 1, 0);" | grep -q "^1$" && return 0 || return 1 ;;
        *)
            return 0 ;;
    esac
}

queue_new_device() {
    local from_num="$1"
    local domain="$2"
    local device_ip="$3"
    local current_ua="$4"

    local safe_num="${from_num//\'/\'\'}"
    local safe_domain="${domain//\'/\'\'}"
    local safe_ip="${device_ip//\'/\'\'}"
    local safe_ua="${current_ua//\'/\'\'}"

    mysql_run "
        INSERT INTO ua_monitor.new_device_queue (from_num, domain, contact_ip, ua, detected_at)
        VALUES ('${safe_num}', '${safe_domain}', '${safe_ip}', '${safe_ua}', NOW());
    "
}

flush_new_device_digest() {
    local queued
    queued=$(mysql_run "
        SELECT from_num, domain, contact_ip, ua, detected_at
        FROM ua_monitor.new_device_queue
        ORDER BY detected_at ASC;
    ")

    [ -z "$queued" ] && return 0

    local count
    count=$(mysql_run "SELECT COUNT(*) FROM ua_monitor.new_device_queue;")

    local tmpfile
    tmpfile=$(mktemp /tmp/ua_monitor_digest.XXXXXX)

    while IFS=$'\t' read -r q_num q_domain q_ip q_ua q_time; do
        local device="${q_num}@${q_domain}"
        printf '%-22s| %-15s | %s\n' "${device:0:22}" "${q_ip:0:15}" "${q_ua:0:40}" >> "$tmpfile"
    done <<< "$queued"

    # FIX: only clear queue if notify succeeds
    if "$NOTIFY_SCRIPT" new_device_digest "$count" "$tmpfile"; then
        mysql_run "DELETE FROM ua_monitor.new_device_queue;"
        mysql_run "INSERT INTO ua_monitor.digest_log (sent_at) VALUES (NOW());"
        log "DIGEST: Sent new device digest — $count device(s)"
    else
        log "DIGEST: Notification failed — queue preserved for next run"
    fi

    rm -f "$tmpfile"
}

# -----------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------

CHANGES=$(mysql_query_file)

if [ -z "$CHANGES" ]; then
    echo "No changes detected."
    if [ "$SEED_MODE" = false ] && should_send_digest; then
        flush_new_device_digest
    fi
    exit 0
fi

CHANGE_COUNT=0

while IFS=$'\t' read -r from_num domain device_ip current_ua known_ua known_ip change_type; do

    safe_num="${from_num//\'/\'\'}"
    safe_domain="${domain//\'/\'\'}"
    safe_ip="${device_ip//\'/\'\'}"
    safe_ua="${current_ua//\'/\'\'}"

    if [ "$change_type" = "new" ]; then
        mysql_run "
            INSERT INTO ua_monitor.device_ua (from_num, domain, contact_ip, last_ua, first_seen, last_seen)
            VALUES ('${safe_num}', '${safe_domain}', '${safe_ip}', '${safe_ua}', NOW(), NOW())
            ON DUPLICATE KEY UPDATE contact_ip = '${safe_ip}', last_ua = '${safe_ua}', last_seen = NOW();
        "
        log "NEW: $from_num@$domain @ $device_ip | UA: $current_ua"

        if [ "$SEED_MODE" = false ]; then
            queue_new_device "$from_num" "$domain" "$device_ip" "$current_ua"
        fi

    else
        if [ "$SEED_MODE" = false ]; then

            ip_changed="false"
            ua_changed="false"

            if [ "$known_ip" != "$device_ip" ]; then
                if [ "$IGNORE_OCTET_COUNT" -gt 0 ] && same_subnet "$known_ip" "$device_ip"; then
                    log "OCTET CHANGE IGNORED (last ${IGNORE_OCTET_COUNT} octet(s)): $from_num@$domain | IP: $known_ip -> $device_ip"
                else
                    ip_changed="true"
                fi
            fi
            [ "$known_ua" != "$current_ua" ] && ua_changed="true"

            if should_suppress "$from_num" "$domain" "$device_ip" "$known_ua" "$current_ua"; then
                mysql_run "
                    UPDATE ua_monitor.device_ua
                    SET contact_ip = '${safe_ip}', last_ua = '${safe_ua}', last_seen = NOW()
                    WHERE from_num = '${safe_num}'
                      AND domain = '${safe_domain}';
                "
            elif should_alert "$ip_changed" "$ua_changed"; then
                WHAT_CHANGED=""
                [ "$ip_changed" = "true" ] && WHAT_CHANGED="IP: $known_ip -> $device_ip "
                [ "$ua_changed" = "true" ] && WHAT_CHANGED="${WHAT_CHANGED}UA: $known_ua -> $current_ua"

                log "CHANGE ($ALERT_MODE): $from_num@$domain | $WHAT_CHANGED"

                # FIX: pass original from_num/domain to get_active_registrations
                active_regs=$(get_active_registrations "$from_num" "$domain")

                # Write alert block to temp file
                # REGS use a dedicated block so multi-line values are preserved
                {
                    printf 'ALERT_START\n'
                    printf 'device=%s@%s\n' "$from_num" "$domain"
                    printf 'old_ip=%s\n' "$known_ip"
                    printf 'new_ip=%s\n' "$device_ip"
                    printf 'old_ua=%s\n' "$known_ua"
                    printf 'new_ua=%s\n' "$current_ua"
                    printf 'REGS_START\n'
                    if [ -n "$active_regs" ]; then
                        while IFS=$'\t' read -r reg_ip reg_ua reg_time reg_expires; do
                            printf '  • %s | %s | seen: %s\n' "$reg_ip" "$reg_ua" "$reg_time"
                        done <<< "$active_regs"
                    else
                        printf '  None found in last 60 minutes\n'
                    fi
                    printf 'REGS_END\n'
                    printf 'ALERT_END\n'
                } >> "$CHANGE_TMPFILE"

                CHANGE_COUNT=$((CHANGE_COUNT + 1))

                mysql_run "
                    UPDATE ua_monitor.device_ua
                    SET contact_ip = '${safe_ip}', last_ua = '${safe_ua}', last_seen = NOW()
                    WHERE from_num = '${safe_num}'
                      AND domain = '${safe_domain}';
                "
            else
                log "SILENT ($ALERT_MODE): $from_num@$domain @ $device_ip | UA: $current_ua"
                mysql_run "
                    UPDATE ua_monitor.device_ua
                    SET contact_ip = '${safe_ip}', last_ua = '${safe_ua}', last_seen = NOW()
                    WHERE from_num = '${safe_num}'
                      AND domain = '${safe_domain}';
                "
            fi
        else
            mysql_run "
                INSERT INTO ua_monitor.device_ua (from_num, domain, contact_ip, last_ua, first_seen, last_seen)
                VALUES ('${safe_num}', '${safe_domain}', '${safe_ip}', '${safe_ua}', NOW(), NOW())
                ON DUPLICATE KEY UPDATE contact_ip = '${safe_ip}', last_ua = '${safe_ua}', last_seen = NOW();
            "
            log "SEED: $from_num@$domain @ $device_ip | UA: $current_ua"
        fi
    fi

done <<< "$CHANGES"

# Send all change alerts as a single batched notification
if [ "$CHANGE_COUNT" -gt 0 ] && [ "$SEED_MODE" = false ]; then
    "$NOTIFY_SCRIPT" changes "$CHANGE_COUNT" "$CHANGE_TMPFILE"
fi

# Send new device digest if threshold is met
if [ "$SEED_MODE" = false ] && should_send_digest; then
    flush_new_device_digest
fi

# Update last_seen for all currently registered devices in one shot
mysql_run "
    UPDATE ua_monitor.device_ua d
    INNER JOIN (
        SELECT rs.from_num, rs.to_domain, INET_NTOA(rs.sipcallerip) AS contact_ip
        FROM voipmonitor.register_state rs
        WHERE rs.state = 1
          AND rs.created_at >= NOW() - INTERVAL ${LOOKBACK_MINUTES} MINUTE
        GROUP BY rs.from_num, rs.to_domain
    ) rs ON rs.from_num = d.from_num
        AND rs.to_domain = d.domain
    SET d.last_seen = NOW();
"

if [ "$SEED_MODE" = true ]; then
    COUNT=$(mysql_run "SELECT COUNT(*) FROM ua_monitor.device_ua;")
    echo "Seed complete — $COUNT devices recorded in tracking table"
fi
