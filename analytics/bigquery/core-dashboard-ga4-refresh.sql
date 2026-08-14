-- Core dashboard GA4 refresh.
-- Daily tables are authoritative through 2026-08-13; intraday fills 08-14.
-- Any device that reports user_properties.user_type=test is excluded from the full window.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-14 15:08:00+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-13';
DECLARE module_coverage_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-07 00:00:00+00';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260813'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX = '20260814'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
base AS (
  SELECT r.event_timestamp, r.event_name, r.user_pseudo_id, r.user_id, r.event_params
  FROM raw_base r
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
),
events AS (
  SELECT
    event_timestamp,
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_day,
    user_pseudo_id,
    user_id,
    event_name,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'),
      event_name
    ) AS anchor,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'button_id') AS button_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'step_id'),
      SPLIT((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'content_id'), ':')[SAFE_OFFSET(0)]
    ) AS step_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'template_id'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'block_template_id')
    ) AS template_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'stage_step') AS stage_step,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'dino_step') AS dino_step,
    (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'dino_scene') AS dino_scene,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'status')) AS status,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'scene')) AS scene,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
    )) AS success_value,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')) AS result_value
  FROM base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
),
first_lesson_start AS (
  SELECT
    user_pseudo_id,
    ARRAY_AGG(STRUCT(
      event_timestamp AS start_ts,
      lesson_id AS lesson_id
    ) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_lesson
  FROM events
  WHERE anchor = 'class_lesson_start'
    AND lesson_id IN ('732', '1615', '734', '733', '1613', '1614', '1661', '1616')
  GROUP BY user_pseudo_id
),
first_lesson_summary AS (
  SELECT
    COUNT(*) AS started,
    COUNTIF(
      EXISTS(
        SELECT 1
        FROM events e
        WHERE e.user_pseudo_id = s.user_pseudo_id
          AND e.anchor = 'class_lesson_end'
          AND e.event_timestamp >= s.first_lesson.start_ts
          AND e.lesson_id = s.first_lesson.lesson_id
          AND e.result_value = 'complete'
      )
      OR (
        s.first_lesson.lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
        AND EXISTS(
          SELECT 1
          FROM events e
          WHERE e.user_pseudo_id = s.user_pseudo_id
            AND e.anchor = 'trial_lesson_complete'
            AND e.event_timestamp >= s.first_lesson.start_ts
        )
      )
    ) AS ended
  FROM first_lesson_start s
),
metrics AS (
  SELECT 'first_open' metric, COUNT(DISTINCT IF(event_name = 'first_open', user_pseudo_id, NULL)) value FROM events
  UNION ALL SELECT 'signup_success', COUNT(DISTINCT IF(anchor = 'signup_result' AND success_value IN ('true','1','success'), user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'teacher_selected', COUNT(DISTINCT IF(anchor = 'teacher_selected', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'class_lesson_start', COUNT(DISTINCT IF(anchor = 'class_lesson_start', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'first_lesson_start', started FROM first_lesson_summary
  UNION ALL SELECT 'first_lesson_end', ended FROM first_lesson_summary
  UNION ALL SELECT 'trial_lesson_complete', COUNT(DISTINCT IF(anchor = 'trial_lesson_complete', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'app_remove', COUNT(DISTINCT IF(event_name = 'app_remove', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'welcome_get_started', COUNT(DISTINCT IF(button_id = 'welcome_get_started' OR anchor = 'welcome_get_started', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'onboarding_1', COUNT(DISTINCT IF(anchor = 'step_submitted' AND step_id = '1_learner_type', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'onboarding_2', COUNT(DISTINCT IF(anchor = 'step_submitted' AND step_id = '2_learner_name', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'onboarding_3', COUNT(DISTINCT IF(anchor = 'step_submitted' AND step_id = '3_learner_age', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'onboarding_4', COUNT(DISTINCT IF(anchor = 'step_submitted' AND step_id = '4_english_level', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_phone', COUNT(DISTINCT IF(button_id = 'login_phone' OR anchor = 'login_phone', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_phone_get_code', COUNT(DISTINCT IF(button_id = 'login_phone_get_code' OR anchor = 'login_phone_get_code', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_google', COUNT(DISTINCT IF(button_id = 'login_google' OR anchor = 'login_google', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_meta', COUNT(DISTINCT IF(button_id = 'login_meta' OR anchor = 'login_meta', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_kakao', COUNT(DISTINCT IF(button_id = 'login_kakao' OR anchor = 'login_kakao', user_pseudo_id, NULL)) FROM events
  UNION ALL SELECT 'login_apple', COUNT(DISTINCT IF(button_id = 'login_apple' OR anchor = 'login_apple', user_pseudo_id, NULL)) FROM events
  -- Core modules use signed-in users (user_id) for both numerator and denominator.
  -- Entry clicks are excluded; Explore / Play detail events begin on 2026-08-07.
  UNION ALL SELECT 'core_logged_in_users', COUNT(DISTINCT user_id) FROM events
  UNION ALL SELECT 'core_class_users', COUNT(DISTINCT IF(
    anchor = 'class_lesson_start', user_id, NULL)) FROM events
  UNION ALL SELECT 'core_dino_users', COUNT(DISTINCT IF(
    (anchor = 'dino_assistant_progress' AND dino_step = 'session_start') OR anchor = 'dino_session_start',
    user_id, NULL)) FROM events
  UNION ALL SELECT 'core_explore_users', COUNT(DISTINCT IF(
    (anchor = 'explore_practice_progress' AND status = 'start')
      OR (anchor = 'listening_play_progress' AND status = 'play_start'),
    user_id, NULL)) FROM events
  UNION ALL SELECT 'core_explore_words_users', COUNT(DISTINCT IF(
    anchor = 'explore_practice_progress' AND status = 'start', user_id, NULL)) FROM events
  UNION ALL SELECT 'core_explore_listening_users', COUNT(DISTINCT IF(
    anchor = 'listening_play_progress' AND status = 'play_start', user_id, NULL)) FROM events
  UNION ALL SELECT 'core_play_users', COUNT(DISTINCT IF(
    anchor = 'play_round_progress' AND status = 'round_start'
    AND scene IN ('blind_box','words_pk','speaking_pk'), user_id, NULL)) FROM events
  UNION ALL SELECT 'core_play_blind_box_users', COUNT(DISTINCT IF(
    anchor = 'play_round_progress' AND status = 'round_start' AND scene = 'blind_box',
    user_id, NULL)) FROM events
  UNION ALL SELECT 'core_play_words_pk_users', COUNT(DISTINCT IF(
    anchor = 'play_round_progress' AND status = 'round_start' AND scene = 'words_pk',
    user_id, NULL)) FROM events
  UNION ALL SELECT 'core_play_speaking_pk_users', COUNT(DISTINCT IF(
    anchor = 'play_round_progress' AND status = 'round_start' AND scene = 'speaking_pk',
    user_id, NULL)) FROM events
),
daily AS (
  SELECT
    event_day,
    COUNT(DISTINCT IF(anchor = 'class_lesson_start', user_pseudo_id, NULL)) AS starts,
    COUNT(DISTINCT IF(anchor = 'trial_lesson_complete', user_pseudo_id, NULL)) AS completes
  FROM events
  WHERE event_day BETWEEN DATE_SUB(complete_day, INTERVAL 2 DAY) AND complete_day
  GROUP BY event_day
),
lesson_templates AS (
  SELECT
    template_id,
    COUNT(DISTINCT user_pseudo_id) AS users
  FROM events
  WHERE anchor IN ('class_stage_progress', 'class_stage_start', 'class_stage_end')
    AND lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
    AND template_id IS NOT NULL
  GROUP BY template_id
),
warmup_assign AS (
  SELECT
    user_pseudo_id,
    ARRAY_AGG(STRUCT(
      event_timestamp AS warmup_ts,
      lesson_id AS lesson_id,
      CASE
        WHEN lesson_id IN ('732', '1615') THEN 'l1l2'
        WHEN lesson_id IN ('734', '733') THEN 'l3l4'
        WHEN lesson_id IN ('1613', '1614') THEN 'l5l6'
      END AS level_group
    ) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_warmup
  FROM events
  WHERE anchor IN ('class_stage_progress', 'class_stage_start')
    AND lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
    AND STARTS_WITH(template_id, 'warm-up-template_')
  GROUP BY user_pseudo_id
),
lesson_stage_by_level AS (
  SELECT
    a.first_warmup.level_group AS level_group,
    CASE
      WHEN STARTS_WITH(e.template_id, 'warm-up-template_') THEN 'warmup'
      WHEN STARTS_WITH(e.template_id, 'lead-in-template_') THEN 'lead_in'
      WHEN e.template_id = 'play-video-template' THEN 'video'
      WHEN STARTS_WITH(e.template_id, 'word_teach') THEN 'word_teach'
      WHEN STARTS_WITH(e.template_id, 'word_practice') THEN 'word_practice'
      WHEN STARTS_WITH(e.template_id, 'practice_listen') THEN 'listening'
      WHEN STARTS_WITH(e.template_id, 'sentence_teach') THEN 'sentence_teach'
      WHEN STARTS_WITH(e.template_id, 'sentence_practice') THEN 'sentence_practice'
      WHEN STARTS_WITH(e.template_id, 'wrapup') THEN 'wrapup'
    END AS stage,
    COUNT(DISTINCT e.user_pseudo_id) AS users
  FROM warmup_assign a
  JOIN events e USING (user_pseudo_id)
  WHERE e.event_timestamp >= a.first_warmup.warmup_ts
    AND e.lesson_id = a.first_warmup.lesson_id
    AND (
      STARTS_WITH(e.template_id, 'warm-up-template_')
      OR STARTS_WITH(e.template_id, 'lead-in-template_')
      OR e.template_id = 'play-video-template'
      OR STARTS_WITH(e.template_id, 'word_teach')
      OR STARTS_WITH(e.template_id, 'word_practice')
      OR STARTS_WITH(e.template_id, 'practice_listen')
      OR STARTS_WITH(e.template_id, 'sentence_teach')
      OR STARTS_WITH(e.template_id, 'sentence_practice')
      OR STARTS_WITH(e.template_id, 'wrapup')
    )
  GROUP BY level_group, stage
)
SELECT metric, CAST(value AS STRING) AS value
FROM metrics
UNION ALL
SELECT CONCAT('daily_start_', CAST(event_day AS STRING)), CAST(starts AS STRING) FROM daily
UNION ALL
SELECT CONCAT('daily_complete_', CAST(event_day AS STRING)), CAST(completes AS STRING) FROM daily
UNION ALL
SELECT CONCAT('lesson_template|', template_id), CAST(users AS STRING) FROM lesson_templates
UNION ALL
SELECT CONCAT('lesson_stage|', level_group, '|', stage), CAST(users AS STRING) FROM lesson_stage_by_level
UNION ALL
SELECT 'warmup_users', CAST(SUM(users) AS STRING) FROM lesson_stage_by_level WHERE stage = 'warmup'
UNION ALL
SELECT 'lead_in_users', CAST(SUM(users) AS STRING) FROM lesson_stage_by_level WHERE stage = 'lead_in'
UNION ALL
SELECT 'cutoff', CAST(cutoff AS STRING)
UNION ALL
SELECT 'module_coverage_start', CAST(module_coverage_start AS STRING)
ORDER BY metric;
