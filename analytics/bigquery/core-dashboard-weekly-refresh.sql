-- Core dashboard calendar-week snapshots (UTC).
-- Week slices use events/orders occurring inside each selected interval.
-- A/B slices use devices first assigned in the week and observe their events through that week's end.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-24 03:01:17+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-23';
DECLARE module_coverage_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-07 00:00:00+00';

WITH weeks AS (
  SELECT * FROM UNNEST([
    STRUCT('w1' AS week_key, TIMESTAMP '2026-07-10 00:00:00+00' AS start_ts, TIMESTAMP '2026-07-17 00:00:00+00' AS end_ts),
    ('w2', TIMESTAMP '2026-07-17 00:00:00+00', TIMESTAMP '2026-07-24 00:00:00+00'),
    ('w3', TIMESTAMP '2026-07-24 00:00:00+00', TIMESTAMP '2026-07-31 00:00:00+00'),
    ('w4', TIMESTAMP '2026-07-31 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', TIMESTAMP '2026-08-21 00:00:00+00'),
    ('w7', TIMESTAMP '2026-08-21 00:00:00+00', cutoff)
  ])
),
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260822'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260823' AND '20260824'
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
    DATE(TIMESTAMP_MICROS(r.event_timestamp)) AS event_day,
    r.event_name,
    r.user_pseudo_id,
    r.user_id,
    r.platform,
    r.country,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'), r.event_name) AS anchor,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'content_id') AS content_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'channel')) AS channel,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'button_id') AS button_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'step_id'),
      SPLIT((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'content_id'), ':')[SAFE_OFFSET(0)]
    ) AS step_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'template_id'),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'block_template_id')
    ) AS template_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'firebase_screen_class') AS screen_class,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'source') AS source,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'subscription_source') AS subscription_source,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'dino_step') AS dino_step,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'dino_scene') AS dino_scene,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'status')) AS status,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'scene')) AS scene,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS result_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
