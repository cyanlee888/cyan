-- Weekly A/B cohort snapshot for the core dashboard.
-- A weekly slice means: devices first stably assigned during the interval,
-- with funnel events and attributed orders observed through the interval end.
DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-17 02:15:00+00';

WITH weeks AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS week_key, experiment_start AS start_ts, cutoff AS end_ts),
    ('w4', TIMESTAMP '2026-08-01 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', cutoff)
  ])
),
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$') AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260815'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260816' AND '20260817'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
events AS (
  SELECT
    r.event_timestamp, r.event_name, r.user_pseudo_id, r.user_id, r.platform, r.country,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'), r.event_name) AS anchor,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'content_id') AS content_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'channel')) AS channel,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'firebase_screen_class') AS screen_class,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'step_id') AS step_id,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'source') AS source,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'subscription_source') AS subscription_source,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS result_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL AND r.event_timestamp < UNIX_MICROS(cutoff)
),
device_groups AS (
  SELECT
    platform, user_pseudo_id, MIN(event_timestamp) AS first_assigned_at,
    ARRAY_AGG(STRUCT(channel, country) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_assignment,
    COUNT(DISTINCT channel) AS channel_count
  FROM events
  WHERE platform IN ('ANDROID','IOS') AND event_name = 'trigger'
    AND anchor = 'experiment_group_assign' AND content_id = 'conv_funnel_v1'
  GROUP BY 1,2
),
stable AS (
  SELECT
    w.week_key, w.end_ts, d.platform, d.user_pseudo_id, d.first_assigned_at,
    d.first_assignment.channel AS experiment_group,
    d.first_assignment.country AS assignment_country
  FROM device_groups d
  JOIN weeks w ON d.first_assigned_at >= UNIX_MICROS(w.start_ts) AND d.first_assigned_at < UNIX_MICROS(w.end_ts)
  WHERE d.first_assigned_at >= UNIX_MICROS(experiment_start)
    AND d.channel_count = 1 AND d.first_assignment.channel IN ('a','b')
),
uid_map AS (
  SELECT
    s.week_key, s.platform, s.user_pseudo_id,
    ARRAY_AGG(e.user_id IGNORE NULLS ORDER BY e.event_timestamp DESC LIMIT 1)[SAFE_OFFSET(0)] AS user_id
  FROM stable s
  LEFT JOIN events e ON e.platform = s.platform AND e.user_pseudo_id = s.user_pseudo_id
    AND e.event_timestamp < UNIX_MICROS(s.end_ts)
  GROUP BY 1,2,3
),
order_flags AS (
  SELECT
    s.week_key, s.platform, s.user_pseudo_id,
    COUNTIF(o.status = 'SUCCESS' AND o.env_type = 'PRODUCTION') > 0 AS paid,
    COUNTIF(o.status = 'PENDING') AS pending
  FROM stable s
  LEFT JOIN uid_map u USING (week_key, platform, user_pseudo_id)
  LEFT JOIN `dino-english-497507.de_ods.payment_order` o
    ON CAST(o.user_id AS STRING) = u.user_id
   AND o.created_at >= TIMESTAMP_MICROS(s.first_assigned_at) AND o.created_at < s.end_ts
  GROUP BY 1,2,3
),
flags AS (
  SELECT
    s.week_key, s.platform, s.user_pseudo_id, s.experiment_group, s.assignment_country,
    LOGICAL_OR(e.anchor = 'first_open') AS first_open,
    LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'WelcomeActivity') AS welcome,
    LOGICAL_OR(e.anchor = 'screen_view' AND e.screen_class = 'OnboardingSetupActivity') AS onboarding,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '2_learner_name' OR e.content_id = '2_learner_name')) AS q_name,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '3_learner_age' OR STARTS_WITH(e.content_id, '3_learner_age:'))) AS q_age,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '4_english_level' OR STARTS_WITH(e.content_id, '4_english_level:'))) AS q_level,
    LOGICAL_OR(e.anchor = 'step_submitted' AND (e.step_id = '5_learning_goal' OR STARTS_WITH(e.content_id, '5_learning_goal:'))) AS q_goal,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'login') AS login_page,
    LOGICAL_OR(e.anchor = 'signup_result' AND e.result_value IN ('true','1','success')) AS registered,
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
    LOGICAL_OR(e.anchor = 'trial_lesson_complete' OR (e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id IN ('732','1615','734','733','1613','1614'))) AS a_lesson_complete,
    LOGICAL_OR(e.anchor = 'class_lesson_start' AND e.lesson_id = '1661') AS b_lesson_start,
    LOGICAL_OR(e.anchor = 'class_lesson_end' AND e.result_value = 'complete' AND e.lesson_id = '1661') AS b_lesson_complete,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'report' AND e.source = 'course_flow') AS course_report,
    LOGICAL_OR(e.event_name = 'page_view' AND e.anchor = 'study_plan' AND e.source = 'trial_report') AS a_study_plan,
    LOGICAL_OR(e.anchor = 'subscription' AND e.source = 'trial_report') AS a_paywall,
    LOGICAL_OR(e.anchor = 'subscription_checkout_start' AND COALESCE(e.source,e.subscription_source) = 'trial_report') AS a_checkout,
    LOGICAL_OR(e.anchor = 'discount_offer' AND e.source = 'guidance_report') AS guidance_discount,
    LOGICAL_OR(e.anchor = 'subscription_checkout_start' AND COALESCE(e.source,e.subscription_source) = 'guidance_report') AS guidance_checkout,
    LOGICAL_OR(COALESCE(o.paid,FALSE)) AS paid,
    MAX(COALESCE(o.pending,0)) AS pending
  FROM stable s
  LEFT JOIN events e ON e.platform = s.platform AND e.user_pseudo_id = s.user_pseudo_id
    AND e.event_timestamp < UNIX_MICROS(s.end_ts)
  LEFT JOIN order_flags o ON o.week_key = s.week_key AND o.platform = s.platform AND o.user_pseudo_id = s.user_pseudo_id
  GROUP BY 1,2,3,4,5
),
device_steps AS (
  SELECT f.*, step.step_order, step.reached
  FROM flags f
  CROSS JOIN UNNEST(CASE f.experiment_group
    WHEN 'a' THEN [
      STRUCT(1 AS step_order, first_open AS reached), (2, first_open AND welcome), (3, first_open AND welcome AND onboarding),
      (4, first_open AND welcome AND onboarding AND q_name), (5, first_open AND welcome AND onboarding AND q_name AND q_age),
      (6, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level),
      (7, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page),
      (8, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered),
      (9, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page),
      (10, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected),
      (11, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start),
      (12, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete),
      (13, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report),
      (14, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan),
      (15, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall),
      (16, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall AND a_checkout),
      (17, first_open AND welcome AND onboarding AND q_name AND q_age AND q_level AND login_page AND registered AND teacher_page AND teacher_selected AND a_lesson_start AND a_lesson_complete AND course_report AND a_study_plan AND a_paywall AND a_checkout AND paid)
    ]
    ELSE [
      STRUCT(1 AS step_order, first_open AS reached), (2, first_open AND login_page), (3, first_open AND login_page AND registered),
      (4, first_open AND login_page AND registered AND onboarding), (5, first_open AND login_page AND registered AND onboarding AND q_name),
      (6, first_open AND login_page AND registered AND onboarding AND q_name AND q_age),
      (7, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level),
      (8, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal),
      (9, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview),
      (10, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1),
      (11, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino),
      (12, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play),
      (13, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore),
      (14, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class),
      (15, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher),
      (16, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page),
      (17, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson),
      (18, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete),
      (19, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2),
      (20, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start),
      (21, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete),
      (22, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND guidance_discount),
      (23, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND guidance_discount AND guidance_checkout),
      (24, first_open AND login_page AND registered AND onboarding AND q_name AND q_age AND q_level AND q_goal AND study_plan_preview AND b_paywall_1 AND guide_dino AND guide_play AND guide_explore AND guide_class AND guide_teacher AND teacher_page AND guide_lesson AND guide_complete AND b_paywall_2 AND b_lesson_start AND b_lesson_complete AND guidance_discount AND guidance_checkout AND paid)
    ] END) step
),
scopes AS (
  SELECT week_key, platform, user_pseudo_id, experiment_group,
    CASE assignment_country WHEN 'Vietnam' THEN 'vn' WHEN 'South Korea' THEN 'kr' WHEN 'Saudi Arabia' THEN 'sa' WHEN 'Malaysia' THEN 'my' WHEN 'Indonesia' THEN 'id' WHEN 'Thailand' THEN 'th' ELSE 'other' END AS country_key,
    step_order, reached, pending
  FROM device_steps
),
flow_rollup AS (
  SELECT week_key, country_key, experiment_group, step_order, COUNT(DISTINCT user_pseudo_id) AS assigned, COUNTIF(reached) AS reached, SUM(IF(step_order=1,pending,0)) AS pending
  FROM scopes WHERE platform='ANDROID' GROUP BY 1,2,3,4
  UNION ALL
  SELECT week_key, 'all', experiment_group, step_order, COUNT(DISTINCT user_pseudo_id), COUNTIF(reached), SUM(IF(step_order=1,pending,0))
  FROM scopes WHERE platform='ANDROID' GROUP BY 1,2,3,4
),
flow_json AS (
  SELECT week_key, country_key, experiment_group, MAX(assigned) AS assigned,
    ARRAY_AGG(reached ORDER BY step_order) AS counts, MAX(pending) AS pending
  FROM flow_rollup GROUP BY 1,2,3
),
pay_rollup AS (
  SELECT week_key,
    CASE assignment_country WHEN 'Vietnam' THEN 'vn' WHEN 'South Korea' THEN 'kr' WHEN 'Saudi Arabia' THEN 'sa' WHEN 'Malaysia' THEN 'my' WHEN 'Indonesia' THEN 'id' WHEN 'Thailand' THEN 'th' ELSE 'other' END AS country_key,
    experiment_group, COUNT(DISTINCT CONCAT(platform,':',user_pseudo_id)) AS pay_assigned, COUNTIF(paid) AS paid, SUM(pending) AS pending
  FROM flags GROUP BY 1,2,3
  UNION ALL
  SELECT week_key, 'all', experiment_group, COUNT(DISTINCT CONCAT(platform,':',user_pseudo_id)), COUNTIF(paid), SUM(pending)
  FROM flags GROUP BY 1,2,3
),
result_rows AS (
  SELECT f.week_key, f.country_key, f.experiment_group, f.assigned, f.counts,
    COALESCE(p.pay_assigned,0) AS pay_assigned, COALESCE(p.paid,0) AS paid, COALESCE(p.pending,0) AS pending
  FROM flow_json f LEFT JOIN pay_rollup p USING (week_key,country_key,experiment_group)
)
SELECT week_key, TO_JSON_STRING(ARRAY_AGG(STRUCT(country_key,experiment_group,assigned,counts,pay_assigned,paid,pending) ORDER BY country_key,experiment_group)) AS payload
FROM result_rows
WHERE country_key IN ('all','vn','kr','sa','my','id','th')
GROUP BY week_key ORDER BY week_key;
