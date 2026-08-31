-- Dino English 核心指标观测工作台：Android 页面级诊断全量刷新。
-- 双平台注册摘要使用 core-dashboard-ab-refresh.sql；本文件保留 Android 页面锚点，避免混入尚未对齐的 iOS 页面事件。
-- 统一截点：2026-08-31 03:01 UTC；首次稳定进组从 2026-08-01 00:00 UTC 起。
-- 任一事件出现 user_properties.user_type=test 的设备在进组前统一排除。

DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-31 03:01:24+00';

CREATE TEMP TABLE events AS
WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260829'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260830' AND '20260831'
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
  DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_day,
  event_name,
  user_pseudo_id,
  user_id,
  platform,
  country,
  COALESCE((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'), event_name) AS anchor,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'content_id') AS content_id,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'channel') AS channel,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'lesson_id') AS lesson_id,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'firebase_screen_class') AS screen_class,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'step_id') AS step_id,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'source') AS source,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'subscription_source') AS subscription_source,
  (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'template_id') AS template_id,
  LOWER(COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
    CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
  )) AS result_value
FROM base
WHERE event_timestamp < UNIX_MICROS(cutoff);

CREATE TEMP TABLE eligible AS
WITH assignments AS (
  SELECT user_pseudo_id, event_timestamp, channel, country
  FROM events
  WHERE platform = 'ANDROID'
    AND event_name = 'trigger'
    AND anchor = 'experiment_group_assign'
    AND content_id = 'conv_funnel_v1'
    AND user_pseudo_id IS NOT NULL
), device_groups AS (
  SELECT
    user_pseudo_id,
    MIN(event_timestamp) AS first_assigned_at,
    ARRAY_AGG(STRUCT(channel, country) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_assignment,
    COUNT(DISTINCT channel) AS channel_count,
    LOGICAL_OR(channel = 'fallback') AS saw_fallback
  FROM assignments
  GROUP BY user_pseudo_id
)
SELECT
  user_pseudo_id,
  first_assigned_at,
  first_assignment.channel AS first_channel,
  first_assignment.country AS assignment_country,
  channel_count,
  saw_fallback
FROM device_groups
WHERE first_assigned_at >= UNIX_MICROS(experiment_start);

CREATE TEMP TABLE stable AS
SELECT
  user_pseudo_id,
  first_assigned_at,
  DATE(TIMESTAMP_MICROS(first_assigned_at)) AS assignment_day,
  first_channel AS experiment_group,
  assignment_country
FROM eligible
WHERE channel_count = 1 AND first_channel IN ('a', 'b');

CREATE TEMP TABLE device_flags AS
SELECT
  s.user_pseudo_id,
  s.first_assigned_at,
  s.assignment_day,
  s.experiment_group,
  s.assignment_country,
  LOGICAL_OR(e.anchor = 'first_open') AS first_open,
  LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'WelcomeActivity') AS a_welcome,
  LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'OnboardingSetupActivity') AS onboarding,
  LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '4_english_level' OR STARTS_WITH(e.content_id, '4_english_level:'))) AS a_onboarding_complete,
  LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '5_learning_goal' OR STARTS_WITH(e.content_id, '5_learning_goal:'))) AS b_onboarding_complete,
  LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'login') AS login_page,
  LOGICAL_OR(e.anchor = 'signup_result' AND e.result_value IN ('true', '1', 'success')) AS registered_any,
  LOGICAL_OR(
    e.anchor = 'signup_result'
    AND e.result_value IN ('true', '1', 'success')
    AND e.event_timestamp BETWEEN s.first_assigned_at AND s.first_assigned_at + 24 * 60 * 60 * 1000000
  ) AS registered_24h,
  LOGICAL_OR(e.anchor = 'signup_result' AND e.result_value IN ('true', '1', 'success') AND e.event_timestamp >= s.first_assigned_at) AS registered_rolling,
  LOGICAL_OR(e.anchor = 'teacher_selected') AS teacher_selected,
  LOGICAL_OR(e.anchor = 'study_plan_preview' AND e.source = 'onboarding') AS study_plan_preview,
  LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'study_plan_preview') AS b_paywall_1,
  LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_dino') AS guide_start,
  LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_complete') AS guide_complete,
  LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'onboarding_guide') AS b_paywall_2,
  LOGICAL_OR(e.anchor = 'discount_offer' AND e.source = 'guidance_report') AS discount_guidance_report,
  LOGICAL_OR(e.anchor = 'subscription_checkout_start' AND COALESCE(e.source, e.subscription_source) = 'guidance_report') AS checkout_guidance_report,
  LOGICAL_OR(e.anchor = 'subscription') AS paywall_any,
  LOGICAL_OR(e.anchor = 'subscription_checkout_start') AS checkout_any,
  LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'trial_report') AS a_paywall,
  LOGICAL_OR(e.anchor = 'class_lesson_start' AND e.lesson_id IN ('732','1615','734','733','1613','1614')) AS a_lesson_start,
  LOGICAL_OR(
    e.anchor = 'trial_lesson_complete'
    OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id IN ('732','1615','734','733','1613','1614'))
  ) AS a_lesson_complete,
  LOGICAL_OR(e.anchor = 'class_lesson_start' AND e.lesson_id = '1661') AS b_lesson_start,
  LOGICAL_OR(e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id = '1661') AS b_lesson_complete,
  LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND e.anchor = 'class_lesson_start' AND e.lesson_id IN ('732','1615','734','733','1613','1614','1616')) AS a_metric_lesson_start,
  LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND (
    e.anchor = 'trial_lesson_complete'
    OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id IN ('732','1615','734','733','1613','1614','1616'))
  )) AS a_metric_lesson_complete,
  LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND e.anchor = 'class_lesson_start' AND e.lesson_id IN ('1661','1616')) AS b_metric_lesson_start,
  LOGICAL_OR(e.event_timestamp >= s.first_assigned_at AND e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id IN ('1661','1616')) AS b_metric_lesson_complete
