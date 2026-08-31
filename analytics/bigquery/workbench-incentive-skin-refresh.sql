-- 详细数据工作台 · 激励模块 · 皮肤行为观测（GA4，只读）。
-- App：Dino AI / com.prime.dino.english。
-- 任一事件出现 user_properties.user_type=test 的设备从全窗排除。
-- 时间：UTC；与当前工作台统一截点 2026-08-31 03:01:24。
--
-- 业务库的“拥有 / 当前穿戴”快照由 analytics/mysql/workbench-incentive-skin-refresh.sql 查询；
-- GA4 负责 Shop / Backpack 页面触达，并审计购买、换装业务事件是否有量。

DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP('2026-08-31 03:01:24+00');

WITH raw AS (
  SELECT event_timestamp, event_date, event_name, user_pseudo_id, user_id, platform,
    event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260829'
    AND event_timestamp < UNIX_MICROS(cutoff)
  UNION ALL
  SELECT event_timestamp, event_date, event_name, user_pseudo_id, user_id, platform,
    event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260830' AND '20260831'
    AND event_timestamp < UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw
  WHERE LOWER((
    SELECT up.value.string_value
    FROM UNNEST(user_properties) up
    WHERE up.key = 'user_type'
  )) = 'test'
),
events AS (
  SELECT
    event_timestamp,
    event_name,
    user_pseudo_id,
    user_id,
    platform,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'),
      event_name
    ) AS action,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'screen_name'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'page_name'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'firebase_screen'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'firebase_screen_class'),
      ''
    ) AS surface
  FROM raw
  WHERE NOT EXISTS (
    SELECT 1 FROM test_devices t WHERE t.user_pseudo_id = raw.user_pseudo_id
  )
),
pages AS (
  SELECT
    event_timestamp,
    user_pseudo_id,
    user_id,
    platform,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(surface), r'shop') THEN 'Shop'
      WHEN REGEXP_CONTAINS(LOWER(surface), r'backpack') THEN 'Backpack'
    END AS module
  FROM events
  WHERE event_name = 'screen_view'
    AND REGEXP_CONTAINS(LOWER(surface), r'(shop|backpack)')
),
page_rows AS (
  SELECT
    'page_view' AS section,
    module AS metric,
    '全部平台' AS segment,
    COUNT(*) AS events,
    COUNT(DISTINCT user_pseudo_id) AS devices,
    COUNT(DISTINCT user_id) AS accounts,
    CAST(NULL AS FLOAT64) AS rate_pct,
    MIN(TIMESTAMP_MICROS(event_timestamp)) AS first_event_utc,
    MAX(TIMESTAMP_MICROS(event_timestamp)) AS last_event_utc
  FROM pages
  GROUP BY module

  UNION ALL

  SELECT
    'page_view',
    module,
    platform,
    COUNT(*),
    COUNT(DISTINCT user_pseudo_id),
    COUNT(DISTINCT user_id),
    NULL,
    MIN(TIMESTAMP_MICROS(event_timestamp)),
    MAX(TIMESTAMP_MICROS(event_timestamp))
  FROM pages
  GROUP BY module, platform
),
device_path AS (
  SELECT
    user_pseudo_id,
    MIN(IF(module = 'Shop', event_timestamp, NULL)) AS first_shop_ts,
    MIN(IF(module = 'Backpack', event_timestamp, NULL)) AS first_backpack_ts
  FROM pages
  GROUP BY user_pseudo_id
),
account_path AS (
  SELECT
    user_id,
    MIN(IF(module = 'Shop', event_timestamp, NULL)) AS first_shop_ts,
    MIN(IF(module = 'Backpack', event_timestamp, NULL)) AS first_backpack_ts
  FROM pages
  WHERE user_id IS NOT NULL
  GROUP BY user_id
),
path_rows AS (
  SELECT
    'audience' AS section,
    'Shop ∩ Backpack' AS metric,
    '全部平台' AS segment,
    CAST(NULL AS INT64) AS events,
    COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts IS NOT NULL) AS devices,
    (
      SELECT COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts IS NOT NULL)
      FROM account_path
    ) AS accounts,
    SAFE_MULTIPLY(
      SAFE_DIVIDE(
        COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts IS NOT NULL),
        COUNTIF(first_shop_ts IS NOT NULL)
      ),
      100
    ) AS rate_pct,
    CAST(NULL AS TIMESTAMP) AS first_event_utc,
    CAST(NULL AS TIMESTAMP) AS last_event_utc
  FROM device_path

  UNION ALL

  SELECT
    'audience',
    'Shop → Backpack（首次访问时序）',
    '全部平台',
    NULL,
    COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts > first_shop_ts),
    (
      SELECT COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts > first_shop_ts)
      FROM account_path
    ),
    SAFE_MULTIPLY(
      SAFE_DIVIDE(
        COUNTIF(first_shop_ts IS NOT NULL AND first_backpack_ts > first_shop_ts),
        COUNTIF(first_shop_ts IS NOT NULL)
      ),
      100
    ),
    NULL,
    NULL
  FROM device_path
),
expected_actions AS (
  SELECT 'shop_purchase_result' AS action
  UNION ALL SELECT 'skin_equip_result'
),
business_rows AS (
  SELECT
    'business_event' AS section,
    a.action AS metric,
    '全部平台' AS segment,
    COUNTIF(e.action = a.action) AS events,
    COUNT(DISTINCT IF(e.action = a.action, e.user_pseudo_id, NULL)) AS devices,
    COUNT(DISTINCT IF(e.action = a.action, e.user_id, NULL)) AS accounts,
    CAST(NULL AS FLOAT64) AS rate_pct,
    MIN(IF(e.action = a.action, TIMESTAMP_MICROS(e.event_timestamp), NULL)) AS first_event_utc,
    MAX(IF(e.action = a.action, TIMESTAMP_MICROS(e.event_timestamp), NULL)) AS last_event_utc
  FROM expected_actions a
  LEFT JOIN events e ON e.action = a.action
  GROUP BY a.action
)
SELECT * FROM page_rows
UNION ALL SELECT * FROM path_rows
UNION ALL SELECT * FROM business_rows
ORDER BY
  CASE section WHEN 'page_view' THEN 1 WHEN 'audience' THEN 2 ELSE 3 END,
  metric,
  CASE segment WHEN '全部平台' THEN 1 WHEN 'ANDROID' THEN 2 ELSE 3 END;
