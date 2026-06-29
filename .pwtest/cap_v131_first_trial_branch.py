"""Verify V1.3.1 first (onboarding) trial report now branches by performance.

Fuzzy placement only picks WHICH level's trial runs; the report gives a real
best-fit level within trial-level ±1, driven by demoState.trialResult.
Trial taken on Level 2 → down=L1, same=L2, up=L3. After the CTA the plan
(placementLevelId) should move to the assessed level, while the Class-home
"Trial lesson" card keeps showing the level actually taken (L2).
"""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()
SHOTS = pathlib.Path(__file__).resolve().parent / "shots-v131-first-trial"
SHOTS.mkdir(exist_ok=True)

errors = []
with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1500, "height": 950})
    page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
    page.goto(URL)
    page.wait_for_timeout(400)

    EXPECT = {"down": "Level 1", "same": "Level 2", "up": "Level 3"}
    for res in ["down", "same", "up"]:
        page.evaluate(f"""
          profile.premiumUnlocked=false;
          profile.name='Mia';
          profile.placementLevelId='level-2'; profile.currentLevelId='level-2';
          profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1';
          profile.trialReportShown=false; profile.trialTakenLevelId=null;
          demoState.trialResult='{res}';
          trialReportMode='trial';
          showTrialReport();
        """)
        page.wait_for_timeout(250)
        lvl = (page.text_content('#trp-level') or '').strip()
        overall = (page.text_content('#trp-overall') or '').strip()
        ok = lvl == EXPECT[res]
        print(f"[{res}] trp-level = {lvl!r}  (expect {EXPECT[res]!r})  -> {'OK' if ok else 'FAIL'}")
        print(f"        overall: {overall}")
        page.screenshot(path=str(SHOTS / f"trial-{res}.png"), full_page=True)

    # CTA commit: free user, up-branch (L2 trial -> L3 plan), then check the plan
    # moved to L3 but the trial card still reads L2.
    page.evaluate("""
      profile.premiumUnlocked=false; profile.name='Mia';
      profile.placementLevelId='level-2'; profile.currentLevelId='level-2';
      profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1';
      profile.trialReportShown=true; profile.trialTakenLevelId=null;
      demoState.trialResult='up';
      trialReportMode='trial';
      showTrialReport();
    """)
    page.wait_for_timeout(200)
    page.evaluate("document.querySelector('#btn-trip-start').click();")
    page.wait_for_timeout(300)
    after = page.evaluate("({plan: profile.placementLevelId, cur: profile.currentLevelId, taken: profile.trialTakenLevelId})")
    print("after CTA (up, free):", after)
    card_html = page.evaluate("renderClassTrialCard()")
    import re
    m = re.search(r'course-card-title\">([^<]+)<', card_html)
    print("trial card title (L2 content kept):", m.group(1) if m else "?")

    browser.close()

print("console errors:", errors)