FROM stable s
LEFT JOIN events e USING (user_pseudo_id)
GROUP BY 1,2,3,4,5;

CREATE TEMP TABLE group_totals AS
SELECT
  experiment_group,
  COUNT(*) AS assigned,
  COUNTIF(first_open) AS first_open,
  COUNTIF(login_page) AS login_page,
  COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR))) AS mature_24h,
  COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR)) AND registered_24h) AS registered_24h,
  COUNTIF(registered_rolling) AS registered_rolling,
  COUNTIF(paywall_any) AS paywall_any,
  COUNTIF(checkout_any) AS checkout_any,
  COUNTIF(IF(experiment_group = 'a', a_metric_lesson_start, b_metric_lesson_start)) AS lesson_start,
  COUNTIF(IF(experiment_group = 'a', a_metric_lesson_complete, b_metric_lesson_complete)) AS lesson_complete
FROM device_flags
GROUP BY experiment_group;

CREATE TEMP TABLE payment_by_day AS
WITH uid_candidates AS (
  SELECT DISTINCT s.experiment_group, s.assignment_day, s.first_assigned_at, e.user_id
  FROM stable s
  JOIN events e USING (user_pseudo_id)
  WHERE e.event_timestamp >= s.first_assigned_at AND e.user_id IS NOT NULL
), uid_map AS (
  SELECT experiment_group, assignment_day, user_id
  FROM uid_candidates
  QUALIFY ROW_NUMBER() OVER (PARTITION BY experiment_group, user_id ORDER BY first_assigned_at) = 1
), orders AS (
  SELECT m.experiment_group, m.assignment_day, o.order_no, o.status, o.env_type
  FROM uid_map m
  JOIN `dino-english-497507.de_ods.payment_order` o ON CAST(o.user_id AS STRING) = m.user_id
  WHERE o.created_at >= experiment_start AND o.created_at < cutoff
)
SELECT
  experiment_group,
  assignment_day,
  COUNT(DISTINCT IF(status = 'PENDING', order_no, NULL)) AS pending_orders,
  COUNT(DISTINCT IF(status = 'SUCCESS' AND env_type = 'PRODUCTION', order_no, NULL)) AS paid_orders
