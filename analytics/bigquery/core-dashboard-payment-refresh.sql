-- Production payment truth for the same dashboard window.
-- Orders belonging to GA4 devices ever marked user_type=test are excluded by user_id mapping.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-26 03:01:46+00';

WITH raw_ga4 AS (
  SELECT event_timestamp, user_pseudo_id, user_id, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260823'
  UNION ALL
  SELECT event_timestamp, user_pseudo_id, user_id, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260824' AND '20260826'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_ga4
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
test_user_ids AS (
  SELECT DISTINCT user_id
  FROM raw_ga4
  JOIN test_devices USING (user_pseudo_id)
  WHERE event_timestamp < UNIX_MICROS(cutoff) AND user_id IS NOT NULL
),
orders AS (
  SELECT o.*
  FROM `dino-english-497507.de_ods.payment_order`
  o LEFT JOIN test_user_ids t ON CAST(o.user_id AS STRING) = t.user_id
  WHERE o.created_at >= TIMESTAMP '2026-07-10 00:00:00+00'
    AND o.created_at < cutoff
    AND t.user_id IS NULL
),
metrics AS (
  SELECT 'orders' metric, COUNT(*) value FROM orders
  UNION ALL SELECT 'users', COUNT(DISTINCT user_id) FROM orders
  UNION ALL SELECT 'pending', COUNTIF(status = 'PENDING') FROM orders
  UNION ALL SELECT 'production_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION') FROM orders
  UNION ALL SELECT 'sandbox_success', COUNTIF(status = 'SUCCESS' AND env_type = 'SANDBOX') FROM orders
  UNION ALL SELECT 'failed', COUNTIF(status = 'FAILED') FROM orders
  UNION ALL SELECT 'apple_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION' AND platform = 'APPLE') FROM orders
  UNION ALL SELECT 'google_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION' AND platform = 'GOOGLE') FROM orders
  UNION ALL SELECT 'week_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION' AND billing_period = 'WEEK') FROM orders
  UNION ALL SELECT 'month_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION' AND billing_period = 'MONTH') FROM orders
  UNION ALL SELECT 'year_success', COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION' AND billing_period = 'YEAR') FROM orders
)
SELECT metric, value FROM metrics ORDER BY metric;
