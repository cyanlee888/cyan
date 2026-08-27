-- Dino English 登录注册：日期 × 首启国家 × 注册方式
-- 口径：首启当日成功注册设备 ÷ 当日首启设备；设备与日期均按 UTC。
-- 成功兼容历史值 true / 1 / success；每台设备只取首个带有效方式的成功事件。
-- 日表优先，intraday 仅补日表尚未落地的日期，避免重复扫描同一天。
-- 任一事件出现 user_properties.user_type=test 的设备从首启分母与注册分子统一排除。

DECLARE start_date DATE DEFAULT DATE '2026-07-10';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-27 03:02:06+00';
DECLARE daily_max_suffix STRING DEFAULT (
  SELECT MAX(REGEXP_EXTRACT(table_name, r'^events_(\d{8})$'))
  FROM `dino-english-497507.analytics_538991439.INFORMATION_SCHEMA.TABLES`
  WHERE REGEXP_CONTAINS(table_name, r'^events_\d{8}$')
);

WITH raw_union AS (
  SELECT
    event_name, event_date, event_timestamp, user_pseudo_id,
    event_params, user_properties, geo, platform
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND daily_max_suffix
    AND event_timestamp < UNIX_MICROS(cutoff)

  UNION ALL

  SELECT
    event_name, event_date, event_timestamp, user_pseudo_id,
    event_params, user_properties, geo, platform
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX > daily_max_suffix
    AND _TABLE_SUFFIX <= FORMAT_DATE('%Y%m%d', DATE(cutoff))
    AND event_timestamp < UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_union
  WHERE LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) = 'test'
),
events_union AS (
  SELECT r.* EXCEPT(user_properties)
  FROM raw_union r
  LEFT JOIN test_devices t USING (user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND event_name IN ('first_open', 'signup_result')
),
first_open_ranked AS (
  SELECT
    user_pseudo_id,
    PARSE_DATE('%Y%m%d', event_date) AS cohort_date,
    platform,
    geo.country AS country,
    ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS rn
  FROM events_union
  WHERE event_name = 'first_open'
),
cohorts AS (
  SELECT
    user_pseudo_id,
    cohort_date,
    platform,
    CASE country
      WHEN 'Vietnam' THEN 'VN'
      WHEN 'Indonesia' THEN 'ID'
      WHEN 'Malaysia' THEN 'MY'
      WHEN 'Saudi Arabia' THEN 'SA'
      WHEN 'Thailand' THEN 'TH'
      WHEN 'South Korea' THEN 'KR'
      ELSE 'Other'
    END AS country_code
  FROM first_open_ranked
  WHERE rn = 1
),
signup_shaped AS (
  SELECT
    user_pseudo_id,
    PARSE_DATE('%Y%m%d', event_date) AS signup_date,
    event_timestamp,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'signup_method'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'method')
    )) AS signup_method,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key = 'is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key = 'result')
    )) AS success_value
  FROM events_union
  WHERE event_name = 'signup_result'
),
signup_ranked AS (
  SELECT
    user_pseudo_id,
    signup_date,
    CASE
      WHEN signup_method IN ('google', 'phone', 'apple', 'facebook', 'kakao') THEN signup_method
      ELSE 'unknown'
    END AS signup_method,
    ROW_NUMBER() OVER (
      PARTITION BY user_pseudo_id, signup_date
      ORDER BY IF(signup_method IS NULL, 1, 0), event_timestamp
    ) AS rn
  FROM signup_shaped
  WHERE success_value IN ('true', '1', 'success')
),
signup_success AS (
  SELECT user_pseudo_id, signup_date, signup_method
  FROM signup_ranked
  WHERE rn = 1
),
country_daily AS (
  SELECT
    c.cohort_date,
    c.country_code,
    COUNT(*) AS first_opens,
    COUNTIF(s.user_pseudo_id IS NOT NULL) AS registered,
    COUNTIF(s.signup_method = 'google') AS google,
    COUNTIF(s.signup_method = 'phone') AS phone,
    COUNTIF(s.signup_method = 'apple') AS apple,
    COUNTIF(s.signup_method = 'facebook') AS facebook,
    COUNTIF(s.signup_method = 'kakao') AS kakao,
    COUNTIF(s.signup_method = 'unknown') AS unknown,
    COUNTIF(c.platform = 'ANDROID') AS android_first_opens,
    COUNTIF(c.platform = 'ANDROID' AND s.user_pseudo_id IS NOT NULL) AS android_registered,
    COUNTIF(c.platform = 'IOS') AS ios_first_opens,
    COUNTIF(c.platform = 'IOS' AND s.user_pseudo_id IS NOT NULL) AS ios_registered
  FROM cohorts c
  LEFT JOIN signup_success s
    ON s.user_pseudo_id = c.user_pseudo_id
   AND s.signup_date = c.cohort_date
  GROUP BY 1, 2
)
SELECT
  cohort_date,
  country_code,
  first_opens,
  registered,
  ROUND(SAFE_DIVIDE(registered, first_opens) * 100, 1) AS registered_rate,
  google,
  phone,
  apple,
  facebook,
  kakao,
  unknown,
  android_first_opens,
  android_registered,
  ios_first_opens,
  ios_registered
FROM country_daily
ORDER BY cohort_date, country_code;
