-- 详细数据工作台 · 激励模块 · 皮肤拥有与当前穿戴（MySQL，只读）。
-- App：Dino AI / com.prime.dino.english。
-- 测试账号：user_profile.user_type = 1；本查询只纳入 user_type = 0。
-- 时间：UTC；user_equip 是当前状态表，执行结果代表查询当下快照，不是历史换装流水。

WITH
prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
),
skin_items AS (
  SELECT id, name, price, sale_status, is_default
  FROM dino_english.item_catalog
  WHERE item_type = 'SKIN'
),
owned AS (
  SELECT DISTINCT ui.user_id, ui.item_id, ui.source
  FROM dino_english.user_item ui
  JOIN prod p ON p.user_id = ui.user_id
  JOIN skin_items i ON i.id = ui.item_id
  WHERE i.is_default = 0 AND ui.quantity > 0
),
equipped AS (
  SELECT e.user_id, e.item_id, i.is_default, e.created_at, e.updated_at
  FROM dino_english.user_equip e
  JOIN prod p ON p.user_id = e.user_id
  JOIN skin_items i ON i.id = e.item_id
  WHERE e.equip_slot = 'SKIN'
)
SELECT
  UTC_TIMESTAMP(3) AS snapshot_utc,
  (SELECT COUNT(*) FROM prod) AS production_users,
  (SELECT COUNT(DISTINCT a.user_id) FROM dino_english.dino_coin_account a JOIN prod p ON p.user_id = a.user_id) AS coin_accounts,
  (SELECT COUNT(DISTINCT user_id) FROM equipped) AS equipped_users,
  (SELECT COUNT(DISTINCT user_id) FROM equipped WHERE is_default = 1) AS default_wearers,
  (SELECT COUNT(DISTINCT user_id) FROM equipped WHERE is_default = 0) AS non_default_wearers,
  (SELECT COUNT(DISTINCT user_id) FROM owned) AS non_default_owners,
  (SELECT COUNT(DISTINCT user_id) FROM owned WHERE source = 'SHOP_PURCHASE') AS buyers,
  (SELECT COUNT(DISTINCT user_id) FROM owned WHERE source IN ('SYNC_REWARD', 'WELCOME_GIFT')) AS reward_owners,
  (
    SELECT COUNT(DISTINCT e.user_id)
    FROM equipped e
    JOIN owned o ON o.user_id = e.user_id AND o.item_id = e.item_id
    WHERE e.is_default = 0 AND o.source = 'SHOP_PURCHASE'
  ) AS buyers_wearing_purchased,
  (
    SELECT COUNT(DISTINCT e.user_id)
    FROM equipped e
    JOIN owned o ON o.user_id = e.user_id AND o.item_id = e.item_id
    WHERE e.is_default = 0 AND o.source IN ('SYNC_REWARD', 'WELCOME_GIFT')
  ) AS reward_owners_wearing_reward,
  (
    SELECT COUNT(DISTINCT user_id)
    FROM equipped
    WHERE updated_at > created_at + INTERVAL 1 SECOND
  ) AS equip_record_updated;

-- 来源拥有量与“当前穿着同来源皮肤”的用户数。
WITH prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
),
owned AS (
  SELECT ui.user_id, ui.item_id, ui.source, ui.quantity
  FROM dino_english.user_item ui
  JOIN prod p ON p.user_id = ui.user_id
  JOIN dino_english.item_catalog i ON i.id = ui.item_id
  WHERE i.item_type = 'SKIN' AND i.is_default = 0 AND ui.quantity > 0
)
SELECT
  o.source,
  COUNT(*) AS inventory_rows,
  COUNT(DISTINCT o.user_id) AS owners,
  SUM(o.quantity) AS units,
  COUNT(DISTINCT CASE WHEN e.item_id IS NOT NULL THEN o.user_id END) AS wearing_same_source_skin
FROM owned o
LEFT JOIN dino_english.user_equip e
  ON e.user_id = o.user_id AND e.item_id = o.item_id AND e.equip_slot = 'SKIN'
GROUP BY o.source
ORDER BY units DESC;