weekly_events AS (
  SELECT w.week_key, w.start_ts, w.end_ts, e.*
  FROM weeks w
  JOIN events e
    ON e.event_timestamp >= UNIX_MICROS(w.start_ts)
   AND e.event_timestamp < UNIX_MICROS(w.end_ts)
),
weekly_first_lesson AS (
  SELECT
    week_key,
    user_pseudo_id,
    ARRAY_AGG(STRUCT(event_timestamp AS start_ts, lesson_id) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_lesson
  FROM weekly_events
  WHERE anchor = 'class_lesson_start'
    AND lesson_id IN ('732','1615','734','733','1613','1614','1661','1616')
  GROUP BY week_key, user_pseudo_id
),
weekly_first_lesson_result AS (
  SELECT
    f.week_key,
    f.user_pseudo_id,
    LOGICAL_OR(
      (e.anchor = 'class_lesson_end' AND e.lesson_id = f.first_lesson.lesson_id AND e.result_value = 'complete')
      OR (f.first_lesson.lesson_id IN ('732','1615','734','733','1613','1614') AND e.anchor = 'trial_lesson_complete')
    ) AS completed
  FROM weekly_first_lesson f
  LEFT JOIN weekly_events e
    ON e.week_key = f.week_key
   AND e.user_pseudo_id = f.user_pseudo_id
   AND e.event_timestamp >= f.first_lesson.start_ts
  GROUP BY 1,2
),
weekly_first_lesson_summary AS (
  SELECT week_key, COUNT(*) AS lesson_start, COUNTIF(completed) AS lesson_complete
  FROM weekly_first_lesson_result
  GROUP BY week_key
),
weekly_journey AS (
  SELECT
    w.week_key,
    COUNT(DISTINCT IF(e.event_name = 'first_open', e.user_pseudo_id, NULL)) AS first_open,
    COUNT(DISTINCT IF(e.anchor = 'signup_result' AND e.result_value IN ('true','1','success'), e.user_pseudo_id, NULL)) AS signup_success,
    ANY_VALUE(COALESCE(l.lesson_start, 0)) AS lesson_start,
    ANY_VALUE(COALESCE(l.lesson_complete, 0)) AS lesson_complete,
    ANY_VALUE(w.start_ts >= module_coverage_start) AS core_detail_available,
    COUNT(DISTINCT e.user_id) AS core_logged_in_users,
    COUNT(DISTINCT IF(
      e.anchor = 'class_lesson_start', e.user_id, NULL)) AS core_class_users,
    COUNT(DISTINCT IF(
      (e.anchor = 'dino_assistant_progress' AND e.dino_step = 'session_start') OR e.anchor = 'dino_session_start',
      e.user_id, NULL)) AS core_dino_users,
    COUNT(DISTINCT IF(
      (e.anchor = 'explore_practice_progress' AND e.status = 'start')
        OR (e.anchor = 'listening_play_progress' AND e.status = 'play_start'),
      e.user_id, NULL)) AS core_explore_users,
    COUNT(DISTINCT IF(
      e.anchor = 'explore_practice_progress' AND e.status = 'start',
      e.user_id, NULL)) AS core_explore_words_users,
    COUNT(DISTINCT IF(
      e.anchor = 'listening_play_progress' AND e.status = 'play_start',
      e.user_id, NULL)) AS core_explore_listening_users,
    COUNT(DISTINCT IF(
      e.anchor = 'play_round_progress' AND e.status = 'round_start'
      AND e.scene IN ('blind_box','words_pk','speaking_pk'),
      e.user_id, NULL)) AS core_play_users,
    COUNT(DISTINCT IF(
      e.anchor = 'play_round_progress' AND e.status = 'round_start' AND e.scene = 'blind_box',
      e.user_id, NULL)) AS core_play_blind_box_users,
    COUNT(DISTINCT IF(
      e.anchor = 'play_round_progress' AND e.status = 'round_start' AND e.scene = 'words_pk',
      e.user_id, NULL)) AS core_play_words_pk_users,
    COUNT(DISTINCT IF(
      e.anchor = 'play_round_progress' AND e.status = 'round_start' AND e.scene = 'speaking_pk',
      e.user_id, NULL)) AS core_play_speaking_pk_users
  FROM weeks w
  LEFT JOIN weekly_events e USING (week_key)
  LEFT JOIN weekly_first_lesson_summary l USING (week_key)
  GROUP BY w.week_key
),
weekly_warmup AS (
  SELECT
    week_key,
    user_pseudo_id,
    ARRAY_AGG(STRUCT(
      event_timestamp AS warmup_ts,
      lesson_id,
      CASE
        WHEN lesson_id IN ('732','1615') THEN 'l1l2'
        WHEN lesson_id IN ('734','733') THEN 'l3l4'
        ELSE 'l5l6'
      END AS level_group
    ) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_warmup
  FROM weekly_events
  WHERE anchor IN ('class_stage_progress','class_stage_start')
    AND lesson_id IN ('732','1615','734','733','1613','1614')
    AND STARTS_WITH(template_id, 'warm-up-template_')
  GROUP BY week_key, user_pseudo_id
),
weekly_lesson_stage AS (
  SELECT
    a.week_key,
    a.first_warmup.level_group AS level_group,
    CASE
      WHEN STARTS_WITH(e.template_id, 'warm-up-template_') THEN 'warmup'
      WHEN STARTS_WITH(e.template_id, 'lead-in-template_') THEN 'lead_in'
      WHEN e.template_id = 'play-video-template' THEN 'video'
      WHEN STARTS_WITH(e.template_id, 'word_teach') THEN 'word_teach'
      WHEN STARTS_WITH(e.template_id, 'word_practice') THEN 'word_practice'
      WHEN STARTS_WITH(e.template_id, 'sentence_teach') THEN 'sentence_teach'
      WHEN STARTS_WITH(e.template_id, 'sentence_practice') THEN 'sentence_practice'
      WHEN STARTS_WITH(e.template_id, 'wrapup') THEN 'wrapup'
    END AS stage,
    COUNT(DISTINCT e.user_pseudo_id) AS users
  FROM weekly_warmup a
  JOIN weekly_events e USING (week_key, user_pseudo_id)
  WHERE e.event_timestamp >= a.first_warmup.warmup_ts
    AND e.lesson_id = a.first_warmup.lesson_id
    AND (
      STARTS_WITH(e.template_id, 'warm-up-template_') OR STARTS_WITH(e.template_id, 'lead-in-template_')
      OR e.template_id = 'play-video-template' OR STARTS_WITH(e.template_id, 'word_teach')
      OR STARTS_WITH(e.template_id, 'word_practice') OR STARTS_WITH(e.template_id, 'sentence_teach')
      OR STARTS_WITH(e.template_id, 'sentence_practice') OR STARTS_WITH(e.template_id, 'wrapup')
    )
  GROUP BY 1,2,3
),
firsts AS (
  SELECT user_pseudo_id, MIN(event_day) AS cohort_day
  FROM events WHERE event_name = 'first_open'
  GROUP BY user_pseudo_id
),
activity AS (
  SELECT DISTINCT user_pseudo_id, event_day
  FROM events
  WHERE event_name IN ('session_start','user_engagement','screen_view','page_view')
),
first_day_behavior AS (
  SELECT
    f.user_pseudo_id,
    f.cohort_day,
    LOGICAL_OR(e.anchor = 'trial_lesson_complete') AS completed_trial,
    LOGICAL_OR(e.anchor = 'signup_result' AND e.result_value IN ('true','1','success')) AS registered
  FROM firsts f
  LEFT JOIN events e ON e.user_pseudo_id = f.user_pseudo_id AND e.event_day = f.cohort_day
  GROUP BY 1,2
),
weekly_retention AS (
  SELECT
    w.week_key,
    COUNT(DISTINCT f.user_pseudo_id) AS devices,
    COUNT(DISTINCT IF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 1 DAY), f.user_pseudo_id, NULL)) AS d1
  FROM weeks w
  LEFT JOIN firsts f ON f.cohort_day >= DATE(w.start_ts) AND f.cohort_day < DATE(w.end_ts)
    AND f.cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
  LEFT JOIN activity a USING (user_pseudo_id)
  GROUP BY w.week_key
),
weekly_retention_segment AS (
  SELECT
    w.week_key,
    CASE WHEN b.completed_trial THEN 'completed_trial' WHEN b.registered THEN 'registered_no_trial' ELSE 'not_registered' END AS segment,
    COUNT(DISTINCT b.user_pseudo_id) AS devices,
    COUNT(DISTINCT IF(a.event_day = DATE_ADD(b.cohort_day, INTERVAL 1 DAY), b.user_pseudo_id, NULL)) AS d1
  FROM weeks w
  JOIN first_day_behavior b ON b.cohort_day >= DATE(w.start_ts) AND b.cohort_day < DATE(w.end_ts)
    AND b.cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
  LEFT JOIN activity a USING (user_pseudo_id)
  GROUP BY 1,2
),
test_user_ids AS (
  SELECT DISTINCT r.user_id
  FROM raw_base r
  JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE r.user_id IS NOT NULL AND r.event_timestamp < UNIX_MICROS(cutoff)
),
weekly_orders AS (
  SELECT w.week_key, o.*
  FROM weeks w
  JOIN `dino-english-497507.de_ods.payment_order` o
    ON o.created_at >= w.start_ts AND o.created_at < w.end_ts
  LEFT JOIN test_user_ids t ON CAST(o.user_id AS STRING) = t.user_id
  WHERE t.user_id IS NULL
),
weekly_payment AS (
  SELECT
    w.week_key,
    COUNT(o.order_no) AS orders,
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
  FROM weeks w
  LEFT JOIN weekly_orders o USING (week_key)
  GROUP BY w.week_key
),
weekly_lesson_json AS (
  SELECT week_key, ARRAY_AGG(STRUCT(level_group, stage, users) ORDER BY level_group, stage) AS lesson_stages
  FROM weekly_lesson_stage
  GROUP BY week_key
),
weekly_retention_segment_json AS (
  SELECT week_key, ARRAY_AGG(STRUCT(segment, devices, d1) ORDER BY segment) AS retention_segments
  FROM weekly_retention_segment
  GROUP BY week_key
)
SELECT
  w.week_key,
  TO_JSON_STRING(STRUCT(
    j AS journey,
    module_coverage_start AS module_coverage_start,
    COALESCE(l.lesson_stages, []) AS lesson_stages,
    r AS retention,
    COALESCE(s.retention_segments, []) AS retention_segments,
    p AS payment
  )) AS payload
FROM weeks w
LEFT JOIN weekly_journey j USING (week_key)
LEFT JOIN weekly_retention r USING (week_key)
LEFT JOIN weekly_payment p USING (week_key)
LEFT JOIN weekly_lesson_json l USING (week_key)
LEFT JOIN weekly_retention_segment_json s USING (week_key)
ORDER BY w.week_key;
