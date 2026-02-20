#!/bin/bash
# /opt/ua_monitor/notify_slack.sh
# Slack notification handler

SLACK_WEBHOOK="https://hooks.slack.com/services/XXXX/XXXX/XXXX"

send_slack() {
    local payload="$1"
    curl -s -o /dev/null -w "%{http_code}" -X POST "$SLACK_WEBHOOK" \
        -H 'Content-Type: application/json' \
        -d "$payload" | grep -q "^200$"
}

# -----------------------------------------------------------------------
# changes <count> <alertfile>
# Reads structured alert blocks from a temp file and sends one message
# FIX: REGS_START/REGS_END block used to properly capture multi-line regs
# -----------------------------------------------------------------------
notify_changes() {
    local count="$1"
    local alertfile="$2"
    local detected_at
    detected_at=$(date)
    local body=""

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
                body="${body}*Device:* ${device}\n"
                body="${body}*IP:* ${old_ip} → ${new_ip}\n"
                body="${body}*UA (old):* ${old_ua}\n"
                body="${body}*UA (new):* ${new_ua}\n"
                if [ -n "$regs" ]; then
                    body="${body}*Active registrations:*\n${regs}"
                fi
                body="${body}─────────────────────────────\n"
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

    local payload
    payload=$(cat <<EOF
{
    "text": ":warning: *${count} Device Change(s) Detected*",
    "attachments": [{
        "color": "danger",
        "footer": "${detected_at}",
        "text": "${body}"
    }]
}
EOF
)
    send_slack "$payload"
}

# -----------------------------------------------------------------------
# new_device_digest <count> <entriesfile>
# Reads device rows from a temp file and sends one summary message
# -----------------------------------------------------------------------
notify_new_device_digest() {
    local count="$1"
    local entriesfile="$2"
    local detected_at
    detected_at=$(date)

    local table
    table="Device                 | IP              | User Agent\n"
    table="${table}-----------------------|-----------------|------------------\n"
    while IFS= read -r line; do
        table="${table}${line}\n"
    done < "$entriesfile"

    local payload
    payload=$(cat <<EOF
{
    "text": ":new: *${count} New Device Registration(s)*",
    "attachments": [{
        "color": "#2eb886",
        "footer": "${detected_at}",
        "text": "\`\`\`${table}\`\`\`"
    }]
}
EOF
)
    send_slack "$payload"
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