FROM orders
GROUP BY 1,2;

CREATE TEMP TABLE country_targets AS
SELECT * FROM UNNEST([
  STRUCT('all' AS country_key, CAST(NULL AS STRING) AS country_name),
  ('kr', 'South Korea'),
  ('sa', 'Saudi Arabia'),
  ('my', 'Malaysia'),
  ('id', 'Indonesia'),
  ('vn', 'Vietnam')
]);

CREATE TEMP TABLE flow_rows AS
SELECT
  c.country_key,
  d.experiment_group,
  COUNT(*) AS assigned,
  COUNTIF(first_open) AS c1,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome, login_page)) AS c2,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding, login_page AND registered_any)) AS c3,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete, login_page AND registered_any AND onboarding)) AS c4,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page, login_page AND registered_any AND onboarding AND b_onboarding_complete)) AS c5,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page AND registered_any, login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview)) AS c6,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page AND registered_any AND teacher_selected, login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1)) AS c7,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page AND registered_any AND teacher_selected AND a_lesson_start, login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start)) AS c8,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page AND registered_any AND teacher_selected AND a_lesson_start AND a_lesson_complete, login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete)) AS c9,
  COUNTIF(first_open AND IF(d.experiment_group = 'a', a_welcome AND onboarding AND a_onboarding_complete AND login_page AND registered_any AND teacher_selected AND a_lesson_start AND a_lesson_complete AND a_paywall, login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete AND b_paywall_2)) AS c10,
  COUNTIF(first_open AND d.experiment_group = 'b' AND login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete AND b_paywall_2 AND b_lesson_start) AS c11,
  COUNTIF(first_open AND d.experiment_group = 'b' AND login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete) AS c12,
  COUNTIF(first_open AND d.experiment_group = 'b' AND login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND discount_guidance_report) AS c13,
  COUNTIF(first_open AND d.experiment_group = 'b' AND login_page AND registered_any AND onboarding AND b_onboarding_complete AND study_plan_preview AND b_paywall_1 AND guide_start AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND discount_guidance_report AND checkout_guidance_report) AS c14
FROM country_targets c
JOIN device_flags d ON c.country_name IS NULL OR d.assignment_country = c.country_name
GROUP BY 1,2;

CREATE TEMP TABLE lesson_detail AS
SELECT
  d.experiment_group,
  e.lesson_id,
  COUNT(DISTINCT IF(e.anchor = 'class_lesson_start', d.user_pseudo_id, NULL)) AS started,
  COUNT(DISTINCT IF(
    (d.experiment_group = 'a' AND (
      (e.lesson_id IN ('732','1615','734','733','1613','1614') AND e.anchor = 'trial_lesson_complete')
      OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete')
    ))
    OR (d.experiment_group = 'b' AND e.anchor = 'class_lesson_end' AND e.result_value = 'complete'),
    d.user_pseudo_id,
    NULL
  )) AS completed
FROM device_flags d
JOIN events e USING (user_pseudo_id)
WHERE ((d.experiment_group = 'a' AND e.lesson_id IN ('732','1615','734','733','1613','1614','1616'))
    OR (d.experiment_group = 'b' AND e.lesson_id IN ('1661','1616')))
  AND e.event_timestamp >= d.first_assigned_at
GROUP BY 1,2;

CREATE TEMP TABLE b_lesson AS
WITH lesson_events AS (
  SELECT e.*
  FROM events e
  JOIN stable s USING (user_pseudo_id)
  WHERE s.experiment_group = 'b' AND e.platform = 'ANDROID' AND e.lesson_id = '1661'
), stage_def AS (
  SELECT * FROM UNNEST([
    STRUCT(1 AS step_order, 'lead-in-template_l1l2' AS template_id),
    (2, 'play-video-template'),
    (3, 'word_teach_image_l1l2'),
    (4, 'word_practice_bubble_image'),
    (5, 'wrapup_summary_video_trail')
  ])
)
SELECT 0 AS step_order, 'class_lesson_start' AS step_key,
  COUNT(DISTINCT IF(anchor = 'class_lesson_start', user_pseudo_id, NULL)) AS reached,
  CAST(NULL AS INT64) AS ended
