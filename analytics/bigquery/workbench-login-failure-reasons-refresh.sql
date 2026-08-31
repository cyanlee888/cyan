-- 详细数据工作台 · 登录注册 · 2026-08-01 至截点的国家 × 登录方式失败原因。
-- 仅统计 auth_login_result 终态诊断中的 user_abort / rejected / tech_fail；不把“未见成功”推断为失败。

DECLARE analysis_start TIMESTAMP DEFAULT TIMESTAMP '2026-08-01 00:00:00+00';
DECLARE history_start DATE DEFAULT DATE '2026-07-01';
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-31 03:01:24+00';
DECLARE daily_max_suffix STRING DEFAULT (
  SELECT MAX(REGEXP_EXTRACT(table_name, r'^events_(\d{8})$'))
  FROM `dino-english-497507.analytics_538991439.INFORMATION_SCHEMA.TABLES`
  WHERE REGEXP_CONTAINS(table_name, r'^events_\d{8}$')
);

WITH raw_history AS (
  SELECT event_name,event_timestamp,user_pseudo_id,platform,geo.country AS event_country,
         app_info.id AS app_id,event_params,user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX,r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d',history_start) AND daily_max_suffix
    AND event_timestamp<UNIX_MICROS(cutoff)

  UNION ALL

  SELECT event_name,event_timestamp,user_pseudo_id,platform,geo.country AS event_country,
         app_info.id AS app_id,event_params,user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX>daily_max_suffix
    AND _TABLE_SUFFIX<=FORMAT_DATE('%Y%m%d',DATE(cutoff))
    AND event_timestamp<UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id
  FROM raw_history
  WHERE LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key='user_type'))='test'
),
base AS (
  SELECT r.*
  FROM raw_history r
  LEFT JOIN test_devices t USING(user_pseudo_id)
  WHERE t.user_pseudo_id IS NULL
    AND r.user_pseudo_id IS NOT NULL
    AND r.app_id='com.prime.dino.english'
    AND r.platform IN ('ANDROID','IOS')
),
first_open_country AS (
  SELECT user_pseudo_id,event_country
  FROM base
  WHERE event_name='first_open' AND event_country IS NOT NULL
  QUALIFY ROW_NUMBER() OVER(PARTITION BY user_pseudo_id ORDER BY event_timestamp)=1
),
failures AS (
  SELECT
    FORMAT_DATE('%m-%d',DATE_TRUNC(DATE(TIMESTAMP_MICROS(b.event_timestamp)),WEEK(MONDAY))) AS week_key,
    CASE COALESCE(f.event_country,b.event_country)
      WHEN 'Vietnam' THEN 'VN'
      WHEN 'Indonesia' THEN 'ID'
      WHEN 'Malaysia' THEN 'MY'
      WHEN 'Saudi Arabia' THEN 'SA'
      WHEN 'Thailand' THEN 'TH'
      WHEN 'South Korea' THEN 'KR'
      ELSE 'Other'
    END AS country_code,
    CASE LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='auth_method'),
      (SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='target')
    ))
      WHEN 'google' THEN 'google' WHEN 'google_sdk' THEN 'google'
      WHEN 'phone' THEN 'phone' WHEN 'sms_login' THEN 'phone'
      WHEN 'apple' THEN 'apple' WHEN 'apple_sdk' THEN 'apple'
      WHEN 'facebook' THEN 'facebook' WHEN 'facebook_sdk' THEN 'facebook' WHEN 'meta' THEN 'facebook'
      WHEN 'kakao' THEN 'kakao' WHEN 'kakao_sdk' THEN 'kakao' WHEN 'kakao_bind_phone' THEN 'kakao'
      ELSE 'unknown'
    END AS method_key,
    b.user_pseudo_id,
    LOWER((SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='result')) AS result_type,
    LOWER(COALESCE((SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='reason'),'unspecified')) AS raw_reason,
    COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='code'),
      CAST((SELECT ep.value.int_value FROM UNNEST(b.event_params) ep WHERE ep.key='status_code') AS STRING),
      'none'
    ) AS error_code
  FROM base b
  LEFT JOIN first_open_country f USING(user_pseudo_id)
  WHERE b.event_timestamp>=UNIX_MICROS(analysis_start)
    AND b.event_name='app_diagnostic'
    AND LOWER((SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='diagnostic_id'))='auth_login_result'
    AND COALESCE(LOWER((SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='record_type')),'outcome')='outcome'
    AND LOWER((SELECT ep.value.string_value FROM UNNEST(b.event_params) ep WHERE ep.key='result')) IN ('user_abort','tech_fail','rejected')
),
classified AS (
  SELECT *,
    CASE
      WHEN error_code='40002' THEN '验证码错误'
      WHEN error_code='40001' THEN '验证码过期'
      WHEN error_code='40003' THEN '短信请求过于频繁'
      WHEN raw_reason='cancelled' THEN '用户取消'
      WHEN raw_reason='denied' THEN '用户拒绝授权'
      WHEN raw_reason='interrupted' THEN '流程被中断'
      WHEN raw_reason='duplicate_request' THEN '重复请求'
      WHEN raw_reason='unavailable' THEN '登录 SDK 不可用'
      WHEN raw_reason='sdk_timeout' THEN '登录 SDK 超时'
      WHEN raw_reason='network_error' THEN '网络错误'
      WHEN raw_reason='signature_failed' THEN '签名校验失败'
      WHEN raw_reason='provider_not_registered' THEN 'Provider 未注册'
      WHEN error_code='400' THEN '请求参数或方式不合法'
      WHEN error_code='401' THEN '三方登录凭证无效'
      WHEN error_code='403' THEN '账号不可用或服务端拒绝'
      WHEN raw_reason='server_error' THEN '服务端异常'
      WHEN raw_reason='server_rejected' THEN '服务端拒绝'
      WHEN raw_reason='unknown' OR raw_reason='unspecified' THEN '未知技术异常'
      ELSE raw_reason
    END AS reason_label,
    CASE
      WHEN error_code IN ('400','40001','40002','40003','401','403') OR result_type='rejected' THEN '业务拒绝'
      WHEN result_type='user_abort' THEN '用户中止'
      ELSE '技术失败'
    END AS failure_type
  FROM failures
),
dimension_scoped AS (
  SELECT * FROM classified
  UNION ALL SELECT week_key,'All',method_key,user_pseudo_id,result_type,raw_reason,error_code,reason_label,failure_type FROM classified
  UNION ALL SELECT week_key,country_code,'All',user_pseudo_id,result_type,raw_reason,error_code,reason_label,failure_type FROM classified
  UNION ALL SELECT week_key,'All','All',user_pseudo_id,result_type,raw_reason,error_code,reason_label,failure_type FROM classified
),
scoped AS (
  SELECT * FROM dimension_scoped
  UNION ALL SELECT 'all',country_code,method_key,user_pseudo_id,result_type,raw_reason,error_code,reason_label,failure_type FROM dimension_scoped
),
grouped AS (
  SELECT week_key,country_code,method_key,failure_type,reason_label,
    COUNT(*) AS failure_events,
    COUNT(DISTINCT user_pseudo_id) AS failure_devices
  FROM scoped
  GROUP BY 1,2,3,4,5
)
SELECT week_key,country_code,method_key,failure_type,reason_label,failure_events,failure_devices,
  ROUND(100*SAFE_DIVIDE(failure_events,SUM(failure_events) OVER(PARTITION BY week_key,country_code,method_key)),2) AS share_within_selection_pct
FROM grouped
ORDER BY
  CASE week_key WHEN 'all' THEN 0 ELSE 1 END,week_key,
  CASE country_code WHEN 'All' THEN 0 WHEN 'VN' THEN 1 WHEN 'ID' THEN 2 WHEN 'MY' THEN 3 WHEN 'SA' THEN 4 WHEN 'TH' THEN 5 WHEN 'KR' THEN 6 ELSE 7 END,
  CASE method_key WHEN 'All' THEN 0 WHEN 'google' THEN 1 WHEN 'phone' THEN 2 WHEN 'apple' THEN 3 WHEN 'facebook' THEN 4 WHEN 'kakao' THEN 5 ELSE 6 END,
  failure_events DESC;
