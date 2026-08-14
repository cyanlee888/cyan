-- 核心指标观测工作台：支付触达、发起与生产订单结算刷新。
-- SQL 仅保存在本地分析目录，不进入公开 HTML。
-- GA4 设备和由其映射出的支付账号均排除 user_type=test。
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-14 09:01:00+00';

CREATE TEMP TABLE ga4_events AS
WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260812'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260813' AND '20260814'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
base AS (
  SELECT r.* EXCEPT(user_properties)
  FROM raw_base r
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
)
SELECT
  event_timestamp,
  event_name,
  user_pseudo_id,
  user_id,
  COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'button_id'),
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'),
    event_name
  ) AS action,
  COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'subscription_source'),
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'source'),
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'trigger_source')
  ) AS source,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'order_id') AS order_id,
  COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
    CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING)
  ) AS is_success,
  COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'reason'),
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'failed_reason')
  ) AS result_reason
FROM base
WHERE event_timestamp < UNIX_MICROS(cutoff);

CREATE TEMP TABLE orders AS
WITH identity_rows AS (
  SELECT event_timestamp, user_pseudo_id, user_id,
    LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) AS user_type
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260812'
  UNION ALL
  SELECT event_timestamp, user_pseudo_id, user_id,
    LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) AS user_type
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260813' AND '20260814'
),
test_ids AS (
  SELECT DISTINCT user_pseudo_id
  FROM identity_rows
  WHERE event_timestamp < UNIX_MICROS(cutoff) AND user_type = 'test'
),
test_user_ids AS (
  SELECT DISTINCT r.user_id
  FROM identity_rows r
  JOIN test_ids t USING (user_pseudo_id)
  WHERE r.event_timestamp < UNIX_MICROS(cutoff) AND r.user_id IS NOT NULL
)
SELECT o.*
FROM `dino-english-497507.de_ods.payment_order` o
LEFT JOIN test_user_ids t ON CAST(o.user_id AS STRING) = t.user_id
WHERE o.created_at >= TIMESTAMP '2026-07-10 00:00:00+00'
  AND o.created_at < cutoff
  AND t.user_id IS NULL;

