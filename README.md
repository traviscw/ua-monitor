# UA Monitor

A lightweight SIP device registration monitor for **VoIPmonitor** environments. Detects when a registered device's User Agent string or IP address changes and alerts your team — via Slack, email, or Microsoft Teams. Built entirely in bash with no additional software requirements beyond what VoIPmonitor already installs.

---

## How It Works

VoIPmonitor passively captures SIP traffic and stores registration events in MySQL. UA Monitor queries that data every 5 minutes, compares each device's current registration against a known-state tracking table, and fires alerts when something changes.

```
voipmonitor.register_state  ──►  ua_monitor.device_ua  ──►  notify.sh  ──►  Slack / Email / Teams
     (live SIP data)               (known state)            (router)         (your choice)
```

All changes are written to the tracking database and a local log file regardless of alert settings.

---

## Requirements

- VoIPmonitor server running Ubuntu/Debian
- MySQL/MariaDB (already present with VoIPmonitor)
- `sip-register = yes` in `/etc/voipmonitor.conf`
- `curl` and `bash` (already present)
- A Slack webhook, email (sendmail/mailutils), or Teams webhook

---

## Installation

### Option 1 — Automatic

Downloads all files from GitHub and walks you through configuration interactively:

```bash
curl -fsSL https://raw.githubusercontent.com/traviscw/ua-monitor/main/install.sh | sudo bash
```

You will be prompted for:
- MySQL root password
- UA Monitor DB password (a new password you choose)
- Notification provider (Slack / email / Teams) and credentials
- Alert mode, digest frequency, and octet ignore settings

The script will download all files, configure credentials, set permissions, run the database setup, seed the device table, and optionally install cron jobs — all in one shot.

---

### Option 2 — Manual

#### 1. Run MySQL Setup

Update the password in `setup.sql` first, then:

```bash
mysql -u root -p < setup.sql
```

#### 2. Deploy Files

```bash
sudo mkdir -p /opt/ua_monitor
sudo cp check_ua.sh query.sql notify.sh notify_slack.sh notify_email.sh notify_teams.sh suppress.conf /opt/ua_monitor/
```

#### 3. Set Credentials

Edit `check_ua.sh`:
```bash
DB_PASS="yourpassword"
```

Edit your chosen notification script. For Slack, edit `notify_slack.sh`:
```bash
SLACK_WEBHOOK="https://hooks.slack.com/services/XXXX/XXXX/XXXX"
```

For email, edit `notify_email.sh`:
```bash
EMAIL_TO="admin@yourdomain.com"
EMAIL_FROM="ua-monitor@yourdomain.com"
```

For Teams, edit `notify_teams.sh`:
```bash
TEAMS_WEBHOOK="https://outlook.office.com/webhook/XXXX"
```

Then set your provider in `notify.sh`:
```bash
NOTIFY_PROVIDER="slack"   # slack | email | teams
```

#### 4. Set Permissions

```bash
sudo chmod 700 /opt/ua_monitor/check_ua.sh
sudo chmod 700 /opt/ua_monitor/notify.sh
sudo chmod 700 /opt/ua_monitor/notify_slack.sh
sudo chmod 700 /opt/ua_monitor/notify_email.sh
sudo chmod 700 /opt/ua_monitor/notify_teams.sh
sudo chmod 700 /opt/ua_monitor/cleanup.sh
sudo chmod 600 /opt/ua_monitor/suppress.conf
sudo chmod 600 /opt/ua_monitor/query.sql
sudo touch /var/log/ua_monitor.log
sudo chmod 640 /var/log/ua_monitor.log
```

#### 5. Seed the Database

```bash
sudo /opt/ua_monitor/check_ua.sh --seed
```

Verify:
```bash
mysql -u"ua_monitor" -p'yourpassword' -e "SELECT COUNT(*) FROM ua_monitor.device_ua;"
tail -20 /var/log/ua_monitor.log
```

#### 6. Test Run

```bash
sudo /opt/ua_monitor/check_ua.sh
```

#### 7. Enable Cron

```bash
sudo crontab -e
```

Add:
```
*/5 * * * * /opt/ua_monitor/check_ua.sh
0 3 * * 0 /opt/ua_monitor/cleanup.sh
```

---

## Files

