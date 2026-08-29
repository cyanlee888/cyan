-- Device-level exact-day retention for first-open cohorts. 08-27 is the latest complete UTC day.
-- A return means the same user_pseudo_id emitted an explicit foreground-active event
-- (session_start / user_engagement / screen_view / page_view) on exactly cohort day + N.
-- Any device that reports user_properties.user_type=test is excluded from cohorts and returns.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-29 03:00:53+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-28';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260827'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260828' AND '20260829'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
base AS (
  SELECT r.event_timestamp, r.event_name, r.user_pseudo_id, r.event_params
  FROM raw_base r
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
),
events AS (
  SELECT
    DATE(TIMESTAMP_MICROS(event_timestamp)) AS event_day,
    user_pseudo_id,
    event_name,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'event_id'),
      event_name
    ) AS anchor,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
    )) AS success_value
  FROM base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND user_pseudo_id IS NOT NULL
),
firsts AS (
  SELECT user_pseudo_id, MIN(event_day) AS cohort_day
  FROM events
  WHERE event_name = 'first_open'
  GROUP BY user_pseudo_id
),
activity AS (
  SELECT DISTINCT user_pseudo_id, event_day
  FROM events
  WHERE event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view')
),
first_day_behavior AS (
  SELECT
    f.user_pseudo_id,
    f.cohort_day,
    LOGICAL_OR(e.anchor = 'trial_lesson_complete') AS completed_trial,
    LOGICAL_OR(e.anchor = 'signup_result' AND e.success_value IN ('true','1','success')) AS registered
  FROM firsts f
  LEFT JOIN events e
    ON e.user_pseudo_id = f.user_pseudo_id
   AND e.event_day = f.cohort_day
  GROUP BY 1,2
),
cohort AS (
  SELECT
    f.cohort_day,
    COUNT(DISTINCT f.user_pseudo_id) AS devices,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 1 DAY)) AS d1,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 2 DAY)) AS d2,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 3 DAY)) AS d3,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 4 DAY)) AS d4,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 5 DAY)) AS d5,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 6 DAY)) AS d6,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 7 DAY)) AS d7
  FROM firsts f
  LEFT JOIN activity a USING (user_pseudo_id)
  WHERE f.cohort_day BETWEEN DATE '2026-07-10' AND complete_day
  GROUP BY f.cohort_day
),
segments AS (
  SELECT
    CASE
      WHEN b.completed_trial THEN 'completed_trial'
      WHEN b.registered THEN 'registered_no_trial'
      ELSE 'not_registered'
    END AS segment,
    COUNT(DISTINCT b.user_pseudo_id) AS devices,
    COUNTIF(a.event_day = DATE_ADD(b.cohort_day, INTERVAL 1 DAY)) AS d1
  FROM first_day_behavior b
  LEFT JOIN activity a USING (user_pseudo_id)
  WHERE b.cohort_day BETWEEN DATE '2026-07-10' AND DATE_SUB(complete_day, INTERVAL 1 DAY)
  GROUP BY segment
),
curve AS (
  SELECT 'd1' AS period, SUM(devices) AS devices, SUM(d1) AS retained
  FROM cohort WHERE cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
  UNION ALL
  SELECT 'd3', SUM(devices), SUM(d3)
  FROM cohort WHERE cohort_day <= DATE_SUB(complete_day, INTERVAL 3 DAY)
  UNION ALL
  SELECT 'd7', SUM(devices), SUM(d7)
  FROM cohort WHERE cohort_day <= DATE_SUB(complete_day, INTERVAL 7 DAY)
)
SELECT
  'cohort' AS row_type,
  CAST(cohort_day AS STRING) AS row_key,
  devices,
  IF(DATE_ADD(cohort_day, INTERVAL 1 DAY) <= complete_day, d1, NULL) AS v1,
  IF(DATE_ADD(cohort_day, INTERVAL 2 DAY) <= complete_day, d2, NULL) AS v2,
  IF(DATE_ADD(cohort_day, INTERVAL 3 DAY) <= complete_day, d3, NULL) AS v3,
  IF(DATE_ADD(cohort_day, INTERVAL 4 DAY) <= complete_day, d4, NULL) AS v4,
  IF(DATE_ADD(cohort_day, INTERVAL 5 DAY) <= complete_day, d5, NULL) AS v5,
  IF(DATE_ADD(cohort_day, INTERVAL 6 DAY) <= complete_day, d6, NULL) AS v6,
  IF(DATE_ADD(cohort_day, INTERVAL 7 DAY) <= complete_day, d7, NULL) AS v7
FROM cohort
WHERE cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
UNION ALL
SELECT 'segment', segment, devices, d1, NULL, NULL, NULL, NULL, NULL, NULL FROM segments
UNION ALL
SELECT 'curve', period, devices, retained, NULL, NULL, NULL, NULL, NULL, NULL FROM curve
ORDER BY row_type, row_key;
