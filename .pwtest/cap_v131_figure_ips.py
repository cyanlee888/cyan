"""Verify V1.3.1 backpack figure IP tabs = Dino family (Dino/Emma/Bob/Hena/Bruce)."""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()
SHOTS = pathlib.Path(__file__).resolve().parent / "shots-v131-figure-ips"
SHOTS.mkdir(exist_ok=True)

errors = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1500, "height": 950})
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.goto(URL)
    page.wait_for_timeout(400)

    page.evaluate("""
      enterLandscape();
      if (window.GAME && window.GAME.openBackpackPets) window.GAME.openBackpackPets("dino");
    """)
    page.wait_for_timeout(500)
    tabs = page.eval_on_selector_all(".bag-ip-tab, [data-ip]", "els => els.map(e => (e.textContent||'').trim()).filter(Boolean)")
    print("IP tabs:", tabs)
    page.screenshot(path=str(SHOTS / "backpack-figure-ips.png"), full_page=True)

    browser.close()

print("console errors:", errors)