WITH surface_rows AS (
  SELECT
    IF(action IN ('subscription', 'subscription_page_view'), 'paywall', 'discount') AS surface,
    COALESCE(NULLIF(source, ''), '__missing__') AS source,
    COUNT(*) AS exposures,
    COUNT(DISTINCT user_pseudo_id) AS users
  FROM ga4_events
  WHERE action IN ('subscription', 'subscription_page_view', 'discount_offer', 'discount_offer_view')
  GROUP BY 1, 2
),
surface_totals AS (
  SELECT
    IF(action IN ('subscription', 'subscription_page_view'), 'paywall', 'discount') AS surface,
    COUNT(*) AS exposures,
    COUNT(DISTINCT user_pseudo_id) AS users
  FROM ga4_events
  WHERE action IN ('subscription', 'subscription_page_view', 'discount_offer', 'discount_offer_view')
  GROUP BY 1
),
checkout_rows AS (
  SELECT
    COALESCE(NULLIF(source, ''), '__missing__') AS source,
    COUNT(DISTINCT order_id) AS order_ids,
    COUNT(DISTINCT user_pseudo_id) AS users,
    COUNT(*) AS events
  FROM ga4_events
  WHERE action = 'subscription_checkout_start'
  GROUP BY 1
),
action_stats AS (
  SELECT action AS row_key, COUNT(*) AS events, COUNT(DISTINCT user_pseudo_id) AS users
  FROM ga4_events
  WHERE REGEXP_CONTAINS(LOWER(action), r'(purchase|checkout)')
  GROUP BY 1
),
offer_devices AS (
  SELECT user_pseudo_id, MIN(event_timestamp) AS offer_ts
  FROM ga4_events
  WHERE action IN ('subscription', 'subscription_page_view', 'discount_offer', 'discount_offer_view')
    AND user_pseudo_id IS NOT NULL
  GROUP BY 1
),
checkout_after_offer AS (
  SELECT o.user_pseudo_id, MIN(e.event_timestamp) AS checkout_ts
  FROM offer_devices o
  JOIN ga4_events e USING (user_pseudo_id)
  WHERE e.action = 'subscription_checkout_start'
    AND e.event_timestamp >= o.offer_ts
  GROUP BY 1
),
result_after_checkout AS (
  SELECT c.user_pseudo_id, MIN(e.event_timestamp) AS result_ts
  FROM checkout_after_offer c
  JOIN ga4_events e USING (user_pseudo_id)
  WHERE e.action = 'subscription_checkout_result'
    AND e.event_timestamp >= c.checkout_ts
  GROUP BY 1
),
purchase_after_checkout AS (
  SELECT c.user_pseudo_id, MIN(e.event_timestamp) AS purchase_ts
  FROM checkout_after_offer c
  JOIN ga4_events e USING (user_pseudo_id)
  WHERE e.action = 'purchase'
    AND e.event_timestamp >= c.checkout_ts
  GROUP BY 1
),
checkout_starts AS (
  SELECT order_id, MIN(event_timestamp) AS start_ts
  FROM ga4_events
  WHERE action = 'subscription_checkout_start'
    AND order_id IS NOT NULL
  GROUP BY 1
),
latest_checkout_result AS (
  SELECT
    s.order_id,
    e.is_success,
    e.result_reason
  FROM checkout_starts s
  JOIN ga4_events e
    ON e.order_id = s.order_id
   AND e.action = 'subscription_checkout_result'
   AND e.event_timestamp >= s.start_ts
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.order_id ORDER BY e.event_timestamp DESC) = 1
),
order_outcome AS (
  SELECT
    CASE
      WHEN s.order_id IS NULL THEN 'unmatched_checkout_start'
      WHEN r.order_id IS NULL THEN 'checkout_start_no_result'
      WHEN r.is_success = 'false' THEN 'client_fail_or_cancel'
      WHEN r.is_success = 'true' THEN 'client_success'
      ELSE 'result_missing_is_success'
    END AS row_key,
    COUNT(*) AS orders,
    COUNTIF(o.status = 'PENDING') AS pending,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION') AS production_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(o.status = 'FAILED') AS failed,
    COUNTIF(o.status IN ('CANCELED', 'ABANDONED')) AS canceled_or_abandoned
  FROM orders o
  LEFT JOIN checkout_starts s ON o.order_no = s.order_id
  LEFT JOIN latest_checkout_result r ON s.order_id = r.order_id
  GROUP BY 1
),
successful_pairs AS (
  SELECT user_id, platform, MIN(created_at) AS first_success_at
  FROM orders
  WHERE status = 'SUCCESS' AND env_type = 'PRODUCTION'
  GROUP BY 1, 2
),
retry_before_success AS (
  SELECT
    s.user_id,
    s.platform,
    COUNTIF(o.status = 'PENDING' AND o.created_at < s.first_success_at) AS pending_before
  FROM successful_pairs s
  JOIN orders o USING (user_id, platform)
  GROUP BY 1, 2
),
order_source AS (
  SELECT
    COALESCE(NULLIF(subscription_source, ''), '__missing__') AS row_key,
    COUNT(*) AS orders,
    COUNT(DISTINCT user_id) AS users,
    COUNTIF(status = 'PENDING') AS pending,
    COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION') AS production_success,
    COUNTIF(status = 'SUCCESS' AND env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(status = 'FAILED') AS failed
  FROM orders
  GROUP BY 1
),
order_platform AS (
  SELECT
    COALESCE(NULLIF(platform, ''), '__missing__') AS row_key,
    COUNT(*) AS orders,
    COUNT(DISTINCT user_id) AS users,
    COUNTIF(status = 'PENDING') AS pending,
    COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION') AS production_success,
    COUNTIF(status = 'SUCCESS' AND env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(status = 'FAILED') AS failed
  FROM orders
  GROUP BY 1
),
order_period AS (
  SELECT
    COALESCE(NULLIF(billing_period, ''), '__missing__') AS row_key,
    COUNT(*) AS orders,
    COUNT(DISTINCT user_id) AS users,
    COUNTIF(status = 'PENDING') AS pending,
    COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION') AS production_success,
    COUNTIF(status = 'SUCCESS' AND env_type = 'SANDBOX') AS sandbox_success,
    COUNTIF(status = 'FAILED') AS failed
  FROM orders
  GROUP BY 1
)
SELECT 'surface_source' AS section, CONCAT(surface, '|', source) AS row_key,
  exposures AS v1, users AS v2, NULL AS v3, NULL AS v4, NULL AS v5, NULL AS v6
FROM surface_rows
UNION ALL
SELECT 'surface_total', surface, exposures, users, NULL, NULL, NULL, NULL
FROM surface_totals
UNION ALL
SELECT 'surface_total', 'any', COUNT(*), COUNT(DISTINCT user_pseudo_id), NULL, NULL, NULL, NULL
FROM ga4_events
WHERE action IN ('subscription', 'subscription_page_view', 'discount_offer', 'discount_offer_view')
UNION ALL
SELECT 'checkout_source', source, order_ids, users, events, NULL, NULL, NULL FROM checkout_rows
UNION ALL
SELECT 'action_stats', row_key, events, users, NULL, NULL, NULL, NULL FROM action_stats
UNION ALL
SELECT 'client_funnel', 'strict',
  (SELECT COUNT(*) FROM offer_devices),
  (SELECT COUNT(*) FROM checkout_after_offer),
  (SELECT COUNT(*) FROM result_after_checkout),
  (SELECT COUNT(*) FROM purchase_after_checkout),
  NULL, NULL
UNION ALL
SELECT 'order_outcome', row_key, orders, pending, production_success, sandbox_success, failed, canceled_or_abandoned
FROM order_outcome
UNION ALL
SELECT 'pending_health', 'all',
  COUNTIF(status = 'PENDING'),
  COUNTIF(status = 'PENDING' AND updated_at = created_at),
  COUNTIF(status = 'PENDING' AND created_at < TIMESTAMP_SUB(cutoff, INTERVAL 7 DAY)),
  COUNTIF(status = 'PENDING'
    AND env_type IS NULL
    AND subscription_id IS NULL
    AND payment_event_id IS NULL
    AND platform_order_id IS NULL
    AND platform_transaction_id IS NULL
    AND purchase_token_hash IS NULL
    AND paid_at IS NULL),
  NULL, NULL
FROM orders
UNION ALL
SELECT 'payment_retry_health', 'successful_pairs',
  COUNT(*), COUNTIF(pending_before > 0), SUM(pending_before), NULL, NULL, NULL
FROM retry_before_success
UNION ALL
SELECT 'order_source', row_key, orders, users, pending, production_success, sandbox_success, failed FROM order_source
UNION ALL
SELECT 'order_platform', row_key, orders, users, pending, production_success, sandbox_success, failed FROM order_platform
UNION ALL
SELECT 'order_period', row_key, orders, users, pending, production_success, sandbox_success, failed FROM order_period
UNION ALL
SELECT 'order_total', 'all', COUNT(*), COUNT(DISTINCT user_id),
  COUNTIF(status = 'PENDING'),
  COUNTIF(status = 'SUCCESS' AND env_type = 'PRODUCTION'),
  COUNTIF(status = 'SUCCESS' AND env_type = 'SANDBOX'),
  COUNTIF(status = 'FAILED')
FROM orders
ORDER BY section, v1 DESC, row_key;
