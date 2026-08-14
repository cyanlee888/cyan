-- Six trial lessons, split by actual lesson/level and template_id.
-- Each lesson uses its own first warm-up as the denominator; later templates must occur
-- in the same lesson after that warm-up. This avoids merging levels with different nodes.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-14 15:08:00+00';

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
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^[0-9]{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260813'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX = '20260814'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
events AS (
  SELECT
    r.event_timestamp,
    r.user_pseudo_id,
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
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
first_warmup AS (
  SELECT
    p.period_key,
    p.end_ts,
    user_pseudo_id,
    lesson_id,
    MIN(event_timestamp) AS warmup_ts
  FROM events e
  JOIN periods p
    ON e.event_timestamp >= UNIX_MICROS(p.start_ts)
   AND e.event_timestamp < UNIX_MICROS(p.end_ts)
  WHERE anchor IN ('class_stage_progress', 'class_stage_start')
    AND lesson_id IN ('732', '1615', '734', '733', '1613', '1614')
    AND STARTS_WITH(template_id, 'warm-up-template_')
  GROUP BY p.period_key, p.end_ts, user_pseudo_id, lesson_id
),
template_counts AS (
  SELECT
    w.period_key,
    e.lesson_id,
    e.template_id,
    COUNT(DISTINCT e.user_pseudo_id) AS users
  FROM first_warmup w
  JOIN events e USING (user_pseudo_id, lesson_id)
  WHERE e.event_timestamp >= w.warmup_ts
    AND e.event_timestamp < UNIX_MICROS(w.end_ts)
    AND e.anchor IN ('class_stage_progress', 'class_stage_start', 'class_stage_end')
    AND e.template_id IS NOT NULL
  GROUP BY w.period_key, e.lesson_id, e.template_id
)
SELECT
  period_key,
  lesson_id,
  TO_JSON_STRING(ARRAY_AGG(STRUCT(template_id, users) ORDER BY users DESC, template_id)) AS payload
FROM template_counts
GROUP BY period_key, lesson_id
ORDER BY CASE period_key
    WHEN 'all' THEN 0 WHEN 'w1' THEN 1 WHEN 'w2' THEN 2 WHEN 'w3' THEN 3
    WHEN 'w4' THEN 4 WHEN 'w5' THEN 5 WHEN 'w6' THEN 6 END,
  CASE lesson_id
  WHEN '732' THEN 1 WHEN '1615' THEN 2 WHEN '734' THEN 3
  WHEN '733' THEN 4 WHEN '1613' THEN 5 WHEN '1614' THEN 6 END,
  lesson_id;
