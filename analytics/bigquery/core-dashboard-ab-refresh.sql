-- Android + iOS conv_funnel_v1 refresh for the executive dashboard.
-- Cohort: first stable assignment from 2026-08-01 00:00 UTC; platform is retained as a reporting dimension.
-- Any device that reports user_properties.user_type=test is excluded before assignment and effect metrics.
DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-17 02:15:00+00';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, platform, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260817'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, platform, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260816' AND '20260817'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
base AS (
  SELECT r.event_timestamp, r.event_name, r.user_pseudo_id, r.platform, r.event_params
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
),
events AS (
  SELECT
    event_timestamp,
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_day,
    user_pseudo_id,
    platform,
    event_name,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'),
      event_name
    ) AS anchor,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'content_id') AS content_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'channel')) AS channel,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
    )) AS success_value,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')) AS result_value
  FROM base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
),
assignments AS (
  SELECT platform, user_pseudo_id, channel, event_timestamp
  FROM events
  WHERE platform IN ('ANDROID', 'IOS')
    AND event_name = 'trigger'
    AND anchor = 'experiment_group_assign'
    AND content_id = 'conv_funnel_v1'
    AND user_pseudo_id IS NOT NULL
),
device_groups AS (
  SELECT
    platform,
    user_pseudo_id,
    MIN(event_timestamp) AS first_assigned_at,
    ARRAY_AGG(channel ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_channel,
    COUNT(DISTINCT channel) AS channel_count,
    LOGICAL_OR(channel = 'fallback') AS saw_fallback
  FROM assignments
  GROUP BY platform, user_pseudo_id
),
eligible AS (
  SELECT *
  FROM device_groups
  WHERE first_assigned_at >= UNIX_MICROS(experiment_start)
),
stable AS (
  SELECT platform, user_pseudo_id, first_assigned_at, first_channel AS experiment_group
  FROM eligible
  WHERE channel_count = 1 AND first_channel IN ('a','b')
),
first_lesson_start AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    s.experiment_group,
    ARRAY_AGG(
      STRUCT(e.event_timestamp AS start_ts, e.lesson_id AS lesson_id)
      ORDER BY e.event_timestamp LIMIT 1
    )[OFFSET(0)] AS first_lesson
  FROM stable s
  JOIN events e
    ON e.platform = s.platform
   AND e.user_pseudo_id = s.user_pseudo_id
   AND e.event_timestamp >= s.first_assigned_at
  WHERE e.anchor = 'class_lesson_start'
    AND (
      (s.experiment_group = 'a' AND e.lesson_id IN ('732','1615','734','733','1613','1614','1616'))
      OR (s.experiment_group = 'b' AND e.lesson_id IN ('1661','1616'))
    )
  GROUP BY 1,2,3
),
first_lesson_metrics AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    s.experiment_group,
    TRUE AS lesson_started,
    EXISTS(
      SELECT 1
      FROM events e
      WHERE e.platform = s.platform
        AND e.user_pseudo_id = s.user_pseudo_id
        AND e.event_timestamp >= s.first_lesson.start_ts
        AND e.anchor = 'class_lesson_end'
        AND e.lesson_id = s.first_lesson.lesson_id
        AND e.result_value = 'complete'
    ) OR (
      s.first_lesson.lesson_id IN ('732','1615','734','733','1613','1614')
      AND EXISTS(
        SELECT 1
        FROM events e
        WHERE e.platform = s.platform
          AND e.user_pseudo_id = s.user_pseudo_id
          AND e.event_timestamp >= s.first_lesson.start_ts
          AND e.anchor = 'trial_lesson_complete'
      )
    ) AS lesson_completed
  FROM first_lesson_start s
),
device_metrics AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    s.experiment_group,
    s.first_assigned_at,
    DATE(TIMESTAMP_MICROS(s.first_assigned_at)) AS assignment_day,
    LOGICAL_OR(e.anchor = 'first_open') AS first_open,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'login') AS login_page,
    LOGICAL_OR(
      e.anchor = 'signup_result'
      AND e.success_value IN ('true','1','success')
      AND e.event_timestamp BETWEEN s.first_assigned_at AND s.first_assigned_at + 24 * 60 * 60 * 1000000
    ) AS registered_24h,
    LOGICAL_OR(
      e.anchor = 'signup_result'
      AND e.success_value IN ('true','1','success')
      AND e.event_timestamp >= s.first_assigned_at
    ) AS registered_rolling,
    LOGICAL_OR(COALESCE(f.lesson_started, FALSE)) AS lesson_started,
    LOGICAL_OR(COALESCE(f.lesson_completed, FALSE)) AS lesson_completed,
    LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND e.anchor = 'subscription') AS paywall_any,
    LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND e.anchor = 'subscription_checkout_start') AS checkout_any
  FROM stable s
  LEFT JOIN events e
    ON e.user_pseudo_id = s.user_pseudo_id
   AND e.platform = s.platform
  LEFT JOIN first_lesson_metrics f
    ON f.user_pseudo_id = s.user_pseudo_id
   AND f.platform = s.platform
   AND f.experiment_group = s.experiment_group
  GROUP BY 1,2,3,4,5
),
effect_by_platform AS (
  SELECT
    platform,
    experiment_group,
    COUNT(*) AS assigned,
    COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR))) AS mature_24h,
    COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR)) AND registered_24h) AS registered_24h,
    COUNTIF(registered_rolling) AS registered_rolling,
    COUNTIF(lesson_started) AS lesson_started,
    COUNTIF(lesson_completed) AS lesson_completed,
    COUNTIF(first_open) AS first_open,
    COUNTIF(login_page) AS login_page,
    COUNTIF(paywall_any) AS paywall_any,
    COUNTIF(checkout_any) AS checkout_any
  FROM device_metrics
  GROUP BY platform, experiment_group
),
effect AS (
  SELECT * FROM effect_by_platform
  UNION ALL
  SELECT
    'ALL' AS platform,
    experiment_group,
    SUM(assigned),
    SUM(mature_24h),
    SUM(registered_24h),
    SUM(registered_rolling),
    SUM(lesson_started),
    SUM(lesson_completed),
    SUM(first_open),
    SUM(login_page),
    SUM(paywall_any),
    SUM(checkout_any)
  FROM effect_by_platform
  GROUP BY experiment_group
),
daily_by_platform AS (
  SELECT
    platform,
    assignment_day,
    experiment_group,
    COUNT(*) AS assigned,
    COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR))) AS mature_24h,
    COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR)) AND registered_24h) AS registered_24h,
    COUNTIF(registered_rolling) AS registered_rolling,
    COUNTIF(lesson_started) AS lesson_started,
    COUNTIF(lesson_completed) AS lesson_completed
  FROM device_metrics
  GROUP BY platform, assignment_day, experiment_group
),
daily AS (
  SELECT * FROM daily_by_platform
  UNION ALL
  SELECT
    'ALL' AS platform,
    assignment_day,
    experiment_group,
    SUM(assigned),
    SUM(mature_24h),
    SUM(registered_24h),
    SUM(registered_rolling),
    SUM(lesson_started),
    SUM(lesson_completed)
  FROM daily_by_platform
  GROUP BY assignment_day, experiment_group
),
health_by_platform AS (
  SELECT
    platform,
    COUNT(*) AS all_assigned_devices,
    COUNTIF(saw_fallback) AS fallback_devices,
    COUNTIF(channel_count > 1) AS conflict_devices
  FROM eligible
  GROUP BY platform
),
health AS (
  SELECT * FROM health_by_platform
  UNION ALL
  SELECT 'ALL', SUM(all_assigned_devices), SUM(fallback_devices), SUM(conflict_devices)
  FROM health_by_platform
),
lesson_detail_by_platform AS (
  SELECT
    s.platform,
    s.experiment_group,
    e.lesson_id,
    COUNT(DISTINCT IF(e.anchor = 'class_lesson_start', s.user_pseudo_id, NULL)) AS started,
    COUNT(DISTINCT IF(
      (s.experiment_group = 'a' AND (
        (e.lesson_id IN ('732','1615','734','733','1613','1614') AND e.anchor = 'trial_lesson_complete')
        OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete')
      ))
      OR (s.experiment_group = 'b' AND e.anchor = 'class_lesson_end' AND e.result_value = 'complete'),
      s.user_pseudo_id,
      NULL
    )) AS completed
  FROM stable s
  JOIN events e
    ON e.user_pseudo_id = s.user_pseudo_id
   AND e.platform = s.platform
   AND e.event_timestamp >= s.first_assigned_at
  WHERE (s.experiment_group = 'a' AND e.lesson_id IN ('732','1615','734','733','1613','1614','1616'))
     OR (s.experiment_group = 'b' AND e.lesson_id IN ('1661','1616'))
  GROUP BY 1,2,3
),
lesson_detail AS (
  SELECT * FROM lesson_detail_by_platform
  UNION ALL
  SELECT 'ALL', experiment_group, lesson_id, SUM(started), SUM(completed)
  FROM lesson_detail_by_platform
  GROUP BY experiment_group, lesson_id
)
SELECT
  'group' AS row_type,
  CONCAT(LOWER(platform), '-', experiment_group) AS row_key,
  assigned AS v1,
  mature_24h AS v2,
  registered_24h AS v3,
  registered_rolling AS v4,
  lesson_started AS v5,
  lesson_completed AS v6,
  first_open AS v7,
  login_page AS v8,
  paywall_any AS v9,
  checkout_any AS v10
FROM effect
UNION ALL
SELECT
  'day',
  CONCAT(LOWER(platform), '-', FORMAT_DATE('%m-%d', assignment_day), '-', experiment_group),
  assigned,
  mature_24h,
  registered_24h,
  registered_rolling,
  lesson_started,
  lesson_completed,
  NULL,NULL,NULL,NULL
FROM daily
UNION ALL
SELECT 'health', LOWER(platform), all_assigned_devices, fallback_devices, conflict_devices, NULL, NULL, NULL,
  NULL,NULL,NULL,NULL
FROM health
UNION ALL
SELECT 'lesson', CONCAT(LOWER(platform), '-', experiment_group, '-', lesson_id), started, completed,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM lesson_detail
ORDER BY row_type, row_key;