FROM lesson_events
UNION ALL
SELECT s.step_order, s.template_id,
  COUNT(DISTINCT IF(e.anchor = 'class_stage_start', e.user_pseudo_id, NULL)),
  COUNT(DISTINCT IF(e.anchor = 'class_stage_end', e.user_pseudo_id, NULL))
FROM stage_def s
LEFT JOIN lesson_events e USING (template_id)
GROUP BY 1,2
UNION ALL
SELECT 6, 'class_lesson_end_complete',
  COUNT(DISTINCT IF(anchor = 'class_lesson_end' AND result_value = 'complete', user_pseudo_id, NULL)),
  CAST(NULL AS INT64)
FROM lesson_events;

CREATE TEMP TABLE timing_health AS
WITH b_login AS (
  SELECT
    s.user_pseudo_id,
    s.first_assigned_at,
    MIN(IF(e.event_name = 'page_view' AND e.anchor = 'login', e.event_timestamp, NULL)) AS first_login_at
  FROM stable s
  LEFT JOIN events e USING (user_pseudo_id)
  WHERE s.experiment_group = 'b'
  GROUP BY 1,2
)
SELECT
  COUNTIF(first_login_at IS NOT NULL) AS b_login_devices,
  COUNTIF(first_login_at < first_assigned_at) AS b_login_before_assign,
  APPROX_QUANTILES(IF(first_login_at < first_assigned_at, (first_assigned_at - first_login_at) / 1000000, NULL), 100)[OFFSET(50)] AS median_lag_seconds
FROM b_login;

-- 统一列结构，便于脚本一次导出并写回 HTML。
SELECT 'total' AS section, experiment_group AS row_key, CAST(NULL AS STRING) AS dim,
  assigned AS v1, first_open AS v2, login_page AS v3, mature_24h AS v4, registered_24h AS v5,
  registered_rolling AS v6, paywall_any AS v7, checkout_any AS v8, lesson_start AS v9, lesson_complete AS v10,
  CAST(NULL AS INT64) AS v11, CAST(NULL AS INT64) AS v12, CAST(NULL AS INT64) AS v13, CAST(NULL AS INT64) AS v14,
  CAST(NULL AS INT64) AS v15
FROM group_totals

UNION ALL
SELECT 'day', experiment_group, FORMAT_DATE('%m-%d', assignment_day),
  COUNT(*),
  COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR))),
  COUNTIF(first_assigned_at <= UNIX_MICROS(TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR)) AND registered_24h),
  COUNTIF(registered_rolling),
  COUNTIF(IF(experiment_group = 'a', a_metric_lesson_complete, b_metric_lesson_complete)),
  COALESCE(MAX(p.paid_orders), 0), COALESCE(MAX(p.pending_orders), 0),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM device_flags d
LEFT JOIN payment_by_day p USING (experiment_group, assignment_day)
GROUP BY 1,2,3

UNION ALL
SELECT 'flow', experiment_group, country_key,
  assigned,c1,c2,c3,c4,c5,c6,c7,c8,c9,c10,c11,c12,c13,c14
FROM flow_rows

UNION ALL
SELECT 'lesson', experiment_group, lesson_id, started, completed,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM lesson_detail

UNION ALL
SELECT 'b_lesson', 'b', step_key, reached, ended,
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM b_lesson

UNION ALL
SELECT 'health', 'all', 'eligible', COUNT(*), COUNTIF(saw_fallback), COUNTIF(channel_count > 1),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM eligible

UNION ALL
SELECT 'health', 'b_timing', 'login_before_assign', b_login_devices, b_login_before_assign, CAST(median_lag_seconds AS INT64),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM timing_health

UNION ALL
SELECT 'payment_total', experiment_group, 'orders', SUM(pending_orders), SUM(paid_orders),
  NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL
FROM payment_by_day
GROUP BY 1,2,3

ORDER BY section, row_key, dim;
