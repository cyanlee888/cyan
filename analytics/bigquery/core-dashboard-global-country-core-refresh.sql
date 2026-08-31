-- Global country slices for signed-in core modules, payment, and the user-country map.
-- Country for an account is the geo.country of its earliest mapped GA4 device event
-- in the reporting window. First-open funnel/retention use first_open country separately.

DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-31 03:01:24+00';

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS period_key, TIMESTAMP '2026-07-10 00:00:00+00' AS start_ts, cutoff AS end_ts),
    ('w1', TIMESTAMP '2026-07-10 00:00:00+00', TIMESTAMP '2026-07-17 00:00:00+00'),
    ('w2', TIMESTAMP '2026-07-17 00:00:00+00', TIMESTAMP '2026-07-24 00:00:00+00'),
    ('w3', TIMESTAMP '2026-07-24 00:00:00+00', TIMESTAMP '2026-07-31 00:00:00+00'),
    ('w4', TIMESTAMP '2026-07-31 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', TIMESTAMP '2026-08-21 00:00:00+00'),
    ('w7', TIMESTAMP '2026-08-21 00:00:00+00', cutoff)
  ])
),
country_targets AS (
  SELECT * FROM UNNEST(['all','vn','kr','sa','my','id','th']) AS country_key
),
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260829'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260830' AND '20260831'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
events AS (
  SELECT
    r.event_timestamp,
    r.event_name,
    r.user_pseudo_id,
    r.user_id,
    r.platform,
    CASE r.country
      WHEN 'Vietnam' THEN 'vn'
      WHEN 'South Korea' THEN 'kr'
      WHEN 'Saudi Arabia' THEN 'sa'
      WHEN 'Malaysia' THEN 'my'
      WHEN 'Indonesia' THEN 'id'
      WHEN 'Thailand' THEN 'th'
      ELSE 'other'
    END AS event_country_key,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'), r.event_name) AS anchor,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'dino_step') AS dino_step
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
device_geo AS (
  SELECT
    platform,
    user_pseudo_id,
    ARRAY_AGG(STRUCT(event_timestamp AS first_event_ts, event_country_key AS country_key) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_geo
  FROM events
  GROUP BY platform, user_pseudo_id
),
user_geo AS (
  SELECT
    e.user_id,
    ARRAY_AGG(STRUCT(e.event_timestamp AS mapped_ts, d.first_geo.country_key AS country_key) ORDER BY e.event_timestamp LIMIT 1)[OFFSET(0)] AS first_geo
  FROM events e
  JOIN device_geo d USING (platform, user_pseudo_id)
  WHERE e.user_id IS NOT NULL
  GROUP BY e.user_id
),
period_events AS (
  SELECT p.period_key, e.*, u.first_geo.country_key AS country_key
  FROM periods p
  JOIN events e
    ON e.event_timestamp >= UNIX_MICROS(p.start_ts)
   AND e.event_timestamp < UNIX_MICROS(p.end_ts)
  LEFT JOIN user_geo u USING (user_id)
),
core_country AS (
  SELECT
    period_key,
    country_key,
    COUNT(DISTINCT user_id) AS logged_in_users,
    COUNT(DISTINCT IF(anchor = 'class_lesson_start', user_id, NULL)) AS class_users,
    COUNT(DISTINCT IF(
      (anchor = 'dino_assistant_progress' AND dino_step = 'session_start') OR anchor = 'dino_session_start',
      user_id,
      NULL
    )) AS dino_users
  FROM period_events
  WHERE user_id IS NOT NULL
    AND country_key IN ('vn','kr','sa','my','id','th')
  GROUP BY period_key, country_key
),
core_all AS (
  SELECT
    period_key,
    'all' AS country_key,
    COUNT(DISTINCT user_id) AS logged_in_users,
    COUNT(DISTINCT IF(anchor = 'class_lesson_start', user_id, NULL)) AS class_users,
    COUNT(DISTINCT IF(
      (anchor = 'dino_assistant_progress' AND dino_step = 'session_start') OR anchor = 'dino_session_start',
      user_id,
      NULL
    )) AS dino_users
  FROM period_events
  WHERE user_id IS NOT NULL
  GROUP BY period_key
),
core AS (
  SELECT * FROM core_country
  UNION ALL
  SELECT * FROM core_all
),
test_user_ids AS (
  SELECT DISTINCT r.user_id
  FROM raw_base r
  JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE r.user_id IS NOT NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
orders AS (
  SELECT o.*
  FROM `dino-english-497507.de_ods.payment_order` o
  LEFT JOIN test_user_ids t ON CAST(o.user_id AS STRING) = t.user_id
  WHERE o.created_at >= TIMESTAMP '2026-07-10 00:00:00+00'
    AND o.created_at < cutoff
    AND t.user_id IS NULL
),
payment_country AS (
  SELECT
    p.period_key,
    u.first_geo.country_key AS country_key,
    COUNT(*) AS orders,
    COUNT(DISTINCT o.user_id) AS users,
    COUNTIF(o.status = 'PENDING') AS pending,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION') AS production_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(o.status = 'FAILED') AS failed,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.platform = 'APPLE') AS apple_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.platform = 'GOOGLE') AS google_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'WEEK') AS week_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'MONTH') AS month_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'YEAR') AS year_success
  FROM periods p
  JOIN orders o ON o.created_at >= p.start_ts AND o.created_at < p.end_ts
  JOIN user_geo u ON CAST(o.user_id AS STRING) = u.user_id
  WHERE u.first_geo.country_key IN ('vn','kr','sa','my','id','th')
  GROUP BY p.period_key, country_key
),
payment_all AS (
  SELECT
    p.period_key,
    'all' AS country_key,
    COUNT(*) AS orders,
    COUNT(DISTINCT o.user_id) AS users,
    COUNTIF(o.status = 'PENDING') AS pending,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION') AS production_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(o.status = 'FAILED') AS failed,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.platform = 'APPLE') AS apple_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.platform = 'GOOGLE') AS google_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'WEEK') AS week_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'MONTH') AS month_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.billing_period = 'YEAR') AS year_success
  FROM periods p
  JOIN orders o ON o.created_at >= p.start_ts AND o.created_at < p.end_ts
  GROUP BY p.period_key
),
payment AS (
  SELECT * FROM payment_country
  UNION ALL
  SELECT * FROM payment_all
),
grid AS (
  SELECT p.period_key, c.country_key
  FROM periods p CROSS JOIN country_targets c
),
metric_rows AS (
  SELECT
    'metric' AS row_type,
    g.period_key,
    g.country_key,
    CAST(NULL AS STRING) AS user_id,
    TO_JSON_STRING(STRUCT(
      COALESCE(c.logged_in_users,0) AS logged_in_users,
      COALESCE(c.class_users,0) AS class_users,
      COALESCE(c.dino_users,0) AS dino_users,
      COALESCE(p.orders,0) AS orders,
      COALESCE(p.users,0) AS users,
      COALESCE(p.pending,0) AS pending,
      COALESCE(p.production_success,0) AS production_success,
      COALESCE(p.sandbox_success,0) AS sandbox_success,
      COALESCE(p.failed,0) AS failed,
      COALESCE(p.apple_success,0) AS apple_success,
      COALESCE(p.google_success,0) AS google_success,
      COALESCE(p.week_success,0) AS week_success,
      COALESCE(p.month_success,0) AS month_success,
      COALESCE(p.year_success,0) AS year_success
    )) AS payload
  FROM grid g
  LEFT JOIN core c USING (period_key, country_key)
  LEFT JOIN payment p USING (period_key, country_key)
),
user_rows AS (
  SELECT
    'user_map' AS row_type,
    'all' AS period_key,
    first_geo.country_key AS country_key,
    user_id,
    CAST(NULL AS STRING) AS payload
  FROM user_geo
  WHERE first_geo.country_key IN ('vn','kr','sa','my','id','th')
)
SELECT * FROM metric_rows
UNION ALL
SELECT * FROM user_rows
ORDER BY row_type, period_key, country_key, user_id;
