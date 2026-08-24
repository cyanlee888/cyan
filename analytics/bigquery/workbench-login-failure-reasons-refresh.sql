-- Dino English 登录失败原因：周期 × 首启国家 × 登录方式 × 原因。
-- 仅统计 login_result 明确上报失败（false / 0 / fail / failure）的事件。
-- 不把“点击后未见成功”推断为失败；原因只输出脱敏后的可行动分类。

DECLARE start_date DATE DEFAULT DATE '2026-07-10';
DECLARE end_date DATE DEFAULT DATE '2026-08-21';

WITH periods AS (
  SELECT * FROM UNNEST([
    STRUCT('w1' AS period_key, DATE '2026-07-10' AS start_day, DATE '2026-07-17' AS end_day),
    ('w2', DATE '2026-07-17', DATE '2026-07-24'),
    ('w3', DATE '2026-07-24', DATE '2026-07-31'),
    ('w4', DATE '2026-07-31', DATE '2026-08-07'),
    ('w5', DATE '2026-08-07', DATE '2026-08-14'),
    ('w6', DATE '2026-08-14', DATE '2026-08-21')
  ])
),
raw_base AS (
  SELECT event_date,event_name,event_timestamp,user_pseudo_id,geo.country AS country,event_params,user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', start_date) AND FORMAT_DATE('%Y%m%d', DATE_SUB(end_date, INTERVAL 1 DAY))
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_base
  WHERE LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key='user_type'))='test'
),
events AS (
  SELECT r.*,
    LOWER(COALESCE((SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='event_id'),r.event_name)) AS anchor,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(r.event_params) ep WHERE ep.key='is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='result')
    )) AS success_value
  FROM raw_base r LEFT JOIN test_devices t USING(user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL AND r.user_pseudo_id IS NOT NULL
),
first_country AS (
  SELECT user_pseudo_id,
    CASE country WHEN 'Vietnam' THEN 'VN' WHEN 'Indonesia' THEN 'ID' WHEN 'Malaysia' THEN 'MY'
      WHEN 'Saudi Arabia' THEN 'SA' WHEN 'Thailand' THEN 'TH' WHEN 'South Korea' THEN 'KR' ELSE 'Other' END AS country_code,
    ROW_NUMBER() OVER(PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS rn
  FROM events WHERE event_name='first_open'
),
failures AS (
  SELECT p.period_key,e.event_date,e.user_pseudo_id,COALESCE(c.country_code,'Other') AS country_code,
    CASE LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='method'),
      (SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='login_method')
    ))
      WHEN 'google' THEN 'google' WHEN 'phone' THEN 'phone' WHEN 'apple' THEN 'apple'
      WHEN 'facebook' THEN 'facebook' WHEN 'meta' THEN 'facebook' WHEN 'kakao' THEN 'kakao' ELSE 'unknown' END AS method_key,
    CASE
      WHEN STARTS_WITH((SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='failed_reason'),'400:Facebook') THEN 'Facebook 登录未启用'
      WHEN STARTS_WITH((SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='failed_reason'),'401:id token expired') THEN '身份令牌已过期'
      WHEN REGEXP_CONTAINS(LOWER(COALESCE((SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='failed_reason'),'')),r'database|sql') THEN '服务端数据库异常'
      WHEN (SELECT ep.value.string_value FROM UNNEST(e.event_params) ep WHERE ep.key='failed_reason') IS NULL THEN '未上报原因'
      ELSE '其他失败'
    END AS reason
  FROM events e
  JOIN periods p ON PARSE_DATE('%Y%m%d',e.event_date)>=p.start_day AND PARSE_DATE('%Y%m%d',e.event_date)<p.end_day
  LEFT JOIN first_country c ON c.user_pseudo_id=e.user_pseudo_id AND c.rn=1
  WHERE e.anchor='login_result' AND e.success_value IN ('false','0','fail','failure')
),
period_scopes AS (
  SELECT * FROM failures
  UNION ALL SELECT 'all',event_date,user_pseudo_id,country_code,method_key,reason FROM failures
),
country_scopes AS (
  SELECT * FROM period_scopes
  UNION ALL SELECT period_key,event_date,user_pseudo_id,'All',method_key,reason FROM period_scopes
),
method_scopes AS (
  SELECT * FROM country_scopes
  UNION ALL SELECT period_key,event_date,user_pseudo_id,country_code,'All',reason FROM country_scopes
),
reason_scopes AS (
  SELECT * FROM method_scopes
  UNION ALL SELECT period_key,event_date,user_pseudo_id,country_code,method_key,'All' FROM method_scopes
)
SELECT period_key,country_code,method_key,reason,
  COUNT(*) AS failure_events,COUNT(DISTINCT user_pseudo_id) AS failure_devices,
  MIN(event_date) AS first_event_date,MAX(event_date) AS last_event_date
FROM reason_scopes
GROUP BY 1,2,3,4
ORDER BY period_key,country_code,method_key,reason;
