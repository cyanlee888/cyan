-- 详细数据工作台：V1.5.1 签到欢迎礼核心数据刷新。
-- 业务口径只纳入五个核心国家（越南、韩国、沙特、马来西亚、印度尼西亚），
-- 活动同时覆盖新注册与既有注册用户；排除 user_type=test、debug_event=1，
-- 并按账号去重；时间统一使用 UTC。新注册账号仅作为单独分析子群。
-- 当前线上只发现 newcomer_checkin_reward_grant 与 newcomer_visit_reward_entry，
-- PRD 中 unlock / calendar / claim / continue / close 事件暂未进入 GA4，不能计算完整曝光领取漏斗。
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-29 03:00:53+00';
DECLARE complete_day DATE DEFAULT DATE '2026-08-28';
DECLARE feature_start_day DATE DEFAULT DATE '2026-08-08';

CREATE TEMP TABLE raw_events AS
WITH raw_base AS (
  SELECT
    event_timestamp, event_name, user_pseudo_id, user_id, platform,
    app_info.version AS app_version, geo.country AS country,
    event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260801' AND '20260827'
  UNION ALL
  SELECT
    event_timestamp, event_name, user_pseudo_id, user_id, platform,
    app_info.version AS app_version, geo.country AS country,
    event_params, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260828' AND '20260829'
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE event_timestamp < UNIX_MICROS(cutoff)
    AND user_pseudo_id IS NOT NULL
    AND LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
test_accounts AS (
  SELECT DISTINCT COALESCE(
    NULLIF(user_id, ''),
    NULLIF((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'uid'), '')
  ) AS account_id
  FROM raw_base r
  JOIN test_devices t USING (user_pseudo_id)
  WHERE event_timestamp < UNIX_MICROS(cutoff)
)
SELECT
  TIMESTAMP_MICROS(r.event_timestamp) AS event_ts,
  DATE(TIMESTAMP_MICROS(r.event_timestamp)) AS event_day,
  r.event_name,
  r.user_pseudo_id,
  COALESCE(
    NULLIF(r.user_id, ''),
    NULLIF((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'uid'), '')
  ) AS account_id,
  r.platform,
  r.app_version,
  r.country,
  COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'),
    r.event_name
  ) AS anchor,
  (SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'content_index') AS content_index,
  COALESCE(
    (SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
    SAFE_CAST((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS INT64)
  ) AS is_success,
  LOWER(COALESCE(
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
    CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
    (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
  )) AS success_value,
  (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'source') AS source,
  COALESCE((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'debug_event'), 0) AS debug_event
FROM raw_base r
LEFT JOIN test_devices td USING (user_pseudo_id)
LEFT JOIN test_accounts ta ON ta.account_id = COALESCE(
  NULLIF(r.user_id, ''),
  NULLIF((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'uid'), '')
)
WHERE r.event_timestamp < UNIX_MICROS(cutoff)
  AND td.user_pseudo_id IS NULL
  AND ta.account_id IS NULL;

CREATE TEMP TABLE reward_events AS
SELECT *,
  country IN ('Vietnam', 'South Korea', 'Saudi Arabia', 'Malaysia', 'Indonesia') AS is_core_country
FROM raw_events
WHERE debug_event = 0
  AND anchor IN ('newcomer_checkin_reward_grant', 'newcomer_visit_reward_entry');

CREATE TEMP TABLE grants AS
SELECT *
FROM reward_events
WHERE anchor = 'newcomer_checkin_reward_grant'
  AND account_id IS NOT NULL;

CREATE TEMP TABLE successful_core_grants AS
SELECT *
FROM grants
WHERE is_core_country AND is_success = 1;

CREATE TEMP TABLE day1_cohorts AS
SELECT
  account_id,
  MIN(event_ts) AS first_grant_ts,
  MIN(event_day) AS cohort_day,
  ARRAY_AGG(country IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS country,
  ARRAY_AGG(platform IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS platform
FROM successful_core_grants
WHERE content_index = 1
GROUP BY account_id;

CREATE TEMP TABLE reward_devices AS
SELECT DISTINCT account_id, user_pseudo_id
FROM successful_core_grants
WHERE user_pseudo_id IS NOT NULL;

CREATE TEMP TABLE account_activity AS
SELECT DISTINCT account_id, event_day
FROM raw_events
WHERE account_id IS NOT NULL
  AND event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view')
UNION DISTINCT
SELECT DISTINCT d.account_id, e.event_day
FROM reward_devices d
JOIN raw_events e USING (user_pseudo_id)
WHERE e.event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view');

-- Participation denominator proxy (new and existing users): identifiable signed-in accounts
-- with a foreground-active event in the five core countries. Accounts with a successful Day1
-- grant but no foreground anchor are added back because the grant itself proves participation.
CREATE TEMP TABLE foreground_days AS
SELECT
  account_id,
  event_day,
  ARRAY_AGG(country IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS country,
  ARRAY_AGG(platform IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS platform
FROM raw_events
WHERE account_id IS NOT NULL
  AND platform IN ('ANDROID', 'IOS')
  AND country IN ('Vietnam', 'South Korea', 'Saudi Arabia', 'Malaysia', 'Indonesia')
  AND event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view')
  AND event_day BETWEEN feature_start_day AND DATE(cutoff)
GROUP BY account_id, event_day;

CREATE TEMP TABLE eligible_accounts AS
SELECT
  account_id,
  ARRAY_AGG(country IGNORE NULLS ORDER BY event_day LIMIT 1)[SAFE_OFFSET(0)] AS country,
  ARRAY_AGG(platform IGNORE NULLS ORDER BY event_day LIMIT 1)[SAFE_OFFSET(0)] AS platform
FROM foreground_days
GROUP BY account_id
UNION ALL
SELECT c.account_id, c.country, c.platform
FROM day1_cohorts c
WHERE NOT EXISTS (SELECT 1 FROM foreground_days f WHERE f.account_id = c.account_id);

CREATE TEMP TABLE eligible_days AS
SELECT account_id, event_day, country, platform FROM foreground_days
UNION ALL
SELECT c.account_id, c.cohort_day, c.country, c.platform
FROM day1_cohorts c
WHERE NOT EXISTS (
  SELECT 1 FROM foreground_days f
  WHERE f.account_id = c.account_id AND f.event_day = c.cohort_day
);

CREATE TEMP TABLE foreground_all AS
SELECT DISTINCT account_id, event_day
FROM raw_events
WHERE account_id IS NOT NULL
  AND platform IN ('ANDROID', 'IOS')
  AND country IN ('Vietnam', 'South Korea', 'Saudi Arabia', 'Malaysia', 'Indonesia')
  AND event_name IN ('session_start', 'user_engagement', 'screen_view', 'page_view')
  AND event_day BETWEEN DATE '2026-08-01' AND complete_day;

CREATE TEMP TABLE signup_cohorts AS
SELECT
  account_id,
  MIN(event_day) AS signup_day,
  ARRAY_AGG(country IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS country,
  ARRAY_AGG(platform IGNORE NULLS ORDER BY event_ts LIMIT 1)[SAFE_OFFSET(0)] AS platform
FROM raw_events
WHERE account_id IS NOT NULL
  AND country IN ('Vietnam', 'South Korea', 'Saudi Arabia', 'Malaysia', 'Indonesia')
  AND event_day >= feature_start_day
  AND anchor = 'signup_result'
  AND success_value IN ('true', '1', 'success')
GROUP BY account_id;

CREATE TEMP TABLE signup_prepost AS
SELECT
  account_id,
  MIN(event_day) AS signup_day
FROM raw_events
WHERE account_id IS NOT NULL
  AND country IN ('Vietnam', 'South Korea', 'Saudi Arabia', 'Malaysia', 'Indonesia')
  AND event_day BETWEEN DATE '2026-08-01' AND DATE '2026-08-10'
  AND anchor = 'signup_result'
  AND success_value IN ('true', '1', 'success')
GROUP BY account_id;

CREATE TEMP TABLE participant_strata AS
SELECT
  c.cohort_day,
  c.country,
  c.platform,
  COUNT(*) AS participant_accounts,
  COUNTIF(EXISTS (
    SELECT 1 FROM account_activity a
    WHERE a.account_id = c.account_id
      AND a.event_day = DATE_ADD(c.cohort_day, INTERVAL 1 DAY)
  )) AS participant_d1
FROM day1_cohorts c
WHERE c.cohort_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
GROUP BY c.cohort_day, c.country, c.platform;

CREATE TEMP TABLE control_strata AS
SELECT
  a.event_day AS cohort_day,
  a.country,
  a.platform,
  COUNT(DISTINCT a.account_id) AS control_accounts,
  COUNT(DISTINCT IF(EXISTS (
    SELECT 1 FROM account_activity d1
    WHERE d1.account_id = a.account_id
      AND d1.event_day = DATE_ADD(a.event_day, INTERVAL 1 DAY)
  ), a.account_id, NULL)) AS control_d1
FROM foreground_days a
WHERE a.event_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
  AND NOT EXISTS (
    SELECT 1 FROM grants g
    WHERE g.account_id = a.account_id AND g.is_success = 1
  )
GROUP BY a.event_day, a.country, a.platform;

CREATE TEMP TABLE retention_impact AS
SELECT
  SUM(p.participant_accounts) AS participant_accounts,
  SUM(p.participant_d1) AS participant_d1,
  SUM(c.control_accounts) AS control_observations,
  SUM(c.control_d1) AS control_d1,
  SUM(p.participant_accounts * SAFE_DIVIDE(c.control_d1, c.control_accounts))
    / SUM(p.participant_accounts) * 100 AS standardized_control_rate
FROM participant_strata p
JOIN control_strata c USING (cohort_day, country, platform)
WHERE c.control_accounts > 0;

CREATE TEMP TABLE signup_impact AS
SELECT
  IF(EXISTS (
    SELECT 1 FROM day1_cohorts r
    WHERE r.account_id = s.account_id AND r.cohort_day = s.signup_day
  ), 'participated', 'not_participated') AS segment,
  COUNT(*) AS accounts,
  COUNTIF(EXISTS (
    SELECT 1 FROM account_activity a
    WHERE a.account_id = s.account_id
      AND a.event_day = DATE_ADD(s.signup_day, INTERVAL 1 DAY)
  )) AS d1
FROM signup_cohorts s
WHERE s.signup_day <= DATE_SUB(complete_day, INTERVAL 1 DAY)
GROUP BY segment;

CREATE TEMP TABLE signup_prepost_impact AS
SELECT
  IF(signup_day < feature_start_day, 'pre_0801_0807', 'post_0808_0810') AS period,
  COUNT(*) AS accounts,
  COUNTIF(EXISTS (
    SELECT 1 FROM foreground_all a
    WHERE a.account_id = s.account_id
      AND a.event_day = DATE_ADD(s.signup_day, INTERVAL 1 DAY)
  )) AS d1
FROM signup_prepost s
GROUP BY 1;

CREATE TEMP TABLE progression AS
SELECT
  target_index,
  COUNTIF(c.cohort_day <= DATE_SUB(complete_day, INTERVAL (target_index - 1) DAY)) AS mature_accounts,
  COUNTIF(
    c.cohort_day <= DATE_SUB(complete_day, INTERVAL (target_index - 1) DAY)
    AND EXISTS (
      SELECT 1 FROM successful_core_grants g
      WHERE g.account_id = c.account_id AND g.content_index >= target_index
    )
  ) AS reached_accounts
FROM day1_cohorts c
CROSS JOIN UNNEST([2,3,4,5,8]) AS target_index
GROUP BY target_index;

CREATE TEMP TABLE reward_retention AS
SELECT
  day_n,
  COUNTIF(c.cohort_day <= DATE_SUB(complete_day, INTERVAL day_n DAY)) AS mature_accounts,
  COUNTIF(
    c.cohort_day <= DATE_SUB(complete_day, INTERVAL day_n DAY)
    AND EXISTS (
      SELECT 1 FROM account_activity a
      WHERE a.account_id = c.account_id
        AND a.event_day = DATE_ADD(c.cohort_day, INTERVAL day_n DAY)
    )
  ) AS retained_accounts
FROM day1_cohorts c
CROSS JOIN UNNEST([1,3,7]) AS day_n
GROUP BY day_n;

CREATE TEMP TABLE learning_paths AS
SELECT
  c.*,
  (
    SELECT MIN(e.event_ts)
    FROM raw_events e
    WHERE e.account_id = c.account_id
      AND e.event_ts BETWEEN c.first_grant_ts AND TIMESTAMP_ADD(c.first_grant_ts, INTERVAL 24 HOUR)
      AND e.anchor = 'class_lesson_start'
  ) AS lesson_start_ts
FROM day1_cohorts c
WHERE c.first_grant_ts <= TIMESTAMP_SUB(cutoff, INTERVAL 24 HOUR);

CREATE TEMP TABLE learning_24h AS
SELECT
  COUNT(*) AS mature_accounts,
  COUNTIF(lesson_start_ts IS NOT NULL) AS lesson_start_accounts,
  COUNTIF(
    lesson_start_ts IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM raw_events e
      WHERE e.account_id = c.account_id
        AND e.event_ts BETWEEN c.lesson_start_ts AND TIMESTAMP_ADD(c.first_grant_ts, INTERVAL 24 HOUR)
        AND (e.anchor = 'trial_lesson_complete' OR e.anchor = 'class_lesson_end')
    )
  ) AS lesson_complete_accounts
FROM learning_paths c;

CREATE TEMP TABLE duplicate_grants AS
SELECT
  COUNTIF(event_count > 1) AS repeated_account_nodes,
  COALESCE(SUM(IF(event_count > 1, event_count - 1, 0)), 0) AS extra_success_events
FROM (
  SELECT account_id, content_index, COUNT(*) AS event_count
  FROM successful_core_grants
  GROUP BY account_id, content_index
);

-- 单表输出，便于刷新 HTML。v1 / v2 / v3 的含义由 row_type 决定。
SELECT
  'summary' AS row_type,
  'grant' AS row_key,
  '成功发放账号 / 事件 / Day1账号' AS label,
  COUNT(DISTINCT account_id) AS v1,
  COUNT(*) AS v2,
  COUNT(DISTINCT IF(content_index = 1, account_id, NULL)) AS v3,
  SAFE_DIVIDE(COUNTIF(is_success = 1), COUNT(*)) * 100 AS rate
FROM grants
WHERE is_core_country

UNION ALL
SELECT
  'summary', 'entry', '首页入口点击账号 / 事件 / 领取账号覆盖率',
  COUNT(DISTINCT account_id), COUNT(*),
  COUNT(DISTINCT IF(account_id IN (SELECT DISTINCT account_id FROM successful_core_grants), account_id, NULL)),
  SAFE_DIVIDE(
    COUNT(DISTINCT IF(account_id IN (SELECT DISTINCT account_id FROM successful_core_grants), account_id, NULL)),
    (SELECT COUNT(DISTINCT account_id) FROM successful_core_grants)
  ) * 100
FROM reward_events
WHERE anchor = 'newcomer_visit_reward_entry' AND is_core_country AND account_id IS NOT NULL

UNION ALL
SELECT
  'summary', 'learning_24h', 'Day1领取后24h进课 / 完课 / 可观察账号',
  lesson_start_accounts, lesson_complete_accounts, mature_accounts,
  SAFE_DIVIDE(lesson_start_accounts, mature_accounts) * 100
FROM learning_24h

UNION ALL
SELECT
  'summary', 'duplicate', '重复账号节点 / 多余成功事件 / 成功事件总数',
  repeated_account_nodes, extra_success_events, (SELECT COUNT(*) FROM successful_core_grants),
  SAFE_DIVIDE(extra_success_events, (SELECT COUNT(*) FROM successful_core_grants)) * 100
FROM duplicate_grants

UNION ALL
SELECT
  'participation', 'overall', '可识别活跃账号（含新老用户） / Day1参与账号 / 任意领取账号',
  (SELECT COUNT(*) FROM eligible_accounts),
  (SELECT COUNT(*) FROM day1_cohorts),
  (SELECT COUNT(DISTINCT account_id) FROM successful_core_grants),
  SAFE_DIVIDE((SELECT COUNT(*) FROM day1_cohorts), (SELECT COUNT(*) FROM eligible_accounts)) * 100

UNION ALL
SELECT
  'participation', 'new_signup', '新注册账号 / 窗口内参与 / 注册同日参与',
  COUNT(*),
  COUNTIF(EXISTS (SELECT 1 FROM day1_cohorts r WHERE r.account_id = s.account_id)),
  COUNTIF(EXISTS (
    SELECT 1 FROM day1_cohorts r
    WHERE r.account_id = s.account_id AND r.cohort_day = s.signup_day
  )),
  SAFE_DIVIDE(
    COUNTIF(EXISTS (SELECT 1 FROM day1_cohorts r WHERE r.account_id = s.account_id)),
    COUNT(*)
  ) * 100
FROM signup_cohorts s

UNION ALL
SELECT
  'impact', 'matched_participant', '同日 × 国家 × 平台：参与账号 D1',
  participant_accounts, participant_d1, NULL,
  SAFE_DIVIDE(participant_d1, participant_accounts) * 100
FROM retention_impact

UNION ALL
SELECT
  'impact', 'matched_control', '同日 × 国家 × 平台：未参与账号标准化 D1',
  control_observations, control_d1, NULL, standardized_control_rate
FROM retention_impact

UNION ALL
SELECT
  'signup_impact', segment,
  CONCAT('新注册账号 D1 · ', segment),
  accounts, d1, NULL,
  SAFE_DIVIDE(d1, accounts) * 100
FROM signup_impact

UNION ALL
SELECT
  'prepost', period,
  CONCAT('全量新注册 D1 · ', period),
  accounts, d1, NULL,
  SAFE_DIVIDE(d1, accounts) * 100
FROM signup_prepost_impact

UNION ALL
SELECT
  'participation_country', e.country, e.country,
  COUNT(DISTINCT e.account_id),
  COUNT(DISTINCT r.account_id),
  NULL,
  SAFE_DIVIDE(COUNT(DISTINCT r.account_id), COUNT(DISTINCT e.account_id)) * 100
FROM eligible_accounts e
LEFT JOIN day1_cohorts r ON r.account_id = e.account_id AND r.country = e.country
GROUP BY e.country

UNION ALL
SELECT
  'participation_daily', CAST(e.event_day AS STRING), CAST(e.event_day AS STRING),
  COUNT(DISTINCT e.account_id),
  COUNT(DISTINCT r.account_id),
  NULL,
  SAFE_DIVIDE(COUNT(DISTINCT r.account_id), COUNT(DISTINCT e.account_id)) * 100
FROM eligible_days e
LEFT JOIN day1_cohorts r ON r.account_id = e.account_id AND r.cohort_day = e.event_day
GROUP BY e.event_day

UNION ALL
SELECT
  'progress', CAST(target_index AS STRING), CONCAT('到访节点 ', CAST(target_index AS STRING)),
  reached_accounts, mature_accounts, NULL,
  SAFE_DIVIDE(reached_accounts, mature_accounts) * 100
FROM progression

UNION ALL
SELECT
  'retention', CONCAT('d', CAST(day_n AS STRING)), CONCAT('领取账号 D', CAST(day_n AS STRING), ' Exact-day 活跃'),
  retained_accounts, mature_accounts, NULL,
  SAFE_DIVIDE(retained_accounts, mature_accounts) * 100
FROM reward_retention

UNION ALL
SELECT
  'content', CAST(g.content_index AS STRING), CONCAT('节点 ', CAST(g.content_index AS STRING)),
  COUNT(DISTINCT account_id), COUNT(*), NULL,
  SAFE_DIVIDE(COUNT(DISTINCT account_id), (SELECT COUNT(DISTINCT account_id) FROM day1_cohorts)) * 100
FROM successful_core_grants g
GROUP BY g.content_index

UNION ALL
SELECT
  'source', COALESCE(g.source, '__missing__'), COALESCE(g.source, '缺失'),
  COUNT(DISTINCT account_id), COUNT(*), NULL,
  SAFE_DIVIDE(COUNT(*), (SELECT COUNT(*) FROM successful_core_grants)) * 100
FROM successful_core_grants g
GROUP BY g.source

UNION ALL
SELECT
  'country', g.country, g.country,
  COUNT(DISTINCT account_id),
  COUNT(DISTINCT IF(content_index = 1, account_id, NULL)),
  COUNT(DISTINCT IF(content_index >= 2, account_id, NULL)),
  SAFE_DIVIDE(
    COUNT(DISTINCT IF(content_index >= 2, account_id, NULL)),
    COUNT(DISTINCT IF(content_index = 1, account_id, NULL))
  ) * 100
FROM successful_core_grants g
GROUP BY g.country

UNION ALL
SELECT
  'platform', g.platform, g.platform,
  COUNT(DISTINCT account_id),
  COUNT(DISTINCT IF(content_index = 1, account_id, NULL)),
  COUNT(*),
  SAFE_DIVIDE(COUNT(DISTINCT account_id), (SELECT COUNT(DISTINCT account_id) FROM successful_core_grants)) * 100
FROM successful_core_grants g
GROUP BY g.platform

UNION ALL
SELECT
  'daily', CAST(g.event_day AS STRING), CAST(g.event_day AS STRING),
  COUNT(DISTINCT IF(content_index = 1, account_id, NULL)),
  COUNT(DISTINCT account_id),
  COUNT(*),
  SAFE_DIVIDE(COUNT(DISTINCT IF(content_index >= 2, account_id, NULL)), COUNT(DISTINCT account_id)) * 100
FROM successful_core_grants g
GROUP BY g.event_day

UNION ALL
SELECT
  'tracking', event_key, event_key,
  event_count, account_count, NULL, coverage_rate
FROM (
  SELECT
    event_key,
    COUNTIF(r.anchor = event_key) AS event_count,
    COUNT(DISTINCT IF(r.anchor = event_key, r.account_id, NULL)) AS account_count,
    SAFE_DIVIDE(COUNTIF(r.anchor = event_key), (SELECT COUNT(*) FROM reward_events)) * 100 AS coverage_rate
  FROM UNNEST([
    'newcomer_visit_reward_unlock',
    'newcomer_visit_reward_grant',
    'newcomer_checkin_reward_grant',
    'newcomer_visit_reward_calendar',
    'newcomer_visit_reward_entry',
    'newcomer_visit_reward_claim',
    'newcomer_visit_reward_continue',
    'newcomer_visit_reward_close'
  ]) AS event_key
  LEFT JOIN reward_events r ON r.anchor = event_key
  GROUP BY event_key
)

ORDER BY row_type, row_key;
