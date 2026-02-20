-- UA Monitor Database Setup
-- Run as a MySQL root or privileged user
-- Update the password before running

CREATE DATABASE IF NOT EXISTS ua_monitor;

-- Main device tracking table
CREATE TABLE IF NOT EXISTS ua_monitor.device_ua (
    from_num     VARCHAR(100) NOT NULL,
    domain       VARCHAR(150) NOT NULL DEFAULT '',
    contact_ip   VARCHAR(64),
    last_ua      TEXT,
    first_seen   DATETIME,
    last_seen    DATETIME,
    PRIMARY KEY (from_num, domain)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Queue for new device digest batching
CREATE TABLE IF NOT EXISTS ua_monitor.new_device_queue (
    id          INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    from_num    VARCHAR(100),
    domain      VARCHAR(150),
    contact_ip  VARCHAR(64),
    ua          TEXT,
    detected_at DATETIME
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Tracks when the last new device digest was sent
CREATE TABLE IF NOT EXISTS ua_monitor.digest_log (
    id      INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    sent_at DATETIME
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Create monitoring user (change the password)
CREATE USER IF NOT EXISTS 'ua_monitor'@'localhost' IDENTIFIED BY 'yourpassword';

-- Read access to voipmonitor tables
GRANT SELECT ON voipmonitor.register_state TO 'ua_monitor'@'localhost';
GRANT SELECT ON voipmonitor.cdr_ua TO 'ua_monitor'@'localhost';

-- Full access to tracking database
GRANT ALL ON ua_monitor.* TO 'ua_monitor'@'localhost';

FLUSH PRIVILEGES;
