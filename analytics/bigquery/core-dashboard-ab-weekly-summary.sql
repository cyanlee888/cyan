-- Lightweight weekly A/B summary for the core dashboard.
-- Cohort: Android devices first stably assigned inside the selected interval.
-- Outcomes are observed through the interval end; first_open may precede assignment.
DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-17 02:15:00+00';

WITH weeks AS (
  SELECT * FROM UNNEST([
    STRUCT('w4' AS week_key, experiment_start AS start_ts, TIMESTAMP '2026-08-07 00:00:00+00' AS end_ts),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', cutoff)
  ])
),
raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, user_id, platform, geo.country AS country, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$') AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260815'
  UNION ALL
  SELECT event_timestamp,event_name,user_pseudo_id,user_id,platform,geo.country country,event_params,user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260816' AND '20260817'
),
test_devices AS (
  SELECT DISTINCT platform, user_pseudo_id FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key='user_type'))='test'
),
events AS (
  SELECT r.event_timestamp,r.event_name,r.user_pseudo_id,r.user_id,r.platform,r.country,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='event_id'),r.event_name) anchor,
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='content_id') content_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='channel')) channel,
    COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='lesson_id'),CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key='lesson_id') AS STRING)) lesson_id,
    LOWER(COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='is_success'),CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key='is_success') AS STRING),(SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='result'))) result_value
  FROM raw_base r LEFT JOIN test_devices t USING(platform,user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL AND r.event_timestamp<UNIX_MICROS(cutoff)
),
device_groups AS (
  SELECT platform,user_pseudo_id,MIN(event_timestamp) first_assigned_at,
    ARRAY_AGG(STRUCT(channel,country) ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] first_assignment,
    COUNT(DISTINCT channel) channel_count
  FROM events WHERE platform='ANDROID' AND event_name='trigger' AND anchor='experiment_group_assign' AND content_id='conv_funnel_v1'
  GROUP BY 1,2
),
stable AS (
  SELECT w.week_key,w.end_ts,d.platform,d.user_pseudo_id,d.first_assigned_at,d.first_assignment.channel experiment_group,d.first_assignment.country assignment_country
  FROM device_groups d JOIN weeks w ON d.first_assigned_at>=UNIX_MICROS(w.start_ts) AND d.first_assigned_at<UNIX_MICROS(w.end_ts)
  WHERE d.channel_count=1 AND d.first_assignment.channel IN('a','b')
),
flags AS (
  SELECT s.week_key,s.experiment_group,
    CASE s.assignment_country WHEN 'Vietnam' THEN 'vn' WHEN 'South Korea' THEN 'kr' WHEN 'Saudi Arabia' THEN 'sa' WHEN 'Malaysia' THEN 'my' WHEN 'Indonesia' THEN 'id' ELSE 'other' END country_key,
    s.user_pseudo_id,
    LOGICAL_OR(e.anchor='first_open') first_open,
    LOGICAL_OR(e.anchor='signup_result' AND e.result_value IN('true','1','success')) registered,
    LOGICAL_OR(e.anchor='class_lesson_start' AND e.lesson_id IN('732','1615','734','733','1613','1614')) a_start,
    LOGICAL_OR(e.anchor='trial_lesson_complete' OR (e.anchor='class_lesson_end' AND e.result_value='complete' AND e.lesson_id IN('732','1615','734','733','1613','1614'))) a_complete,
    LOGICAL_OR(e.anchor='class_lesson_start' AND e.lesson_id='1661') b_start,
    LOGICAL_OR(e.anchor='class_lesson_end' AND e.result_value='complete' AND e.lesson_id='1661') b_complete
  FROM stable s LEFT JOIN events e ON e.platform=s.platform AND e.user_pseudo_id=s.user_pseudo_id AND e.event_timestamp<UNIX_MICROS(s.end_ts)
  GROUP BY 1,2,3,4
),
scoped AS (
  SELECT * FROM flags UNION ALL SELECT week_key,experiment_group,'all',user_pseudo_id,first_open,registered,a_start,a_complete,b_start,b_complete FROM flags
)
SELECT week_key,country_key,experiment_group,
  COUNT(DISTINCT user_pseudo_id) assigned,
  COUNTIF(first_open) first_open,
  COUNTIF(registered) registered,
  COUNTIF(a_start) a_start,COUNTIF(a_complete) a_complete,COUNTIF(b_start) b_start,COUNTIF(b_complete) b_complete
FROM scoped WHERE country_key IN('all','vn','kr','sa','my','id')
GROUP BY 1,2,3 ORDER BY 1,2,3;
