-- 核心模块生产库补数（MySQL，只读）。
-- Play：按 play_game_round.started_at 统计真实开局用户。
-- Explore：进度表只保留首次/最近一次完成时间，按这两个可识别时间点统计完成用户；
--          这是保守口径，不等同于完整的逐次开始流水。
-- 测试账号：user_profile.user_type = 1；本查询只纳入 user_type = 0。
-- 时间：UTC；统一截点 2026-08-24 03:01:17。

WITH periods AS (
  SELECT 'all' period_key, CAST('2026-07-10 00:00:00' AS DATETIME) start_ts,
    CAST('2026-08-24 03:01:17' AS DATETIME) end_ts
  UNION ALL SELECT 'w1', '2026-07-10 00:00:00', '2026-07-17 00:00:00'
  UNION ALL SELECT 'w2', '2026-07-17 00:00:00', '2026-07-24 00:00:00'
  UNION ALL SELECT 'w3', '2026-07-24 00:00:00', '2026-07-31 00:00:00'
  UNION ALL SELECT 'w4', '2026-07-31 00:00:00', '2026-08-07 00:00:00'
  UNION ALL SELECT 'w5', '2026-08-07 00:00:00', '2026-08-14 00:00:00'
  UNION ALL SELECT 'w6', '2026-08-14 00:00:00', '2026-08-21 00:00:00'
  UNION ALL SELECT 'w7', '2026-08-21 00:00:00', '2026-08-24 03:01:17'
),
play_users AS (
  SELECT DISTINCT p.period_key, r.user_id, r.game_type
  FROM periods p
  JOIN dino_english.play_game_round r
    ON r.started_at >= p.start_ts AND r.started_at < p.end_ts
  JOIN dino_english.user_profile u ON u.user_id = r.user_id AND u.user_type = 0
  WHERE r.game_type = 'CAPSULE' OR r.seat = 'USER'
),
explore_points AS (
  SELECT r.user_id, 'words' feature, r.created_at activity_time
  FROM dino_english.vocab_lesson_progress r
  JOIN dino_english.user_profile u ON u.user_id = r.user_id AND u.user_type = 0
  UNION
  SELECT r.user_id, 'words', r.last_complete_time
  FROM dino_english.vocab_lesson_progress r
  JOIN dino_english.user_profile u ON u.user_id = r.user_id AND u.user_type = 0
  UNION
  SELECT r.user_id, 'listening', r.created_at
  FROM dino_english.fm_listen_progress r
  JOIN dino_english.user_profile u ON u.user_id = r.user_id AND u.user_type = 0
  UNION
  SELECT r.user_id, 'listening', r.last_listen_time
  FROM dino_english.fm_listen_progress r
  JOIN dino_english.user_profile u ON u.user_id = r.user_id AND u.user_type = 0
),
explore_users AS (
  SELECT DISTINCT p.period_key, e.user_id, e.feature
  FROM periods p
  JOIN explore_points e ON e.activity_time >= p.start_ts AND e.activity_time < p.end_ts
),
module_users AS (
  SELECT
    period_key,
    user_id,
    MAX(metric = 'explore') AS explore_users,
    MAX(metric = 'explore_words') AS explore_words_users,
    MAX(metric = 'explore_listening') AS explore_listening_users,
    MAX(metric = 'play') AS play_users,
    MAX(metric = 'play_capsule') AS play_blind_box_users,
    MAX(metric = 'play_word_pk') AS play_words_pk_users,
    MAX(metric = 'play_speaking_pk') AS play_speaking_pk_users
  FROM (
    SELECT period_key, user_id, 'explore' AS metric FROM explore_users
    UNION ALL SELECT period_key, user_id, CONCAT('explore_', feature) FROM explore_users
    UNION ALL SELECT period_key, user_id, 'play' FROM play_users
    UNION ALL SELECT period_key, user_id, CONCAT('play_', LOWER(game_type)) FROM play_users
  ) activity
  GROUP BY period_key, user_id
)
SELECT
  'summary' AS row_type,
  p.period_key,
  NULL AS user_id,
  SUM(m.explore_users) AS explore_users,
  SUM(m.explore_words_users) AS explore_words_users,
  SUM(m.explore_listening_users) AS explore_listening_users,
  SUM(m.play_users) AS play_users,
  SUM(m.play_blind_box_users) AS play_blind_box_users,
  SUM(m.play_words_pk_users) AS play_words_pk_users,
  SUM(m.play_speaking_pk_users) AS play_speaking_pk_users
FROM periods p
LEFT JOIN module_users m ON m.period_key = p.period_key
GROUP BY p.period_key

UNION ALL

SELECT
  'user',
  period_key,
  user_id,
  explore_users,
  explore_words_users,
  explore_listening_users,
  play_users,
  play_blind_box_users,
  play_words_pk_users,
  play_speaking_pk_users
FROM module_users

ORDER BY FIELD(period_key, 'all', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6', 'w7'), row_type, user_id;
