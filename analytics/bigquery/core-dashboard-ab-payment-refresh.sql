-- Map stable non-test Android + iOS A/B devices to signed-in user_id, then read production payment truth.
-- Daily GA4 export is authoritative through 2026-08-25; intraday fills 2026-08-26~27.
DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-27 03:02:06+00';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260825'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260826' AND '20260827'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
base AS (
  SELECT r.* EXCEPT(user_properties)
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
),
events AS (
  SELECT
    event_timestamp, user_pseudo_id, user_id, platform, country, event_name,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id') AS event_id,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'content_id') AS content_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'channel')) AS channel
  FROM base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
),
device_groups AS (
  SELECT
    platform,
    user_pseudo_id,
    MIN(event_timestamp) AS first_assigned_at,
    ARRAY_AGG(STRUCT(channel, country) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_assignment,
    COUNT(DISTINCT channel) AS channel_count
  FROM events
  WHERE platform IN ('ANDROID', 'IOS')
    AND event_name = 'trigger'
    AND event_id = 'experiment_group_assign'
    AND content_id = 'conv_funnel_v1'
  GROUP BY platform, user_pseudo_id
),
stable AS (
  SELECT * FROM device_groups
  WHERE first_assigned_at >= UNIX_MICROS(experiment_start)
    AND channel_count = 1
    AND first_assignment.channel IN ('a','b')
),
uid_candidates AS (
  SELECT
    s.platform,
    s.first_assignment.channel AS experiment_group,
    s.first_assignment.country AS assignment_country,
    s.first_assigned_at,
    e.user_id
  FROM stable s
  JOIN events e
    ON e.user_pseudo_id = s.user_pseudo_id
   AND e.platform = s.platform
  WHERE e.event_timestamp >= s.first_assigned_at
    AND e.user_id IS NOT NULL
),
uid_map AS (
  SELECT platform, experiment_group, assignment_country, user_id
  FROM uid_candidates
  QUALIFY ROW_NUMBER() OVER (
    -- Keep the detailed workbench's platform × experiment-group attribution.
    -- Preserve the detailed workbench's attribution definition. Cross-group
    -- overlap is a separate experiment-quality diagnostic rather than silently
    -- changing the KPI definition in the core dashboard.
    PARTITION BY platform, experiment_group, user_id
    ORDER BY first_assigned_at
  ) = 1
),
orders AS (
  SELECT
    m.platform,
    m.experiment_group,
    m.assignment_country,
    m.user_id,
    o.order_no,
    o.status,
    o.env_type
  FROM uid_map m
  JOIN `dino-english-497507.de_ods.payment_order` o
    ON CAST(o.user_id AS STRING) = m.user_id
  WHERE o.created_at >= experiment_start AND o.created_at < cutoff
),
stable_labeled AS (
  SELECT
    platform,
    first_assignment.channel AS experiment_group,
    CASE first_assignment.country
      WHEN 'Vietnam' THEN 'vn'
      WHEN 'South Korea' THEN 'kr'
      WHEN 'Saudi Arabia' THEN 'sa'
      WHEN 'Malaysia' THEN 'my'
      WHEN 'Indonesia' THEN 'id'
      ELSE 'other'
    END AS country_key,
    user_pseudo_id
  FROM stable
),
orders_labeled AS (
  SELECT
    platform,
    experiment_group,
    CASE assignment_country
      WHEN 'Vietnam' THEN 'vn'
      WHEN 'South Korea' THEN 'kr'
      WHEN 'Saudi Arabia' THEN 'sa'
      WHEN 'Malaysia' THEN 'my'
      WHEN 'Indonesia' THEN 'id'
      ELSE 'other'
    END AS country_key,
    user_id,
    order_no,
    status,
    env_type
  FROM orders
),
assignment_scope AS (
  SELECT platform AS platform_scope, experiment_group, country_key, CONCAT(platform, ':', user_pseudo_id) AS assignment_id
  FROM stable_labeled
  UNION ALL
  SELECT platform, experiment_group, 'all', CONCAT(platform, ':', user_pseudo_id)
  FROM stable_labeled
  UNION ALL
  SELECT 'ANDROID_IOS', experiment_group, country_key, CONCAT(platform, ':', user_pseudo_id)
  FROM stable_labeled
  UNION ALL
  SELECT 'ANDROID_IOS', experiment_group, 'all', CONCAT(platform, ':', user_pseudo_id)
  FROM stable_labeled
),
payment_scope AS (
  SELECT platform AS platform_scope, experiment_group, country_key, user_id, order_no, status, env_type
  FROM orders_labeled
  UNION ALL
  SELECT platform, experiment_group, 'all', user_id, order_no, status, env_type
  FROM orders_labeled
  UNION ALL
  SELECT 'ANDROID_IOS', experiment_group, country_key, user_id, order_no, status, env_type
  FROM orders_labeled
  UNION ALL
  SELECT 'ANDROID_IOS', experiment_group, 'all', user_id, order_no, status, env_type
  FROM orders_labeled
),
assignment_counts AS (
  SELECT platform_scope, experiment_group, country_key, COUNT(DISTINCT assignment_id) AS assigned_devices
  FROM assignment_scope
  GROUP BY platform_scope, experiment_group, country_key
),
payment_counts AS (
  SELECT
    platform_scope,
    experiment_group,
    country_key,
    COUNT(DISTINCT IF(status = 'PENDING', order_no, NULL)) AS pending_orders,
    COUNT(DISTINCT IF(status = 'SUCCESS' AND env_type = 'PRODUCTION', user_id, NULL)) AS production_success_users,
    COUNT(DISTINCT IF(status = 'SUCCESS' AND env_type = 'PRODUCTION', order_no, NULL)) AS production_success_orders,
    COUNT(DISTINCT IF(status = 'SUCCESS' AND env_type = 'SANDBOX', order_no, NULL)) AS sandbox_success_orders
  FROM payment_scope
  GROUP BY platform_scope, experiment_group, country_key
)
SELECT
  a.platform_scope,
  a.experiment_group,
  a.country_key,
  a.assigned_devices,
  COALESCE(p.pending_orders, 0) AS pending_orders,
  COALESCE(p.production_success_users, 0) AS production_success_users,
  COALESCE(p.production_success_orders, 0) AS production_success_orders,
  COALESCE(p.sandbox_success_orders, 0) AS sandbox_success_orders
FROM assignment_counts a
LEFT JOIN payment_counts p USING (platform_scope, experiment_group, country_key)
WHERE a.country_key IN ('all', 'vn', 'kr', 'sa', 'my', 'id')
ORDER BY platform_scope, experiment_group, country_key;
