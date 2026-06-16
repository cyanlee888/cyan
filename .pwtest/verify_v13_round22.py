"""V1.3.0 round 22 — skin pricing ladder (phase-1, 4 tiers).
Verifies the demo shop now reflects the PRD 四档 phase-1 ladder:
  基础 200 ×3 / 进阶 500 ×2 / 高级 1000 ×1 / 稀有 2000 ×1  (+1 free Classic).
Captures shop + backpack(skins) and guards against console errors."""
import pathlib, collections
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.0-ui-demo.html").as_uri()
SHOTS = pathlib.Path(__file__).resolve().parent / "shots-v13r22"
SHOTS.mkdir(exist_ok=True)

EXPECTED = sorted([0, 200, 200, 200, 500, 500, 1000, 2000])

def snap(pg, name):
    dev = pg.query_selector("#device-landscape") or pg.query_selector("#wrap-landscape")
    (dev.screenshot(path=str(SHOTS / name)) if dev else pg.screenshot(path=str(SHOTS / name)))

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 800})
    errors = []
    pg.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    pg.on("pageerror", lambda e: errors.append(str(e)))
    pg.goto(URL, wait_until="networkidle")
    pg.wait_for_timeout(400)
    out = {}

    # ---- Open shop via real nav so renderShop() runs (SHOP_ITEMS is closure-private) ----
    pg.evaluate("enterLandscape(); profile.hasStartedClass=true; profile.premiumUnlocked=true; refreshUnlockState();")
    pg.evaluate("showLandScreen('screen-class'); setHubTab('dino');")
    pg.wait_for_timeout(250)
    pg.click('#hub-panel-dino [data-go-game="screen-shop"]')
    pg.wait_for_timeout(350)
    cards = pg.eval_on_selector_all(
        "#shop-grid .shop-card",
        "els=>els.map(e=>({n:(e.querySelector('.shop-card-name')||{}).textContent,"
        "p:(e.querySelector('.shop-card-price')||{}).textContent.trim()}))",
    )
    out["shop_card_count"] = len(cards)
    out["shop_cards"] = cards
    # numeric prices shown on unowned cards ("N Coins")
    nums = sorted(int("".join(ch for ch in c["p"] if ch.isdigit()))
                  for c in cards if any(ch.isdigit() for ch in c["p"]))
    out["numeric_prices"] = nums
    out["distinct_price_points"] = sorted(set(nums))
    out["tier_breakdown"] = dict(collections.Counter(nums))
    out["has_1000_tier"] = 1000 in nums
    out["has_2000_tier"] = 2000 in nums
    out["no_legacy_800"] = 800 not in nums
    snap(pg, "01-shop-4tier-ladder.png")

    # ---- Backpack (skins) still renders owned after repricing (best-effort) ----
    try:
        pg.evaluate("showLandScreen('screen-class'); setHubTab('dino');")
        pg.wait_for_timeout(250)
        pg.click('#hub-panel-dino [data-go-game="screen-backpack"]', timeout=4000)
        pg.wait_for_timeout(300)
        out["bag_cards"] = pg.eval_on_selector_all("#bag-grid .shop-card", "els=>els.length")
        snap(pg, "02-backpack.png")
    except Exception as e:
        out["backpack_nav"] = f"skipped ({type(e).__name__})"

    out["console_errors"] = errors
    print("=== ROUND 22 RESULTS ===")
    for k, v in out.items():
        print(f"{k}: {v}")
    b.close()