-- 购买价格档表现。
WITH prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
)
SELECT
  i.price,
  COUNT(DISTINCT i.id) AS sku,
  COUNT(DISTINCT ui.user_id) AS buyers,
  SUM(ui.quantity) AS units,
  COUNT(DISTINCT CASE WHEN e.item_id IS NOT NULL THEN ui.user_id END) AS current_wearers
FROM dino_english.user_item ui
JOIN prod p ON p.user_id = ui.user_id
JOIN dino_english.item_catalog i
  ON i.id = ui.item_id AND i.item_type = 'SKIN' AND i.is_default = 0
LEFT JOIN dino_english.user_equip e
  ON e.user_id = ui.user_id AND e.item_id = ui.item_id AND e.equip_slot = 'SKIN'
WHERE ui.source = 'SHOP_PURCHASE' AND ui.quantity > 0
GROUP BY i.price
ORDER BY i.price;

-- 每位买家累计购买件数。
WITH prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
),
buyer_units AS (
  SELECT ui.user_id, SUM(ui.quantity) AS units
  FROM dino_english.user_item ui
  JOIN prod p ON p.user_id = ui.user_id
  JOIN dino_english.item_catalog i
    ON i.id = ui.item_id AND i.item_type = 'SKIN' AND i.is_default = 0
  WHERE ui.source = 'SHOP_PURCHASE' AND ui.quantity > 0
  GROUP BY ui.user_id
)
SELECT
  CASE
    WHEN units = 1 THEN '1'
    WHEN units = 2 THEN '2'
    WHEN units BETWEEN 3 AND 4 THEN '3-4'
    ELSE '5+'
  END AS purchase_units,
  COUNT(*) AS buyers
FROM buyer_units
GROUP BY purchase_units
ORDER BY MIN(units);

-- 购买 Top 10 与当前穿戴。
WITH prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
)
SELECT
  i.id AS item_id,
  i.name,
  i.price,
  SUM(ui.quantity) AS units,
  COUNT(DISTINCT ui.user_id) AS buyers,
  COUNT(DISTINCT CASE WHEN e.item_id IS NOT NULL THEN ui.user_id END) AS current_wearers
FROM dino_english.user_item ui
JOIN prod p ON p.user_id = ui.user_id
JOIN dino_english.item_catalog i
  ON i.id = ui.item_id AND i.item_type = 'SKIN' AND i.is_default = 0
LEFT JOIN dino_english.user_equip e
  ON e.user_id = ui.user_id AND e.item_id = ui.item_id AND e.equip_slot = 'SKIN'
WHERE ui.source = 'SHOP_PURCHASE' AND ui.quantity > 0
GROUP BY i.id, i.name, i.price
ORDER BY units DESC, buyers DESC, i.id
LIMIT 10;

-- 当前穿戴非默认皮肤 Top 12，并拆购买 / 奖励来源。
WITH prod AS (
  SELECT user_id FROM dino_english.user_profile WHERE user_type = 0
),
owned_flags AS (
  SELECT
    ui.user_id,
    ui.item_id,
    MAX(ui.source = 'SHOP_PURCHASE') AS has_purchase,
    MAX(ui.source IN ('SYNC_REWARD', 'WELCOME_GIFT')) AS has_reward
  FROM dino_english.user_item ui
  JOIN prod p ON p.user_id = ui.user_id
  GROUP BY ui.user_id, ui.item_id
)
SELECT
  i.id AS item_id,
  i.name,
  i.price,
  COUNT(DISTINCT e.user_id) AS current_wearers,
  COUNT(DISTINCT CASE WHEN o.has_purchase = 1 THEN e.user_id END) AS purchase_owned_wearers,
  COUNT(DISTINCT CASE WHEN o.has_reward = 1 THEN e.user_id END) AS reward_owned_wearers
FROM dino_english.user_equip e
JOIN prod p ON p.user_id = e.user_id
JOIN dino_english.item_catalog i
  ON i.id = e.item_id AND i.item_type = 'SKIN' AND i.is_default = 0
LEFT JOIN owned_flags o ON o.user_id = e.user_id AND o.item_id = e.item_id
WHERE e.equip_slot = 'SKIN'
GROUP BY i.id, i.name, i.price
ORDER BY current_wearers DESC, i.id
LIMIT 12;
