#!/bin/bash
# /opt/ua_monitor/notify_email.sh
# Email notification handler — requires sendmail or mailutils

EMAIL_TO="admin@yourdomain.com"
EMAIL_FROM="ua-monitor@yourdomain.com"

# -----------------------------------------------------------------------
# changes <count> <alertfile>
# FIX: REGS_START/REGS_END block used to properly capture multi-line regs
# -----------------------------------------------------------------------
notify_changes() {
    local count="$1"
    local alertfile="$2"
    local detected_at
    detected_at=$(date)
    local body="${count} device change(s) detected at ${detected_at}\n\n"

    local device="" old_ip="" new_ip="" old_ua="" new_ua=""
    local regs="" in_regs=false in_alert=false

    while IFS= read -r line; do
        case "$line" in
            ALERT_START)
                in_alert=true
                device="" old_ip="" new_ip="" old_ua="" new_ua="" regs="" in_regs=false
                ;;
            ALERT_END)
                in_alert=false
                body="${body}Device:  ${device}\n"
                body="${body}IP:      ${old_ip} -> ${new_ip}\n"
                body="${body}UA (old): ${old_ua}\n"
                body="${body}UA (new): ${new_ua}\n"
                if [ -n "$regs" ]; then
                    body="${body}Active registrations:\n${regs}"
                fi
                body="${body}---\n\n"
                ;;
            REGS_START)
                in_regs=true
                ;;
            REGS_END)
                in_regs=false
                ;;
            *)
                if [ "$in_regs" = true ]; then
                    regs="${regs}${line}\n"
                elif [ "$in_alert" = true ]; then
                    case "$line" in
                        device=*)  device="${line#device=}" ;;
                        old_ip=*)  old_ip="${line#old_ip=}" ;;
                        new_ip=*)  new_ip="${line#new_ip=}" ;;
                        old_ua=*)  old_ua="${line#old_ua=}" ;;
                        new_ua=*)  new_ua="${line#new_ua=}" ;;
                    esac
                fi
                ;;
        esac
    done < "$alertfile"

    printf "Subject: [UA Monitor] %s Device Change(s) Detected\nFrom: %s\nTo: %s\n\n%b" \
        "$count" "$EMAIL_FROM" "$EMAIL_TO" "$body" | sendmail "$EMAIL_TO"
}

# -----------------------------------------------------------------------
# new_device_digest <count> <entriesfile>
# -----------------------------------------------------------------------
notify_new_device_digest() {
    local count="$1"
    local entriesfile="$2"
    local detected_at
    detected_at=$(date)

    local entries
    entries=$(cat "$entriesfile")

    printf "Subject: [UA Monitor] %s New Device Registration(s)\nFrom: %s\nTo: %s\n\n%s new device(s) at %s\n\n%-22s| %-15s | %s\n%s\n%s\n" \
        "$count" "$EMAIL_FROM" "$EMAIL_TO" \
        "$count" "$detected_at" \
        "Device" "IP" "User Agent" \
        "----------------------|-----------------|------------------" \
        "$entries" | sendmail "$EMAIL_TO"
}

# -----------------------------------------------------------------------
# Router
# -----------------------------------------------------------------------
case "$1" in
    changes)
        notify_changes "$2" "$3" ;;
    new_device_digest)
        notify_new_device_digest "$2" "$3" ;;
    *)
        echo "Unknown notification type: $1"
        exit 1
        ;;
esac
