-- Trial-lesson template reach by global period and device country.
-- Country is the geo.country of the device's earliest GA4 event in the reporting window.

DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-17 02:15:00+00';

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('all' AS period_key, TIMESTAMP '2026-07-10 00:00:00+00' AS start_ts, cutoff AS end_ts),
    ('w1', TIMESTAMP '2026-07-10 00:00:00+00', TIMESTAMP '2026-07-17 00:00:00+00'),
    ('w2', TIMESTAMP '2026-07-17 00:00:00+00', TIMESTAMP '2026-07-24 00:00:00+00'),
    ('w3', TIMESTAMP '2026-07-24 00:00:00+00', TIMESTAMP '2026-07-31 00:00:00+00'),
    ('w4', TIMESTAMP '2026-07-31 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', cutoff)
  ])
),
country_targets AS (
  SELECT * FROM UNNEST(['all','vn','kr','sa','my','id','th']) AS country_key
),
lesson_targets AS (
  SELECT * FROM UNNEST(['732','1615','734','733','1613','1614']) AS lesson_id
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
    r.user_pseudo_id,
    r.platform,
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
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'lesson_id') AS STRING)
    ) AS lesson_id,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'template_id'),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'block_template_id')
    ) AS template_id
  FROM raw_base r
  LEFT JOIN test_devices t USING (platform, user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
device_geo AS (
  SELECT
    platform,
    user_pseudo_id,
    ARRAY_AGG(STRUCT(event_timestamp AS first_event_ts, event_country_key AS country_key) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_geo
  FROM events
  GROUP BY platform, user_pseudo_id
),
first_warmup AS (
  SELECT
    p.period_key,
    p.end_ts,
    e.platform,
    e.user_pseudo_id,
    e.lesson_id,
    d.first_geo.country_key AS country_key,
    MIN(e.event_timestamp) AS warmup_ts
  FROM events e
  JOIN periods p
    ON e.event_timestamp >= UNIX_MICROS(p.start_ts)
   AND e.event_timestamp < UNIX_MICROS(p.end_ts)
  JOIN device_geo d USING (platform, user_pseudo_id)
  WHERE e.anchor IN ('class_stage_progress', 'class_stage_start')
    AND e.lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
    AND STARTS_WITH(e.template_id, 'warm-up-template_')
  GROUP BY p.period_key, p.end_ts, e.platform, e.user_pseudo_id, e.lesson_id, country_key
),
scoped_warmup AS (
  SELECT * FROM first_warmup WHERE country_key IN ('vn','kr','sa','my','id','th')
  UNION ALL
  SELECT period_key,end_ts,platform,user_pseudo_id,lesson_id,'all' AS country_key,warmup_ts FROM first_warmup
),
template_counts AS (
  SELECT
    w.period_key,
    w.country_key,
    e.lesson_id,
    e.template_id,
    COUNT(DISTINCT CONCAT(e.platform,':',e.user_pseudo_id)) AS users
  FROM scoped_warmup w
  JOIN events e USING (platform, user_pseudo_id, lesson_id)
  WHERE e.event_timestamp >= w.warmup_ts
    AND e.event_timestamp < UNIX_MICROS(w.end_ts)
    AND e.anchor IN ('class_stage_progress', 'class_stage_start', 'class_stage_end')
    AND e.template_id IS NOT NULL
  GROUP BY w.period_key, w.country_key, e.lesson_id, e.template_id
),
payloads AS (
  SELECT
    period_key,
    country_key,
    lesson_id,
    TO_JSON_STRING(ARRAY_AGG(STRUCT(template_id, users) ORDER BY users DESC, template_id)) AS payload
  FROM template_counts
  GROUP BY period_key, country_key, lesson_id
)
SELECT
  p.period_key,
  c.country_key,
  l.lesson_id,
  COALESCE(x.payload, '[]') AS payload
FROM periods p
CROSS JOIN country_targets c
CROSS JOIN lesson_targets l
LEFT JOIN payloads x USING (period_key, country_key, lesson_id)
ORDER BY
  CASE p.period_key WHEN 'all' THEN 0 WHEN 'w1' THEN 1 WHEN 'w2' THEN 2 WHEN 'w3' THEN 3 WHEN 'w4' THEN 4 WHEN 'w5' THEN 5 ELSE 6 END,
  c.country_key,
  CASE l.lesson_id WHEN '732' THEN 1 WHEN '1615' THEN 2 WHEN '734' THEN 3 WHEN '733' THEN 4 WHEN '1613' THEN 5 ELSE 6 END;
