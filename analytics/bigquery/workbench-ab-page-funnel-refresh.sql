-- A/B 主链路页面级漏斗刷新（本地查询脚本，不部署）。
-- 与工作台当前统一截点保持一致；按 Android / iOS 稳定非测试设备、首次进组国家、累计命中前序节点。

DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-12 01:21:00+00';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260810'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260811' AND '20260812'
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
    event_timestamp,
    event_name,
    user_pseudo_id,
    user_id,
    platform,
    country,
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
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'firebase_screen_class') AS screen_class,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'step_id') AS step_id,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'source') AS source,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'subscription_source') AS subscription_source,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
    )) AS result_value
  FROM base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
),
assignments AS (
  SELECT platform, user_pseudo_id, event_timestamp, channel, country
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
    ARRAY_AGG(STRUCT(channel, country) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_assignment,
    COUNT(DISTINCT channel) AS channel_count
  FROM assignments
  GROUP BY platform, user_pseudo_id
),
stable AS (
  SELECT
    platform,
    user_pseudo_id,
    first_assigned_at,
    first_assignment.channel AS experiment_group,
    first_assignment.country AS assignment_country
  FROM device_groups
  WHERE first_assigned_at >= UNIX_MICROS(experiment_start)
    AND channel_count = 1
    AND first_assignment.channel IN ('a', 'b')
),
uid_map AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    ARRAY_AGG(e.user_id IGNORE NULLS ORDER BY e.event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS user_id
  FROM stable s
  LEFT JOIN events e
    ON e.platform = s.platform
   AND e.user_pseudo_id = s.user_pseudo_id
   AND e.event_timestamp >= s.first_assigned_at
  GROUP BY 1,2
),
paid_flags AS (
  SELECT
    u.platform,
    u.user_pseudo_id,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.subscription_source = 'trial_report') > 0 AS a_paid_success,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION' AND o.subscription_source = 'guidance_report') > 0 AS b_paid_success
  FROM uid_map u
  LEFT JOIN `dino-english-497507.de_ods.payment_order` o
    ON CAST(o.user_id AS STRING) = u.user_id
   AND o.created_at >= experiment_start
   AND o.created_at < cutoff
  GROUP BY 1,2
),
flags AS (
  SELECT
    s.platform,
    s.user_pseudo_id,
    s.experiment_group,
    s.assignment_country,
    LOGICAL_OR(e.anchor = 'first_open') AS first_open,
    LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'WelcomeActivity') AS welcome,
    LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'OnboardingSetupActivity') AS onboarding,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (
      e.step_id = '2_learner_name' OR e.content_id = '2_learner_name'
    )) AS q_name,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (
      e.step_id = '3_learner_age' OR STARTS_WITH(e.content_id, '3_learner_age:')
    )) AS q_age,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (
      e.step_id = '4_english_level' OR STARTS_WITH(e.content_id, '4_english_level:')
    )) AS q_level,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (
      e.step_id = '5_learning_goal' OR STARTS_WITH(e.content_id, '5_learning_goal:')
    )) AS q_goal,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'login') AS login_page,
    LOGICAL_OR(e.anchor = 'signup_result' AND e.result_value IN ('true', '1', 'success')) AS registered,
    LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'DinoClassTeacherSelectActivity') AS teacher_page,
    LOGICAL_OR(e.anchor = 'teacher_selected') AS teacher_selected,
    LOGICAL_OR(e.anchor = 'study_plan_preview' AND e.source = 'onboarding') AS study_plan_preview,
    LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'study_plan_preview') AS b_paywall_1,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_dino') AS guide_dino,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_play') AS guide_play,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_explore') AS guide_explore,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_class_intro') AS guide_class,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_teacher_select') AS guide_teacher,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_lesson_start') AS guide_lesson,
    LOGICAL_OR(e.anchor = 'onboarding_guide_progress' AND e.content_id = 'hub_complete') AS guide_complete,
    LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'onboarding_guide') AS b_paywall_2,
    LOGICAL_OR(e.anchor = 'class_lesson_start' AND e.lesson_id IN ('732','1615','734','733','1613','1614')) AS a_lesson_start,
    LOGICAL_OR(
      e.anchor = 'trial_lesson_complete'
      OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete'
        AND e.lesson_id IN ('732','1615','734','733','1613','1614'))
    ) AS a_lesson_complete,
    LOGICAL_OR(e.anchor = 'class_lesson_start' AND e.lesson_id = '1661') AS b_lesson_start,
    LOGICAL_OR(e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id = '1661') AS b_lesson_complete,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'report' AND e.source = 'course_flow') AS course_report,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'study_plan' AND e.source = 'trial_report') AS a_study_plan,
    LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'trial_report') AS a_paywall,
    LOGICAL_OR(e.anchor = 'subscription_checkout_start'
      AND COALESCE(e.source, e.subscription_source) = 'trial_report') AS a_checkout,
    LOGICAL_OR(e.anchor = 'discount_offer' AND e.source = 'guidance_report') AS guidance_discount,
    LOGICAL_OR(e.anchor = 'subscription_checkout_start'
      AND COALESCE(e.source, e.subscription_source) = 'guidance_report') AS guidance_checkout,
    LOGICAL_OR(COALESCE(p.a_paid_success, FALSE)) AS a_paid_success,
    LOGICAL_OR(COALESCE(p.b_paid_success, FALSE)) AS b_paid_success
  FROM stable s
  LEFT JOIN events e
   ON e.user_pseudo_id = s.user_pseudo_id
   AND e.platform = s.platform
  LEFT JOIN paid_flags p
    ON p.user_pseudo_id = s.user_pseudo_id
   AND p.platform = s.platform
  GROUP BY 1,2,3,4
),
device_steps AS (
  SELECT
    f.platform,
    f.user_pseudo_id,
    f.experiment_group,
    f.assignment_country,
    step.step_order,
    step.step_key,
    step.reached
  FROM flags f
  CROSS JOIN UNNEST(
    CASE f.experiment_group
      WHEN 'a' THEN [
        STRUCT(1 AS step_order, 'first_open' AS step_key, first_open AS reached),
        (2, 'welcome', first_open AND welcome),
        (3, 'onboarding_enter', first_open AND welcome AND onboarding),
        (4, 'question_name', first_open AND welcome AND onboarding AND q_name),
        (5, 'question_age', first_open AND welcome AND onboarding AND q_name AND q_age),
        (6, 'question_level', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level),
        (7, 'login_page', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page),
        (8, 'signup_success', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered),
        (9, 'teacher_page', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page),
        (10, 'teacher_selected', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected),
        (11, 'trial_lesson_start', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start),
        (12, 'trial_lesson_complete', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete),
        (13, 'trial_report', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report),
        (14, 'study_plan', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan),
        (15, 'trial_paywall', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall),
        (16, 'trial_checkout', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall AND a_checkout),
        (17, 'trial_paid_success', first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall AND a_checkout AND a_paid_success)
      ]
      ELSE [
        STRUCT(1 AS step_order, 'first_open' AS step_key, first_open AS reached),
        (2, 'login_page', first_open AND login_page),
        (3, 'signup_success', first_open AND login_page AND registered),
        (4, 'onboarding_enter', first_open AND login_page AND registered AND onboarding),
        (5, 'question_name', first_open AND login_page AND registered AND onboarding AND q_name),
        (6, 'question_age', first_open AND login_page AND registered AND onboarding AND q_name AND q_age),
        (7, 'question_level', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level),
        (8, 'question_goal', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal),
        (9, 'study_plan_preview', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview),
        (10, 'paywall_1', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1),
        (11, 'guide_dino', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino),
        (12, 'guide_play', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play),
        (13, 'guide_explore', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore),
        (14, 'guide_class', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class),
        (15, 'guide_teacher', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher),
        (16, 'teacher_page', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page),
        (17, 'guide_lesson', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson),
        (18, 'guide_complete', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete),
        (19, 'paywall_2', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2),
        (20, 'onboarding_lesson_start', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start),
        (21, 'onboarding_lesson_complete', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete),
        (22, 'guidance_report', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND course_report),
        (23, 'guidance_discount', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND course_report AND guidance_discount),
        (24, 'guidance_checkout', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND course_report AND guidance_discount AND guidance_checkout),
        (25, 'guidance_paid_success', first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND course_report AND guidance_discount AND guidance_checkout AND b_paid_success)
      ]
    END
  ) step
),
country_targets AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS country_key, CAST(NULL AS STRING) AS country_name),
    ('kr', 'South Korea'),
    ('sa', 'Saudi Arabia'),
    ('my', 'Malaysia'),
    ('id', 'Indonesia'),
    ('vn', 'Vietnam')
  ])
),
platform_targets AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS platform_key, CAST(NULL AS STRING) AS platform_name),
    ('android', 'ANDROID'),
    ('ios', 'IOS')
  ])
),
step_counts AS (
  SELECT
    p.platform_key,
    c.country_key,
    s.experiment_group,
    s.step_order,
    COUNT(*) AS assigned_devices,
    COUNTIF(s.reached) AS reached_devices
  FROM platform_targets p
  JOIN device_steps s ON p.platform_name IS NULL OR s.platform = p.platform_name
  JOIN country_targets c ON c.country_name IS NULL OR s.assignment_country = c.country_name
  GROUP BY 1,2,3,4
)
SELECT
  platform_key,
  country_key,
  experiment_group,
  MAX(assigned_devices) AS assigned_devices,
  ARRAY_TO_STRING(ARRAY_AGG(CAST(reached_devices AS STRING) ORDER BY step_order), ',') AS reached_devices
FROM step_counts
GROUP BY 1,2,3
ORDER BY platform_key, country_key, experiment_group;