| File | Description |
|---|---|
| `install.sh` | Automated installer — pulls from GitHub and configures everything |
| `check_ua.sh` | Main monitoring script — runs on cron every 5 minutes |
| `query.sql` | Change detection SQL query |
| `notify.sh` | Notification router — set your provider here |
| `notify_slack.sh` | Slack notification handler |
| `notify_email.sh` | Email notification handler |
| `notify_teams.sh` | Microsoft Teams notification handler |
| `suppress.conf` | Suppression rules |
| `setup.sql` | MySQL setup — run once on fresh install |
| `cleanup.sh` | Weekly stale device removal |

---

## Configuration

### check_ua.sh

| Setting | Options | Description |
|---|---|---|
| `ALERT_MODE` | `ua_only` `ip_only` `ua_and_ip` `ua_or_ip` | What triggers an alert |
| `NEW_DEVICE_DIGEST` | `every_run` `30min` `hourly` `daily` | How often to send new device summary |
| `IGNORE_OCTET_COUNT` | `0` `1` `2` `3` | How many IP octets to ignore when comparing |

### notify.sh

| Setting | Options | Description |
|---|---|---|
| `NOTIFY_PROVIDER` | `slack` `email` `teams` | Which notification script to use |

### Alert Modes

| Mode | Behaviour |
|---|---|
| `ua_only` | Alert only when the UA string changes |
| `ip_only` | Alert only when the IP address changes |
| `ua_and_ip` | Alert only when **both** UA and IP change together |
| `ua_or_ip` | Alert when **either** changes *(default)* |

### Octet Ignore

| Setting | Behaviour |
|---|---|
| `0` | All IP changes alert *(default)* |
| `1` | Ignores last octet — `192.168.1.x` changes ignored |
| `2` | Ignores last two octets — `192.168.x.x` changes ignored |
| `3` | Ignores last three octets — `192.x.x.x` changes ignored |

### New Device Digest

| Setting | Behaviour |
|---|---|
| `every_run` | Sends at the end of every 5-minute cron run |
| `30min` | Batches new devices and sends every 30 minutes |
| `hourly` | Batches new devices and sends every hour |
| `daily` | Batches new devices and sends once a day |

---

## Suppression Rules

Edit `/opt/ua_monitor/suppress.conf`. Changes take effect on the next cron run — no restart needed.

| Rule | Example | Effect |
|---|---|---|
| `DEVICE:` | `DEVICE:200@domain.com` | Ignore a specific device |
| `DOMAIN:` | `DOMAIN:testdomain.com` | Ignore all devices on a domain |
| `IP:` | `IP:192.168.1.100` | Ignore a specific source IP |
| `UA:` | `UA:Mobile321` | Ignore an exact UA string |
| `UA_PREFIX:` | `UA_PREFIX:Mobile/1.0` | Ignore any UA starting with prefix |
| `UA_CHANGE:` | `UA_CHANGE:UA One->UA Two` | Ignore an exact UA-to-UA change |
| `UA_CHANGE_PREFIX:` | `UA_CHANGE_PREFIX:App/1.8->App/1.9` | Ignore version bumps within the same app |

---

## Alerts

### 🔴 Change Alert
All UA/IP changes detected in a single cron run are batched into **one** message per run, rather than one message per device.

### 🟢 New Device Digest
New devices are queued and sent as a single batched table on the configured digest schedule.

---

## Useful Commands

```bash
# Seed or reseed the tracking database
sudo /opt/ua_monitor/check_ua.sh --seed

# Watch the log live
tail -f /var/log/ua_monitor.log

# Check device count
mysql -u"ua_monitor" -p'yourpassword' -e "
    SELECT COUNT(*) AS devices, MIN(last_seen) AS oldest, MAX(last_seen) AS newest
    FROM ua_monitor.device_ua;"

# Check new device queue
mysql -u"ua_monitor" -p'yourpassword' -e "
    SELECT COUNT(*) AS queued FROM ua_monitor.new_device_queue;" ua_monitor

# Check last digest sent
mysql -u"ua_monitor" -p'yourpassword' -e "
    SELECT MAX(sent_at) AS last_digest FROM ua_monitor.digest_log;" ua_monitor
```

---

## Log Reference

| Prefix | Meaning |
|---|---|
| `NEW:` | First time this device has been seen |
| `SEED:` | Device recorded during a `--seed` run |
| `CHANGE:` | UA or IP changed — alert sent |
| `SILENT:` | Change detected but filtered by `ALERT_MODE` |
| `SUPPRESSED:` | Change matched a rule in `suppress.conf` |
| `OCTET CHANGE IGNORED:` | IP changed within the ignored octet range |
| `DIGEST:` | New device digest was sent |
| `CLEANUP:` | Weekly stale device removal ran |
