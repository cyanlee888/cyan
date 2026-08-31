-- Dino English 用户关键里程碑完成时长分布。
-- 统一锚点：设备首次 first_open；GA4 里程碑按设备去重，支付按生产成功账号去重。
-- 登录 / 注册完成：login_result 或 signup_result 任一成功。
-- 首课开始 / 完成：沿用核心看板的 6 节体验课、新手引导课与足球课集合。
-- 支付完成：payment_order.status=SUCCESS、env_type=PRODUCTION，完成时间使用 paid_at。

DECLARE start_ts TIMESTAMP DEFAULT TIMESTAMP '2026-07-10 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-31 03:01:24+00';
DECLARE daily_max_suffix STRING DEFAULT (
  SELECT MAX(REGEXP_EXTRACT(table_name, r'^events_(\d{8})$'))
  FROM `dino-english-497507.analytics_538991439.INFORMATION_SCHEMA.TABLES`
  WHERE REGEXP_CONTAINS(table_name, r'^events_\d{8}$')
);

WITH raw_base AS (
  SELECT
    event_timestamp,
    event_name,
    user_pseudo_id,
    user_id,
    platform,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN FORMAT_TIMESTAMP('%Y%m%d', start_ts) AND daily_max_suffix
    AND event_timestamp < UNIX_MICROS(cutoff)

  UNION ALL

  SELECT
    event_timestamp,
    event_name,
    user_pseudo_id,
    user_id,
    platform,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX > daily_max_suffix
    AND _TABLE_SUFFIX <= FORMAT_TIMESTAMP('%Y%m%d', cutoff)
    AND event_timestamp < UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE LOWER((
    SELECT up.value.string_value
    FROM UNNEST(user_properties) up
    WHERE up.key = 'user_type'
  )) = 'test'
),
events AS (
  SELECT
    r.event_timestamp,
    r.event_name,
    r.user_pseudo_id,
    r.user_id,
    r.platform,
    r.country,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'),
      r.event_name
    )) AS anchor,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS success_value,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')) AS result_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.user_pseudo_id IS NOT NULL
),
first_opens AS (
  SELECT
    platform,
    user_pseudo_id,
    ARRAY_AGG(
      STRUCT(event_timestamp AS first_open_ts, country AS first_open_country)
      ORDER BY event_timestamp
      LIMIT 1
    )[OFFSET(0)] AS first_open
  FROM events
  WHERE event_name = 'first_open'
    AND event_timestamp >= UNIX_MICROS(start_ts)
  GROUP BY platform, user_pseudo_id
),
auth_milestones AS (
  SELECT
    f.platform,
    f.user_pseudo_id,
    f.first_open.first_open_ts,
    MIN(e.event_timestamp) AS milestone_ts
  FROM first_opens f
  JOIN events e USING (platform, user_pseudo_id)
  WHERE e.event_timestamp >= f.first_open.first_open_ts
    AND e.anchor IN ('login_result', 'signup_result')
    AND e.success_value IN ('true', '1', 'success')
  GROUP BY 1, 2, 3
),
first_lesson_starts AS (
  SELECT
    f.platform,
    f.user_pseudo_id,
    f.first_open.first_open_ts,
    ARRAY_AGG(
      STRUCT(e.event_timestamp AS milestone_ts, e.lesson_id AS lesson_id)
      ORDER BY e.event_timestamp
      LIMIT 1
    )[OFFSET(0)] AS first_lesson
  FROM first_opens f
  JOIN events e USING (platform, user_pseudo_id)
  WHERE e.event_timestamp >= f.first_open.first_open_ts
    AND e.anchor = 'class_lesson_start'
    AND e.lesson_id IN ('732', '1615', '734', '733', '1613', '1614', '1661', '1616')
  GROUP BY 1, 2, 3
),
first_lesson_completions AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    s.first_open_ts,
    MIN(e.event_timestamp) AS milestone_ts
  FROM first_lesson_starts s
  JOIN events e USING (platform, user_pseudo_id)
  WHERE e.event_timestamp >= s.first_lesson.milestone_ts
    AND (
      (
        e.anchor = 'class_lesson_end'
        AND e.lesson_id = s.first_lesson.lesson_id
        AND e.result_value = 'complete'
      )
      OR (
        s.first_lesson.lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
        AND e.anchor = 'trial_lesson_complete'
      )
    )
  GROUP BY 1, 2, 3
),
test_user_ids AS (
  SELECT DISTINCT r.user_id
  FROM raw_base r
  JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE r.user_id IS NOT NULL
),
production_success AS (
  SELECT
    CAST(o.user_id AS STRING) AS user_id,
    MIN(o.paid_at) AS milestone_ts
  FROM `dino-english-497507.de_ods.payment_order` o
  LEFT JOIN test_user_ids t ON CAST(o.user_id AS STRING) = t.user_id
  WHERE o.app_code = 'DINO_ENGLISH'
    AND o.status = 'SUCCESS'
    AND o.env_type = 'PRODUCTION'
    AND o.paid_at >= start_ts
    AND o.paid_at < cutoff
    AND t.user_id IS NULL
  GROUP BY 1
),
user_device_links AS (
  SELECT
    e.user_id,
    f.platform,
    f.user_pseudo_id,
    f.first_open.first_open_ts,
    MIN(e.event_timestamp) AS first_link_ts
  FROM first_opens f
  JOIN events e USING (platform, user_pseudo_id)
  WHERE e.user_id IS NOT NULL
    AND e.event_timestamp >= f.first_open.first_open_ts
  GROUP BY 1, 2, 3, 4
),
payment_anchors AS (
  SELECT
    p.user_id,
    p.milestone_ts,
    ARRAY_AGG(
      STRUCT(l.platform, l.user_pseudo_id, l.first_open_ts)
      ORDER BY l.first_open_ts
      LIMIT 1
    )[SAFE_OFFSET(0)] AS anchor_device
  FROM production_success p
  JOIN user_device_links l
    ON l.user_id = p.user_id
   AND l.first_link_ts <= UNIX_MICROS(p.milestone_ts)
   AND l.first_open_ts <= UNIX_MICROS(p.milestone_ts)
  GROUP BY 1, 2
),
device_milestones AS (
  SELECT
    platform,
    CONCAT(platform, ':', user_pseudo_id) AS entity_id,
    'auth_complete' AS milestone_key,
    DIV(milestone_ts - first_open_ts, 1000000) AS duration_seconds
  FROM auth_milestones

  UNION ALL

  SELECT
    platform,
    CONCAT(platform, ':', user_pseudo_id),
    'lesson_start',
    DIV(first_lesson.milestone_ts - first_open_ts, 1000000)
  FROM first_lesson_starts

  UNION ALL

  SELECT
    platform,
    CONCAT(platform, ':', user_pseudo_id),
    'lesson_complete',
    DIV(milestone_ts - first_open_ts, 1000000)
  FROM first_lesson_completions
),
payment_milestones AS (
  SELECT
    anchor_device.platform AS platform,
    CONCAT('USER:', user_id) AS entity_id,
    'payment' AS milestone_key,
    TIMESTAMP_DIFF(milestone_ts, TIMESTAMP_MICROS(anchor_device.first_open_ts), SECOND) AS duration_seconds
  FROM payment_anchors
  WHERE anchor_device IS NOT NULL
),
milestones AS (
  SELECT * FROM device_milestones WHERE duration_seconds >= 0
  UNION ALL
  SELECT * FROM payment_milestones WHERE duration_seconds >= 0
),
milestone_scopes AS (
  SELECT LOWER(platform) AS platform_scope, entity_id, milestone_key, duration_seconds
  FROM milestones
  WHERE platform IN ('ANDROID', 'IOS')

  UNION ALL

  SELECT 'all', entity_id, milestone_key, duration_seconds
  FROM milestones
  WHERE platform IN ('ANDROID', 'IOS')
),
device_population AS (
  SELECT LOWER(platform) AS platform_scope, COUNT(*) AS population_entities
  FROM first_opens
  WHERE platform IN ('ANDROID', 'IOS')
  GROUP BY 1

  UNION ALL

  SELECT 'all', COUNT(*)
  FROM first_opens
  WHERE platform IN ('ANDROID', 'IOS')
),
payment_population AS (
  SELECT LOWER(anchor_device.platform) AS platform_scope, COUNT(*) AS population_entities
  FROM payment_anchors
  WHERE anchor_device IS NOT NULL
    AND anchor_device.platform IN ('ANDROID', 'IOS')
  GROUP BY 1

  UNION ALL

  SELECT 'all', COUNT(*)
  FROM payment_anchors
  WHERE anchor_device IS NOT NULL
    AND anchor_device.platform IN ('ANDROID', 'IOS')
),
population AS (
  SELECT d.platform_scope, k AS milestone_key, d.population_entities
  FROM device_population d
  CROSS JOIN UNNEST(['auth_complete', 'lesson_start', 'lesson_complete']) AS k

  UNION ALL

  SELECT platform_scope, 'payment', population_entities
  FROM payment_population
),
summaries AS (
  SELECT
    p.platform_scope,
    p.milestone_key,
    p.population_entities,
    COUNT(m.entity_id) AS sample_entities,
    APPROX_QUANTILES(m.duration_seconds, 100)[OFFSET(50)] AS p50_seconds,
    APPROX_QUANTILES(m.duration_seconds, 100)[OFFSET(75)] AS p75_seconds,
    APPROX_QUANTILES(m.duration_seconds, 100)[OFFSET(90)] AS p90_seconds
  FROM population p
  LEFT JOIN milestone_scopes m USING (platform_scope, milestone_key)
  GROUP BY 1, 2, 3
),
buckets AS (
  SELECT * FROM UNNEST([
    STRUCT(1 AS bucket_order, '<1m' AS bucket_key, '1 分钟内' AS bucket_label, 0 AS lower_seconds, 60 AS upper_seconds),
    (2, '1_3m', '1–3 分钟', 60, 180),
    (3, '3_5m', '3–5 分钟', 180, 300),
    (4, '5_10m', '5–10 分钟', 300, 600),
    (5, '10_30m', '10–30 分钟', 600, 1800),
    (6, '30_60m', '30–60 分钟', 1800, 3600),
    (7, '1_6h', '1–6 小时', 3600, 21600),
    (8, '6_24h', '6–24 小时', 21600, 86400),
    (9, '1_3d', '1–3 天', 86400, 259200),
    (10, '3_7d', '3–7 天', 259200, 604800),
    (11, '7d_plus', '7 天以上', 604800, NULL)
  ])
),
bucket_counts AS (
  SELECT
    s.platform_scope,
    s.milestone_key,
    b.bucket_order,
    b.bucket_key,
    b.bucket_label,
    COUNTIF(
      m.duration_seconds >= b.lower_seconds
      AND (b.upper_seconds IS NULL OR m.duration_seconds < b.upper_seconds)
    ) AS bucket_entities
  FROM summaries s
  CROSS JOIN buckets b
  LEFT JOIN milestone_scopes m USING (platform_scope, milestone_key)
  GROUP BY 1, 2, 3, 4, 5
),
payment_source_counts AS (
  SELECT
    'all' AS platform_scope,
    COUNT(*) AS production_success_accounts,
    COUNTIF(a.anchor_device IS NOT NULL) AS mapped_accounts
  FROM production_success p
  LEFT JOIN payment_anchors a USING (user_id, milestone_ts)
)
SELECT
  'summary' AS row_type,
  s.platform_scope,
  s.milestone_key,
  0 AS bucket_order,
  'summary' AS bucket_key,
  '汇总' AS bucket_label,
  s.sample_entities AS entities,
  s.population_entities,
  100.0 AS share_pct,
  s.p50_seconds,
  s.p75_seconds,
  s.p90_seconds,
  IF(s.platform_scope = 'all' AND s.milestone_key = 'payment', p.production_success_accounts, NULL) AS source_entities
FROM summaries s
LEFT JOIN payment_source_counts p ON TRUE

UNION ALL

SELECT
  'bucket',
  b.platform_scope,
  b.milestone_key,
  b.bucket_order,
  b.bucket_key,
  b.bucket_label,
  b.bucket_entities,
  s.population_entities,
  ROUND(SAFE_DIVIDE(b.bucket_entities, s.sample_entities) * 100, 2),
  s.p50_seconds,
  s.p75_seconds,
  s.p90_seconds,
  IF(b.platform_scope = 'all' AND b.milestone_key = 'payment', p.production_success_accounts, NULL)
FROM bucket_counts b
JOIN summaries s USING (platform_scope, milestone_key)
LEFT JOIN payment_source_counts p ON TRUE
ORDER BY
  CASE platform_scope WHEN 'all' THEN 0 WHEN 'android' THEN 1 ELSE 2 END,
  CASE milestone_key WHEN 'auth_complete' THEN 1 WHEN 'lesson_start' THEN 2 WHEN 'lesson_complete' THEN 3 ELSE 4 END,
  CASE row_type WHEN 'summary' THEN 0 ELSE 1 END,
  bucket_order;
