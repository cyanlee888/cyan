-- Google Ads spend from the two linked accounts; use the latest transfer snapshot.
WITH spend AS (
  SELECT segments_date, metrics_cost_micros
  FROM `dino-english-497507.google_ads_656_577_9709.ads_AccountBasicStats_5974000948`
  WHERE _DATA_DATE = segments_date
    AND segments_date BETWEEN DATE '2026-07-10' AND DATE '2026-08-11'
  UNION ALL
  SELECT segments_date, metrics_cost_micros
  FROM `dino-english-497507.google_ads_656_577_9709.ads_AccountBasicStats_6565779709`
  WHERE _DATA_DATE = segments_date
    AND segments_date BETWEEN DATE '2026-07-10' AND DATE '2026-08-11'
)
SELECT
  MIN(segments_date) AS start_date,
  MAX(segments_date) AS end_date,
  ROUND(SUM(metrics_cost_micros) / 1000000, 2) AS spend_usd
FROM spend;
