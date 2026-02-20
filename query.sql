SELECT
    rs.from_num,
    rs.to_domain,
    INET_NTOA(rs.sipcallerip) AS device_ip,
    cu.ua AS current_ua,
    COALESCE(d.last_ua, 'NONE') AS known_ua,
    COALESCE(d.contact_ip, 'NONE') AS known_ip,
    CASE WHEN d.from_num IS NULL THEN 'new' ELSE 'changed' END AS change_type
FROM (
    SELECT r1.from_num, r1.to_domain, r1.sipcallerip, r1.ua_id
    FROM voipmonitor.register_state r1
    INNER JOIN (
        -- FIX: added LIMIT 1 via MAX(created_at) subquery to prevent
        -- duplicate rows when two registrations land in the same second
        SELECT from_num, to_domain, MAX(created_at) AS max_created
        FROM voipmonitor.register_state
        WHERE state = 1
          AND created_at >= NOW() - INTERVAL LOOKBACK_MINUTES MINUTE
        GROUP BY from_num, to_domain
    ) r2 ON r1.from_num = r2.from_num
         AND r1.to_domain = r2.to_domain
         AND r1.created_at = r2.max_created
    WHERE r1.state = 1
    GROUP BY r1.from_num, r1.to_domain
) rs
LEFT JOIN voipmonitor.cdr_ua cu ON cu.id = rs.ua_id
LEFT JOIN ua_monitor.device_ua d
       ON d.from_num = rs.from_num
      AND d.domain = rs.to_domain
WHERE cu.ua IS NOT NULL
  AND (
      d.from_num IS NULL
      OR d.last_ua != cu.ua
      OR d.contact_ip != INET_NTOA(rs.sipcallerip)
  );
