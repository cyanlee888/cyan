-- B 组新人引导课（lesson_id=1661）课内环节漏斗
-- 口径：Android / iOS 分平台；conv_funnel_v1；首次稳定进组 >= 2026-08-01 00:00 UTC；
--      按 GA4 user_pseudo_id 去重，排除测试账号 / fallback / 多分组冲突；截至 2026-08-14 09:01 UTC。
-- 新版课中埋点使用 event_name=trigger，具体节点由 event_id 区分。

DECLARE experiment_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-14 09:01:00+00';

WITH raw_base AS (
  SELECT event_timestamp, event_name, user_pseudo_id, platform, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260730' AND '20260812'
  UNION ALL
  SELECT event_timestamp, event_name, user_pseudo_id, platform, event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260813' AND '20260814'
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
    AND r.event_timestamp < UNIX_MICROS(cutoff)
),
assignments AS (
  SELECT
    platform,
    user_pseudo_id,
    (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'channel') AS channel,
    event_timestamp
  FROM base
  WHERE platform IN ('ANDROID', 'IOS')
    AND event_name = 'trigger'
    AND (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'event_id') = 'experiment_group_assign'
    AND (SELECT p.value.string_value FROM UNNEST(event_params) p WHERE p.key = 'content_id') = 'conv_funnel_v1'
),
device_groups AS (
  SELECT
    platform,
    user_pseudo_id,
    MIN(event_timestamp) AS first_assigned_at,
    COUNT(DISTINCT channel) AS channel_count,
    ARRAY_AGG(channel ORDER BY event_timestamp LIMIT 1)[OFFSET(0)] AS first_channel
  FROM assignments
  WHERE user_pseudo_id IS NOT NULL
  GROUP BY platform, user_pseudo_id
),
stable_b AS (
  SELECT platform, user_pseudo_id
  FROM device_groups
  WHERE first_assigned_at >= UNIX_MICROS(experiment_start)
    AND channel_count = 1
    AND first_channel = 'b'
),
lesson_events AS (
  SELECT
    e.platform,
    e.user_pseudo_id,
    (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'event_id') AS event_id,
    (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'template_id') AS template_id,
    (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'result') AS result
  FROM base e
  JOIN stable_b b
    ON b.user_pseudo_id = e.user_pseudo_id
   AND b.platform = e.platform
  WHERE e.platform IN ('ANDROID', 'IOS')
    AND e.event_name = 'trigger'
    AND (SELECT p.value.string_value FROM UNNEST(e.event_params) p WHERE p.key = 'lesson_id') = '1661'
),
stage_def AS (
  SELECT *
  FROM UNNEST([
    STRUCT(1 AS step_order, '课堂导入' AS step_label, 'lead-in-template_l1l2' AS template_id),
    STRUCT(2 AS step_order, '视频示范' AS step_label, 'play-video-template' AS template_id),
    STRUCT(3 AS step_order, '单词教学' AS step_label, 'word_teach_image_l1l2' AS template_id),
    STRUCT(4 AS step_order, '单词练习' AS step_label, 'word_practice_bubble_image' AS template_id),
    STRUCT(5 AS step_order, '总结收尾' AS step_label, 'wrapup_summary_video_trail' AS template_id)
  ])
),
funnel AS (
  SELECT
    platform,
    0 AS step_order,
    '开始新人引导课' AS step_label,
    'class_lesson_start' AS event_anchor,
    COUNT(DISTINCT IF(event_id = 'class_lesson_start', user_pseudo_id, NULL)) AS reached_devices,
    CAST(NULL AS INT64) AS ended_devices
  FROM lesson_events
  GROUP BY platform

  UNION ALL

  SELECT
    e.platform,
    s.step_order,
    s.step_label,
    CONCAT('class_stage_start/end · ', s.template_id) AS event_anchor,
    COUNT(DISTINCT IF(e.event_id = 'class_stage_start', e.user_pseudo_id, NULL)) AS reached_devices,
    COUNT(DISTINCT IF(e.event_id = 'class_stage_end', e.user_pseudo_id, NULL)) AS ended_devices
  FROM stage_def s
  LEFT JOIN lesson_events e USING (template_id)
  GROUP BY e.platform, s.step_order, s.step_label, s.template_id

  UNION ALL

  SELECT
    platform,
    6 AS step_order,
    '完成新人引导课' AS step_label,
    'class_lesson_end · result=complete' AS event_anchor,
    COUNT(DISTINCT IF(event_id = 'class_lesson_end' AND result = 'complete', user_pseudo_id, NULL)) AS reached_devices,
    CAST(NULL AS INT64) AS ended_devices
  FROM lesson_events
  GROUP BY platform
)
SELECT *
FROM funnel
ORDER BY platform, step_order;
