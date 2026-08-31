-- 详细数据工作台 · 登录注册 · 2026-08-01 至截点的国家 × 登录方式成败汇总。
-- 方式占比读取 click；业务成功读取 login_result / signup_result；成败率读取 auth_login_result 终态诊断。
-- 国家优先锚定设备首次 first_open，历史 first_open 不可见时回退到事件发生国家；排除 user_type=test。

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
  SELECT r.*,
    LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(r.event_params) ep WHERE ep.key='event_id'),
      r.event_name
    )) AS anchor
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
window_events AS (
  SELECT b.*,
    FORMAT_DATE('%m-%d',DATE_TRUNC(DATE(TIMESTAMP_MICROS(b.event_timestamp)),WEEK(MONDAY))) AS week_key,
    CASE COALESCE(f.event_country,b.event_country)
      WHEN 'Vietnam' THEN 'VN'
      WHEN 'Indonesia' THEN 'ID'
      WHEN 'Malaysia' THEN 'MY'
      WHEN 'Saudi Arabia' THEN 'SA'
      WHEN 'Thailand' THEN 'TH'
      WHEN 'South Korea' THEN 'KR'
      ELSE 'Other'
    END AS country_code
  FROM base b
  LEFT JOIN first_open_country f USING(user_pseudo_id)
  WHERE b.event_timestamp>=UNIX_MICROS(analysis_start)
),
click_facts AS (
  SELECT week_key,country_code,user_pseudo_id,'click' AS fact_type,CAST(NULL AS STRING) AS result,
    CASE anchor
      WHEN 'login_google' THEN 'google'
      WHEN 'login_phone' THEN 'phone'
      WHEN 'login_apple' THEN 'apple'
      WHEN 'login_meta' THEN 'facebook'
      WHEN 'login_facebook' THEN 'facebook'
      WHEN 'login_kakao' THEN 'kakao'
    END AS method_key
  FROM window_events
  WHERE anchor IN ('login_google','login_phone','login_apple','login_meta','login_facebook','login_kakao')
),
business_success_facts AS (
  SELECT week_key,country_code,user_pseudo_id,
    IF(anchor='login_result','login_success','signup_success') AS fact_type,
    'success' AS result,
    CASE LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='method'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='login_method'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='signup_method')
    ))
      WHEN 'google' THEN 'google'
      WHEN 'phone' THEN 'phone'
      WHEN 'apple' THEN 'apple'
      WHEN 'facebook' THEN 'facebook'
      WHEN 'meta' THEN 'facebook'
      WHEN 'kakao' THEN 'kakao'
      ELSE 'unknown'
    END AS method_key
  FROM window_events
  WHERE anchor IN ('login_result','signup_result')
    AND LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='is_success'),
      CAST((SELECT ep.value.int_value FROM UNNEST(event_params) ep WHERE ep.key='is_success') AS STRING),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='result')
    )) IN ('true','1','success')
),
diagnostic_facts AS (
  SELECT week_key,country_code,user_pseudo_id,'diagnostic' AS fact_type,
    LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='result')) AS result,
    CASE LOWER(COALESCE(
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='auth_method'),
      (SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='target')
    ))
      WHEN 'google' THEN 'google' WHEN 'google_sdk' THEN 'google'
      WHEN 'phone' THEN 'phone' WHEN 'sms_login' THEN 'phone'
      WHEN 'apple' THEN 'apple' WHEN 'apple_sdk' THEN 'apple'
      WHEN 'facebook' THEN 'facebook' WHEN 'facebook_sdk' THEN 'facebook' WHEN 'meta' THEN 'facebook'
      WHEN 'kakao' THEN 'kakao' WHEN 'kakao_sdk' THEN 'kakao' WHEN 'kakao_bind_phone' THEN 'kakao'
      ELSE 'unknown'
    END AS method_key
  FROM window_events
  WHERE event_name='app_diagnostic'
    AND LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='diagnostic_id'))='auth_login_result'
    AND COALESCE(LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='record_type')),'outcome')='outcome'
    AND LOWER((SELECT ep.value.string_value FROM UNNEST(event_params) ep WHERE ep.key='result')) IN ('success','user_abort','tech_fail','rejected','deferred')
),
facts AS (
  SELECT * FROM click_facts
  UNION ALL SELECT * FROM business_success_facts
  UNION ALL SELECT * FROM diagnostic_facts
),
dimension_scoped AS (
  SELECT * FROM facts
  UNION ALL SELECT week_key,'All',user_pseudo_id,fact_type,result,method_key FROM facts
  UNION ALL SELECT week_key,country_code,user_pseudo_id,fact_type,result,'All' FROM facts
  UNION ALL SELECT week_key,'All',user_pseudo_id,fact_type,result,'All' FROM facts
),
scoped AS (
  SELECT * FROM dimension_scoped
  UNION ALL SELECT 'all',country_code,user_pseudo_id,fact_type,result,method_key FROM dimension_scoped
),
grouped AS (
  SELECT week_key,country_code,method_key,
    COUNTIF(fact_type='click') AS click_events,
    COUNT(DISTINCT IF(fact_type='click',user_pseudo_id,NULL)) AS click_devices,
    COUNTIF(fact_type='login_success') AS login_success_events,
    COUNTIF(fact_type='signup_success') AS signup_success_events,
    COUNTIF(fact_type='diagnostic') AS outcome_events,
    COUNT(DISTINCT IF(fact_type='diagnostic',user_pseudo_id,NULL)) AS outcome_devices,
    COUNTIF(fact_type='diagnostic' AND result='success') AS success_outcomes,
    COUNTIF(fact_type='diagnostic' AND result IN ('user_abort','tech_fail','rejected')) AS failure_outcomes,
    COUNTIF(fact_type='diagnostic' AND result='deferred') AS deferred_outcomes
  FROM scoped
  GROUP BY 1,2,3
)
SELECT week_key,country_code,method_key,click_events,click_devices,
  ROUND(100*SAFE_DIVIDE(click_events,MAX(IF(method_key='All',click_events,NULL)) OVER(PARTITION BY week_key,country_code)),2) AS click_share_pct,
  login_success_events,
  ROUND(100*SAFE_DIVIDE(login_success_events,MAX(IF(method_key='All',login_success_events,NULL)) OVER(PARTITION BY week_key,country_code)),2) AS login_success_share_pct,
  signup_success_events,outcome_events,outcome_devices,success_outcomes,failure_outcomes,deferred_outcomes,
  ROUND(100*SAFE_DIVIDE(success_outcomes,success_outcomes+failure_outcomes),2) AS success_rate_pct,
  ROUND(100*SAFE_DIVIDE(outcome_events,click_events),2) AS outcome_coverage_pct
FROM grouped
ORDER BY
  CASE week_key WHEN 'all' THEN 0 ELSE 1 END,week_key,
  CASE country_code WHEN 'All' THEN 0 WHEN 'VN' THEN 1 WHEN 'ID' THEN 2 WHEN 'MY' THEN 3 WHEN 'SA' THEN 4 WHEN 'TH' THEN 5 WHEN 'KR' THEN 6 ELSE 7 END,
  CASE method_key WHEN 'All' THEN 0 WHEN 'google' THEN 1 WHEN 'phone' THEN 2 WHEN 'apple' THEN 3 WHEN 'facebook' THEN 4 WHEN 'kakao' THEN 5 ELSE 6 END;
