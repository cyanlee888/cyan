-- Dino English 登录 / 注册：周期 × 首启国家 × 登录方式漏斗。
-- 通用时序口径：到达登录注册页 -> 点击登录方式 -> login_result / signup_result 任一成功。
-- Phone 细分口径：到达页面 -> 选择 Phone -> 点击获取验证码 -> 提交验证码 -> 任一结果成功。
-- 页面到达兼容旧 login_page_view 与新版 page_view(event_id=login)；结果节点不强制互相排序。
-- 国家锚定设备首次 first_open 的 geo.country；仅纳入当周新用户；设备级去重；排除 user_type=test。

DECLARE start_date DATE DEFAULT DATE '2026-07-10';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-27 03:02:06+00';
DECLARE daily_max_suffix STRING DEFAULT (
  SELECT MAX(REGEXP_EXTRACT(table_name, r'^events_(\d{8})$'))
  FROM `dino-english-497507.analytics_538991439.INFORMATION_SCHEMA.TABLES`
  WHERE REGEXP_CONTAINS(table_name, r'^events_\d{8}$')
);

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('w1' AS period_key, TIMESTAMP '2026-07-10 00:00:00+00' AS start_ts, TIMESTAMP '2026-07-17 00:00:00+00' AS end_ts),
    ('w2', TIMESTAMP '2026-07-17 00:00:00+00', TIMESTAMP '2026-07-24 00:00:00+00'),
    ('w3', TIMESTAMP '2026-07-24 00:00:00+00', TIMESTAMP '2026-07-31 00:00:00+00'),
    ('w4', TIMESTAMP '2026-07-31 00:00:00+00', TIMESTAMP '2026-08-07 00:00:00+00'),
    ('w5', TIMESTAMP '2026-08-07 00:00:00+00', TIMESTAMP '2026-08-14 00:00:00+00'),
    ('w6', TIMESTAMP '2026-08-14 00:00:00+00', TIMESTAMP '2026-08-21 00:00:00+00'),
    ('w7', TIMESTAMP '2026-08-21 00:00:00+00', cutoff)
  ])
),
methods AS (
  SELECT method_key
  FROM UNNEST(['All','google','phone','apple','facebook','kakao','unknown']) AS method_key
),
raw_base AS (
  SELECT
    event_name,
    event_timestamp,
    user_pseudo_id,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND daily_max_suffix
    AND event_timestamp < UNIX_MICROS(cutoff)

  UNION ALL

  SELECT
    event_name,
    event_timestamp,
    user_pseudo_id,
    geo.country AS country,
    event_params,
    user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX > daily_max_suffix
    AND _TABLE_SUFFIX <= FORMAT_DATE('%Y%m%d', DATE(cutoff))
    AND event_timestamp < UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
events AS (
  SELECT
    r.event_timestamp,
    r.event_name,
    r.user_pseudo_id,
    r.country,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'event_id'),
      r.event_name
    )) AS anchor,
    CASE LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'method'),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'signup_method'),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'login_method')
    ))
      WHEN 'google' THEN 'google'
      WHEN 'phone' THEN 'phone'
      WHEN 'apple' THEN 'apple'
      WHEN 'facebook' THEN 'facebook'
      WHEN 'meta' THEN 'facebook'
      WHEN 'kakao' THEN 'kakao'
      ELSE 'unknown'
    END AS result_method,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key = 'result')
    )) AS success_value
  FROM raw_base r
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.user_pseudo_id IS NOT NULL
),
first_open_ranked AS (
  SELECT
    user_pseudo_id,
    event_timestamp AS first_open_ts,
    CASE country
      WHEN 'Vietnam' THEN 'VN'
      WHEN 'Indonesia' THEN 'ID'
      WHEN 'Malaysia' THEN 'MY'
      WHEN 'Saudi Arabia' THEN 'SA'
      WHEN 'Thailand' THEN 'TH'
      WHEN 'South Korea' THEN 'KR'
      ELSE 'Other'
    END AS country_code,
    ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS rn
  FROM events
  WHERE event_name = 'first_open'
),
period_cohorts AS (
  SELECT p.period_key, p.end_ts, f.user_pseudo_id, f.first_open_ts, f.country_code
  FROM periods p
  JOIN first_open_ranked f
    ON f.rn = 1
   AND f.first_open_ts >= UNIX_MICROS(p.start_ts)
   AND f.first_open_ts < UNIX_MICROS(p.end_ts)
),
scoped_cohorts AS (
  SELECT * FROM period_cohorts
  UNION ALL
  SELECT period_key, end_ts, user_pseudo_id, first_open_ts, 'All' AS country_code
  FROM period_cohorts
),
method_events AS (
  SELECT
    user_pseudo_id,
    event_timestamp,
    CASE
      WHEN anchor = 'login_google' THEN 'google'
      WHEN anchor = 'login_phone' THEN 'phone'
      WHEN anchor IN ('login_phone_get_code','login_otp_submit') THEN 'phone'
      WHEN anchor = 'login_apple' THEN 'apple'
      WHEN anchor IN ('login_meta','login_facebook') THEN 'facebook'
      WHEN anchor = 'login_kakao' THEN 'kakao'
      WHEN STARTS_WITH(anchor, 'login_') AND anchor NOT IN ('login_result','login_phone_get_code','login_otp_submit','login_page_view') THEN 'unknown'
      ELSE result_method
    END AS method_key,
    CASE
      WHEN event_name = 'login_page_view' OR (event_name = 'page_view' AND anchor = 'login') THEN 'page'
      WHEN anchor IN ('login_google','login_phone','login_apple','login_meta','login_facebook','login_kakao') THEN 'click'
      WHEN anchor = 'login_phone_get_code' THEN 'code_request'
      WHEN anchor = 'login_otp_submit' THEN 'otp_submit'
      WHEN anchor = 'login_result' AND success_value IN ('true','1','success') THEN 'login'
      WHEN anchor = 'signup_result' AND success_value IN ('true','1','success') THEN 'signup'
    END AS step_key
  FROM events
  WHERE event_name = 'login_page_view'
     OR (event_name = 'page_view' AND anchor = 'login')
     OR anchor IN (
    'login_google','login_phone','login_apple','login_meta','login_facebook','login_kakao',
    'login_phone_get_code','login_otp_submit',
    'login_result','signup_result'
  )
),
expanded_method_events AS (
  SELECT * FROM method_events WHERE step_key IS NOT NULL AND step_key != 'page'
  UNION ALL
  SELECT user_pseudo_id, event_timestamp, 'All' AS method_key, step_key
  FROM method_events
  WHERE step_key IS NOT NULL AND step_key != 'page'
),
first_page AS (
  SELECT
    c.period_key,
    c.country_code,
    c.user_pseudo_id,
    c.end_ts,
    MIN(e.event_timestamp) AS page_ts
  FROM scoped_cohorts c
  JOIN method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.step_key = 'page'
   AND e.event_timestamp >= c.first_open_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY 1,2,3,4
),
first_click AS (
  SELECT
    c.period_key,
    c.country_code,
    c.user_pseudo_id,
    e.method_key,
    c.end_ts,
    MIN(e.event_timestamp) AS click_ts
  FROM first_page c
  JOIN expanded_method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.step_key = 'click'
   AND e.event_timestamp >= c.page_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY 1,2,3,4,5
),
first_phone_code_request AS (
  SELECT
    c.*,
    MIN(e.event_timestamp) AS code_request_ts
  FROM first_click c
  JOIN method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND c.method_key = 'phone'
   AND e.method_key = 'phone'
   AND e.step_key = 'code_request'
   AND e.event_timestamp >= c.click_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY c.period_key,c.country_code,c.user_pseudo_id,c.method_key,c.end_ts,c.click_ts
),
first_phone_otp_submit AS (
  SELECT
    c.*,
    MIN(e.event_timestamp) AS otp_submit_ts
  FROM first_phone_code_request c
  JOIN method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.method_key = 'phone'
   AND e.step_key = 'otp_submit'
   AND e.event_timestamp >= c.code_request_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY c.period_key,c.country_code,c.user_pseudo_id,c.method_key,c.end_ts,c.click_ts,c.code_request_ts
),
first_phone_success AS (
  SELECT
    c.*,
    MIN(e.event_timestamp) AS phone_success_ts
  FROM first_phone_otp_submit c
  JOIN method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.method_key = 'phone'
   AND e.step_key IN ('login','signup')
   AND e.event_timestamp >= c.otp_submit_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY c.period_key,c.country_code,c.user_pseudo_id,c.method_key,c.end_ts,c.click_ts,c.code_request_ts,c.otp_submit_ts
),
first_success AS (
  SELECT
    c.*,
    MIN(e.event_timestamp) AS success_ts
  FROM first_click c
  JOIN expanded_method_events e
    ON e.user_pseudo_id = c.user_pseudo_id
   AND e.method_key = c.method_key
   AND e.step_key IN ('login','signup')
   AND e.event_timestamp >= c.click_ts
   AND e.event_timestamp < UNIX_MICROS(c.end_ts)
  GROUP BY c.period_key,c.country_code,c.user_pseudo_id,c.method_key,c.end_ts,c.click_ts
),
page_base AS (
  SELECT period_key, country_code, COUNT(DISTINCT user_pseudo_id) AS page_view_devices
  FROM first_page
  GROUP BY 1,2
),
click_counts AS (
  SELECT period_key,country_code,method_key,COUNT(DISTINCT user_pseudo_id) AS method_click_devices
  FROM first_click GROUP BY 1,2,3
),
success_counts AS (
  SELECT period_key,country_code,method_key,COUNT(DISTINCT user_pseudo_id) AS auth_success_devices
  FROM first_success GROUP BY 1,2,3
),
phone_step_counts AS (
  SELECT
    c.period_key,
    c.country_code,
    COUNT(DISTINCT c.user_pseudo_id) AS phone_code_request_devices,
    COUNT(DISTINCT o.user_pseudo_id) AS phone_otp_submit_devices,
    COUNT(DISTINCT s.user_pseudo_id) AS phone_auth_success_devices
  FROM first_phone_code_request c
  LEFT JOIN first_phone_otp_submit o
    USING (period_key,country_code,user_pseudo_id,method_key,end_ts,click_ts,code_request_ts)
  LEFT JOIN first_phone_success s
    USING (period_key,country_code,user_pseudo_id,method_key,end_ts,click_ts,code_request_ts,otp_submit_ts)
  GROUP BY 1,2
)
SELECT
  p.period_key,
  c.country_code,
  m.method_key,
  c.page_view_devices,
  COALESCE(k.method_click_devices, 0) AS method_click_devices,
  COALESCE(s.auth_success_devices, 0) AS auth_success_devices,
  IF(m.method_key = 'phone', COALESCE(ph.phone_code_request_devices, 0), 0) AS phone_code_request_devices,
  IF(m.method_key = 'phone', COALESCE(ph.phone_otp_submit_devices, 0), 0) AS phone_otp_submit_devices,
  IF(m.method_key = 'phone', COALESCE(ph.phone_auth_success_devices, 0), 0) AS phone_auth_success_devices
FROM periods p
JOIN page_base c USING (period_key)
CROSS JOIN methods m
LEFT JOIN click_counts k USING (period_key,country_code,method_key)
LEFT JOIN success_counts s USING (period_key,country_code,method_key)
LEFT JOIN phone_step_counts ph USING (period_key,country_code)
ORDER BY p.period_key,
  CASE c.country_code WHEN 'All' THEN 0 WHEN 'VN' THEN 1 WHEN 'ID' THEN 2 WHEN 'MY' THEN 3 WHEN 'SA' THEN 4 WHEN 'TH' THEN 5 WHEN 'KR' THEN 6 ELSE 7 END,
  CASE m.method_key WHEN 'All' THEN 0 WHEN 'google' THEN 1 WHEN 'phone' THEN 2 WHEN 'apple' THEN 3 WHEN 'facebook' THEN 4 WHEN 'kakao' THEN 5 ELSE 6 END;
