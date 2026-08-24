-- Core Funnel Diagnostics by first-open country and selected UTC period.
-- The conversion funnel is cumulative and ordered within the selected period:
-- first_open -> signup success -> specified first-lesson start -> compatible completion.
-- D1 uses first-open cohorts inside the selected period and observes foreground activity
-- on the next UTC calendar day; only cohorts with a complete D1 window are included.

DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-24 03:01:17+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-23';

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS period_key, TIMESTAMP '2026-07-10 00:00:00+00' AS start_ts, cutoff AS end_ts),
    ('w1', TIMESTAMP '2026-07-10 00:00:00+00', TIMESTAMP '2026-07-17 00:00:00+00'),
    ('w2', TIMESTAMP '2026-07-17 00:00:00+00', TIMESTAMP '2026-07-24 00:00:00+00'),
    ('w3', TIMESTAMP '2026-07-24 00:00:00+00', TIMESTAMP '2026-07-31 00:00:00+00'),
    ('w4', TIMESTAMP '2026-07-31 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', TIMESTAMP '2026-08-21 00:00:00+00'),
    ('w7', TIMESTAMP '2026-08-21 00:00:00+00', cutoff)
  ])
),
country_targets AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS country_key, 0 AS country_order),
    ('vn', 1),
    ('kr', 2),
    ('sa', 3),
    ('my', 4),
    ('id', 5),
    ('th', 6)
  ])
),
raw_base AS (
  SELECT
    event_timestamp,
    event_name,
    user_pseudo_id,
    platform,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260822'

  UNION ALL

  SELECT
    event_timestamp,
    event_name,
    user_pseudo_id,
    platform,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260823' AND '20260824'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((
      SELECT up.value.string_value
      FROM UNNEST(user_properties) up
      WHERE up.key = 'user_type'
    )) = 'test'
),
events AS (
  SELECT
    r.event_timestamp,
    DATE(TIMESTAMP_MICROS(r.event_timestamp)) AS event_day,
    r.event_name,
    r.user_pseudo_id,
    r.platform,
    r.country,
    COALESCE((
      SELECT ep.value.string_value
      FROM UNNEST(r.event_params) ep
      WHERE ep.key = 'event_id'
    ), r.event_name) AS anchor,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS success_value,
    LOWER((
      SELECT ep.value.string_value
      FROM UNNEST(r.event_params) ep
      WHERE ep.key = 'result'
    )) AS result_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
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
  GROUP BY platform, user_pseudo_id
),
period_cohort AS (
  SELECT
    p.period_key,
    p.end_ts,
    f.platform,
    f.user_pseudo_id,
    f.first_open.first_open_ts,
    DATE(TIMESTAMP_MICROS(f.first_open.first_open_ts)) AS cohort_day,
    CASE f.first_open.first_open_country
      WHEN 'Vietnam' THEN 'vn'
      WHEN 'South Korea' THEN 'kr'
      WHEN 'Saudi Arabia' THEN 'sa'
      WHEN 'Malaysia' THEN 'my'
      WHEN 'Indonesia' THEN 'id'
      WHEN 'Thailand' THEN 'th'
      ELSE 'other'
    END AS country_key
  FROM first_opens f
  JOIN periods p
    ON f.first_open.first_open_ts >= UNIX_MICROS(p.start_ts)
   AND f.first_open.first_open_ts < UNIX_MICROS(p.end_ts)
),
registered AS (
  SELECT
    c.*,
    MIN(IF(
      e.anchor = 'signup_result'
      AND e.success_value IN ('true', '1', 'success')
      AND e.event_timestamp >= c.first_open_ts
      AND e.event_timestamp < UNIX_MICROS(c.end_ts),
      e.event_timestamp,
      NULL
    )) AS registered_ts
  FROM period_cohort c
  LEFT JOIN events e USING (platform, user_pseudo_id)
  GROUP BY
    c.period_key,
    c.end_ts,
    c.platform,
    c.user_pseudo_id,
    c.first_open_ts,
    c.cohort_day,
    c.country_key
),
lesson_started AS (
  SELECT
    r.*,
    ARRAY_AGG(IF(
      r.registered_ts IS NOT NULL
      AND e.anchor = 'class_lesson_start'
      AND e.lesson_id IN ('732', '1615', '734', '733', '1613', '1614', '1661', '1616')
      AND e.event_timestamp >= r.registered_ts
      AND e.event_timestamp < UNIX_MICROS(r.end_ts),
      STRUCT(e.event_timestamp AS start_ts, e.lesson_id AS lesson_id),
      NULL
    ) IGNORE NULLS ORDER BY e.event_timestamp LIMIT 1)[SAFE_OFFSET(0)] AS first_lesson
  FROM registered r
  LEFT JOIN events e USING (platform, user_pseudo_id)
  GROUP BY
    r.period_key,
    r.end_ts,
    r.platform,
    r.user_pseudo_id,
    r.first_open_ts,
    r.cohort_day,
    r.country_key,
    r.registered_ts
),
device_flags AS (
  SELECT
    s.period_key,
    s.country_key,
    s.platform,
    s.user_pseudo_id,
    s.cohort_day,
    s.registered_ts IS NOT NULL AS registered,
    s.first_lesson.start_ts IS NOT NULL AS lesson_started,
    EXISTS(
      SELECT 1
      FROM events e
      WHERE e.platform = s.platform
        AND e.user_pseudo_id = s.user_pseudo_id
        AND s.first_lesson.start_ts IS NOT NULL
        AND e.event_timestamp >= s.first_lesson.start_ts
        AND e.event_timestamp < UNIX_MICROS(s.end_ts)
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
    ) AS lesson_completed,
    s.cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY) AS d1_eligible,
    EXISTS(
      SELECT 1
      FROM events e
      WHERE e.platform = s.platform
        AND e.user_pseudo_id = s.user_pseudo_id
        AND e.event_day = DATE_ADD(s.cohort_day, INTERVAL 1 DAY)
        AND e.event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view')
    ) AS d1_retained
  FROM lesson_started s
),
scoped AS (
  SELECT * FROM device_flags

  UNION ALL

  SELECT
    period_key,
    'all' AS country_key,
    platform,
    user_pseudo_id,
    cohort_day,
    registered,
    lesson_started,
    lesson_completed,
    d1_eligible,
    d1_retained
  FROM device_flags
),
aggregated AS (
  SELECT
    period_key,
    country_key,
    COUNT(*) AS first_open,
    COUNTIF(registered) AS registered,
    COUNTIF(lesson_started) AS lesson_started,
    COUNTIF(lesson_completed) AS lesson_completed,
    COUNTIF(d1_eligible) AS d1_devices,
    COUNTIF(d1_eligible AND d1_retained) AS d1_retained
  FROM scoped
  WHERE country_key IN ('all', 'vn', 'kr', 'sa', 'my', 'id', 'th')
  GROUP BY period_key, country_key
)
SELECT
  p.period_key,
  c.country_key,
  COALESCE(a.first_open, 0) AS first_open,
  COALESCE(a.registered, 0) AS registered,
  COALESCE(a.lesson_started, 0) AS lesson_started,
  COALESCE(a.lesson_completed, 0) AS lesson_completed,
  COALESCE(a.d1_devices, 0) AS d1_devices,
  COALESCE(a.d1_retained, 0) AS d1_retained
FROM periods p
CROSS JOIN country_targets c
LEFT JOIN aggregated a USING (period_key, country_key)
ORDER BY
  CASE p.period_key
    WHEN 'all' THEN 0
    WHEN 'w1' THEN 1
    WHEN 'w2' THEN 2
    WHEN 'w3' THEN 3
    WHEN 'w4' THEN 4
    WHEN 'w5' THEN 5
    ELSE 6
  END,
  c.country_order;
