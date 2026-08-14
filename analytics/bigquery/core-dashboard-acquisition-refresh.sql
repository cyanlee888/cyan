-- AppsFlyer attribution snapshot through the currently available install date.
-- Exclude GA4 test accounts by mapping their AppsFlyer user property to funnel_user_id.
DECLARE cutoff TIMESTAMP DEFAULT TIMESTAMP '2026-08-14 09:01:00+00';

WITH raw_ga4 AS (
  SELECT event_timestamp, user_pseudo_id, user_properties
  FROM `dino-english-497507.analytics_538991439.events_*`
  WHERE REGEXP_CONTAINS(_TABLE_SUFFIX, r'^\d{8}$')
    AND _TABLE_SUFFIX BETWEEN '20260710' AND '20260812'
  UNION ALL
  SELECT event_timestamp, user_pseudo_id, user_properties
  FROM `dino-english-497507.analytics_538991439.events_intraday_*`
  WHERE _TABLE_SUFFIX BETWEEN '20260813' AND '20260814'
),
ga4_ids AS (
  SELECT
    user_pseudo_id,
    LOWER((SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'user_type')) AS user_type,
    COALESCE(
      (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'apps_flyerId'),
      (SELECT up.value.string_value FROM UNNEST(user_properties) up WHERE up.key = 'appsflyer_id')
    ) AS appsflyer_id
  FROM raw_ga4
  WHERE event_timestamp < UNIX_MICROS(cutoff)
),
test_devices AS (
  SELECT DISTINCT user_pseudo_id FROM ga4_ids WHERE user_type = 'test'
),
test_funnel_ids AS (
  SELECT DISTINCT g.appsflyer_id
  FROM ga4_ids g
  JOIN test_devices t USING (user_pseudo_id)
  WHERE g.appsflyer_id IS NOT NULL
),
f AS (
  SELECT p.*
  FROM `dino-english-497507.de_dwd.product_conversion_funnel_user`
  p LEFT JOIN test_funnel_ids t ON t.appsflyer_id = p.funnel_user_id
  WHERE install_date BETWEEN DATE '2026-07-10' AND DATE(cutoff)
    AND t.appsflyer_id IS NULL
),
valid AS (
  SELECT * FROM f WHERE media_source != 'ecommonltbn_int'
),
metrics AS (
  SELECT 'valid_installs' metric, SUM(is_installed) value FROM valid
  UNION ALL SELECT 'valid_activated', SUM(is_activated) FROM valid
  UNION ALL SELECT 'valid_registered', SUM(is_registered) FROM valid
  UNION ALL SELECT 'fake_installs', SUM(is_installed) FROM f WHERE media_source = 'ecommonltbn_int'
  UNION ALL SELECT 'fake_activated', SUM(is_activated) FROM f WHERE media_source = 'ecommonltbn_int'
  UNION ALL SELECT 'fake_registered', SUM(is_registered) FROM f WHERE media_source = 'ecommonltbn_int'
  UNION ALL SELECT CONCAT('country_', install_country), SUM(is_installed) FROM valid WHERE install_country IN ('VN','ID','MY','SA','TH','KR') GROUP BY install_country
  UNION ALL SELECT 'country_other', SUM(is_installed) FROM valid WHERE install_country NOT IN ('VN','ID','MY','SA','TH','KR') OR install_country IS NULL
  UNION ALL SELECT 'channel_google', SUM(is_installed) FROM valid WHERE media_source = 'googleadwords_int'
  UNION ALL SELECT 'channel_facebook', SUM(is_installed) FROM valid WHERE media_source = 'Facebook Ads'
  UNION ALL SELECT 'channel_organic', SUM(is_installed) FROM valid WHERE media_source = 'organic'
  UNION ALL SELECT 'channel_other', SUM(is_installed) FROM valid WHERE media_source NOT IN ('googleadwords_int','Facebook Ads','organic')
  UNION ALL SELECT 'google_registered', SUM(is_registered) FROM valid WHERE media_source = 'googleadwords_int'
  UNION ALL SELECT 'google_installs_complete', SUM(is_installed) FROM valid WHERE media_source = 'googleadwords_int' AND install_date <= DATE '2026-08-10'
  UNION ALL SELECT 'google_registered_complete', SUM(is_registered) FROM valid WHERE media_source = 'googleadwords_int' AND install_date <= DATE '2026-08-10'
  UNION ALL SELECT 'latest_install_date', CAST(FORMAT_DATE('%Y%m%d', MAX(install_date)) AS INT64) FROM valid
)
SELECT metric, value FROM metrics ORDER BY metric;
