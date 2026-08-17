-- Exact-day retention cohorts and D1 day-0 behavior segments by country.
-- Country is geo.country on the device's first_open event.

DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-17 02:15:00+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-16';

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS period_key, DATE '2026-07-10' AS start_day, DATE '2026-08-17' AS end_day),
    ('w1', DATE '2026-07-10', DATE '2026-07-17'),
    ('w2', DATE '2026-07-17', DATE '2026-07-24'),
    ('w3', DATE '2026-07-24', DATE '2026-07-31'),
    ('w4', DATE '2026-07-31', DATE '2026-08-07'),
    ('w5', DATE '2026-08-07', DATE '2026-08-14'),
    ('w6', DATE '2026-08-14', DATE '2026-08-17')
  ])
),
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260815'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, platform, geo.country AS country, event_params, user_properties
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
    r.event_timestamp,
    DATE(TIMESTAMP_MICROS(r.event_timestamp)) AS event_day,
    r.user_pseudo_id,
    r.platform,
    r.event_name,
    CASE r.country
      WHEN 'Vietnam' THEN 'vn'
      WHEN 'South Korea' THEN 'kr'
      WHEN 'Saudi Arabia' THEN 'sa'
      WHEN 'Malaysia' THEN 'my'
      WHEN 'Indonesia' THEN 'id'
      WHEN 'Thailand' THEN 'th'
      ELSE 'other'
    END AS event_country_key,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'), r.event_name) AS anchor,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS success_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
    AND r.user_pseudo_id IS NOT NULL
),
firsts AS (
  SELECT
    platform,
    user_pseudo_id,
    ARRAY_AGG(STRUCT(event_day AS cohort_day, event_country_key AS country_key) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_open
  FROM events
  WHERE event_name = 'first_open'
  GROUP BY platform, user_pseudo_id
),
scoped_firsts AS (
  SELECT platform,user_pseudo_id,first_open.cohort_day,first_open.country_key
  FROM firsts
  WHERE first_open.country_key IN ('vn','kr','sa','my','id','th')
  UNION ALL
  SELECT platform,user_pseudo_id,first_open.cohort_day,'all' AS country_key FROM firsts
),
activity AS (
  SELECT DISTINCT platform,user_pseudo_id,event_day
  FROM events
  WHERE event_name IN ('session_start','user_engagement','screen_view','page_view')
),
first_day_behavior AS (
  SELECT
    f.platform,
    f.user_pseudo_id,
    f.cohort_day,
    f.country_key,
    LOGICAL_OR(e.anchor = 'trial_lesson_complete') AS completed_trial,
    LOGICAL_OR(e.anchor = 'signup_result' AND e.success_value IN ('true','1','success')) AS registered
  FROM scoped_firsts f
  LEFT JOIN events e
    ON e.platform = f.platform
   AND e.user_pseudo_id = f.user_pseudo_id
   AND e.event_day = f.cohort_day
  GROUP BY 1,2,3,4
),
cohort AS (
  SELECT
    f.country_key,
    f.cohort_day,
    COUNT(DISTINCT CONCAT(f.platform,':',f.user_pseudo_id)) AS devices,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 1 DAY)) AS d1,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 2 DAY)) AS d2,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 3 DAY)) AS d3,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 4 DAY)) AS d4,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 5 DAY)) AS d5,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 6 DAY)) AS d6,
    COUNTIF(a.event_day = DATE_ADD(f.cohort_day, INTERVAL 7 DAY)) AS d7
  FROM scoped_firsts f
  LEFT JOIN activity a USING (platform,user_pseudo_id)
  WHERE f.cohort_day BETWEEN DATE '2026-07-10' AND complete_day
  GROUP BY f.country_key,f.cohort_day
),
segments AS (
  SELECT
    p.period_key,
    b.country_key,
    CASE WHEN b.completed_trial THEN 'completed_trial' WHEN b.registered THEN 'registered_no_trial' ELSE 'not_registered' END AS segment,
    COUNT(DISTINCT CONCAT(b.platform,':',b.user_pseudo_id)) AS devices,
    COUNTIF(a.event_day = DATE_ADD(b.cohort_day, INTERVAL 1 DAY)) AS d1
  FROM periods p
  JOIN first_day_behavior b
    ON b.cohort_day >= p.start_day
   AND b.cohort_day < p.end_day
   AND b.cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
  LEFT JOIN activity a USING (platform,user_pseudo_id)
  GROUP BY p.period_key,b.country_key,segment
),
cohort_rows AS (
  SELECT
    'cohort' AS row_type,
    'all' AS period_key,
    country_key,
    CAST(cohort_day AS STRING) AS row_key,
    devices,
    IF(DATE_ADD(cohort_day, INTERVAL 1 DAY) <= complete_day,d1,NULL) AS v1,
    IF(DATE_ADD(cohort_day, INTERVAL 2 DAY) <= complete_day,d2,NULL) AS v2,
    IF(DATE_ADD(cohort_day, INTERVAL 3 DAY) <= complete_day,d3,NULL) AS v3,
    IF(DATE_ADD(cohort_day, INTERVAL 4 DAY) <= complete_day,d4,NULL) AS v4,
    IF(DATE_ADD(cohort_day, INTERVAL 5 DAY) <= complete_day,d5,NULL) AS v5,
    IF(DATE_ADD(cohort_day, INTERVAL 6 DAY) <= complete_day,d6,NULL) AS v6,
    IF(DATE_ADD(cohort_day, INTERVAL 7 DAY) <= complete_day,d7,NULL) AS v7
  FROM cohort
  WHERE cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
),
segment_rows AS (
  SELECT
    'segment' AS row_type,
    period_key,
    country_key,
    segment AS row_key,
    devices,
    d1 AS v1,
    CAST(NULL AS INT64) AS v2,
    CAST(NULL AS INT64) AS v3,
    CAST(NULL AS INT64) AS v4,
    CAST(NULL AS INT64) AS v5,
    CAST(NULL AS INT64) AS v6,
    CAST(NULL AS INT64) AS v7
  FROM segments
)
SELECT * FROM cohort_rows
UNION ALL
SELECT * FROM segment_rows
ORDER BY row_type,period_key,country_key,row_key;
