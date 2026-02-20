#!/bin/bash
# /opt/ua_monitor/notify_teams.sh
# Microsoft Teams notification handler

TEAMS_WEBHOOK="https://outlook.office.com/webhook/XXXX"

send_teams() {
    local payload="$1"
    curl -s -o /dev/null -w "%{http_code}" -X POST "$TEAMS_WEBHOOK" \
        -H 'Content-Type: application/json' \
        -d "$payload" | grep -q "^200$"
}

# -----------------------------------------------------------------------
# changes <count> <alertfile>
# FIX: REGS_START/REGS_END block used to properly capture multi-line regs
# -----------------------------------------------------------------------
notify_changes() {
    local count="$1"
    local alertfile="$2"
    local detected_at
    detected_at=$(date)
    local facts=""

    local device="" old_ip="" new_ip="" old_ua="" new_ua=""
    local in_regs=false in_alert=false

    while IFS= read -r line; do
        case "$line" in
            ALERT_START)
                in_alert=true
                device="" old_ip="" new_ip="" old_ua="" new_ua="" in_regs=false
                ;;
            ALERT_END)
                in_alert=false
                facts="${facts}{ \"name\": \"${device}\", \"value\": \"IP: ${old_ip} → ${new_ip} | UA: ${old_ua} → ${new_ua}\" },"
                ;;
            REGS_START)
                in_regs=true ;;
            REGS_END)
                in_regs=false ;;
            *)
                if [ "$in_alert" = true ] && [ "$in_regs" = false ]; then
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

    # Remove trailing comma
    facts="${facts%,}"

    local payload
    payload=$(cat <<EOF
{
    "@type": "MessageCard",
    "@context": "http://schema.org/extensions",
    "themeColor": "FF0000",
    "summary": "${count} Device Change(s) Detected",
    "sections": [{
        "activityTitle": "⚠️ ${count} Device Change(s) Detected",
        "activitySubtitle": "${detected_at}",
        "facts": [ ${facts} ]
    }]
}
EOF
)
    send_teams "$payload"
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

    local payload
    payload=$(cat <<EOF
{
    "@type": "MessageCard",
    "@context": "http://schema.org/extensions",
    "themeColor": "2eb886",
    "summary": "${count} New Device Registration(s)",
    "sections": [{
        "activityTitle": "🆕 ${count} New Device Registration(s)",
        "activitySubtitle": "${detected_at}",
        "text": "\`\`\`\nDevice                 | IP              | User Agent\n-----------------------|-----------------|------------------\n${entries}\`\`\`"
    }]
}
EOF
)
    send_teams "$payload"
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
