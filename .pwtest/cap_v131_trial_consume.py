"""V1.3.1 verify: separate 升 / 降 banners on ADJACENT level views + one-time 体验课.
 - upgrade banner on current+1 view; downgrade banner on current-1 view
 - both banner-style, not merged into one level
 - consumed up-level → upgrade banner becomes View report
 - cards never carry Try/Switch (off-plan levels → Locked / Go Premium)
"""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    pg.goto(URL); pg.wait_for_timeout(300)

    def banners(setup, levelId):
        """Render both banner fns for a given level view; return which shows what."""
        pg.evaluate(setup)
        return pg.evaluate(f"""
          (() => {{
            const lv = getLevelById('{levelId}');
            const up = renderUpgradeBanner(lv);
            const dn = renderDowngradeBanner(lv);
            const grab = (html, re) => {{ const m = html.match(re); return m ? m[1].trim() : null; }};
            return {{
              upTry:    grab(up, /data-step-up="[^"]*"[^>]*>([^<]+)</),
              upReport: grab(up, /data-step-report="[^"]*"[^>]*>([^<]+)</),
              down:     grab(dn, /data-step-down="[^"]*"[^>]*>([^<]+)</),
            }};
          }})()
        """)

    def cardcta(setup, levelId):
        pg.evaluate(setup)
        return pg.evaluate(f"""
          (() => {{
            const c = buildCourse('{levelId}','unit-1','lesson-1');
            const html = renderCourseActionButtons(c);
            const m = html.match(/data-action=\\"([^\\"]+)\\"[^>]*>([^<]+)</);
            return {{ rel: levelRel(c), action: m&&m[1], cta: m&&m[2].trim() }};
          }})()
        """)

    freshFree = """profile.premiumUnlocked=false; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.trialDoneLevels=[];"""
    print("=== FREE · current=L2, fresh ===")
    print("  view L3 (current+1):", banners(freshFree, "level-3"), "<-- expect upTry=Try Level 3")
    print("  view L1 (current-1):", banners(freshFree, "level-1"), "<-- expect down=Try Level 1")
    print("  view L2 (current)  :", banners(freshFree, "level-2"), "<-- expect all None (no banner on current)")
    print("  card L3            :", cardcta(freshFree, "level-3"), "<-- expect Go Premium")

    b1 = """profile.premiumUnlocked=false; profile.placementLevelId='level-3';
      profile.currentLevelId='level-3'; profile.trialDoneLevels=['level-2'];"""
    print("=== FREE · current=L3, trialDone=[L2] (B1) ===")
    print("  view L4 (current+1):", banners(b1, "level-4"), "<-- expect upTry=Try Level 4")
    print("  view L2 (current-1):", banners(b1, "level-2"), "<-- expect down=None (L2 consumed→suppressed)")

    freshMem = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.hasStartedClass=true; profile.trialDoneLevels=[];"""
    print("=== MEMBER · current=L2, fresh ===")
    print("  view L3 (current+1):", banners(freshMem, "level-3"), "<-- expect upTry=Try Level 3")
    print("  view L1 (current-1):", banners(freshMem, "level-1"), "<-- expect down=Switch to Level 1")
    print("  card L3            :", cardcta(freshMem, "level-3"), "<-- expect Locked")

    memUpConsumed = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.hasStartedClass=true; profile.trialDoneLevels=['level-3'];"""
    print("=== MEMBER · current=L2, trialDone=[L3] (held) ===")
    print("  view L3 (current+1):", banners(memUpConsumed, "level-3"), "<-- expect upReport=View report")
    print("  view L1 (current-1):", banners(memUpConsumed, "level-1"), "<-- expect down=Switch to Level 1")

    memProgressed = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-3'; profile.hasStartedClass=true; profile.trialDoneLevels=['level-2'];"""
    print("=== MEMBER · current=L3, placement=L2 (progressed) ===")
    print("  view L4 (current+1):", banners(memProgressed, "level-4"), "<-- expect upTry=Try Level 4")
    print("  view L2 (current-1):", banners(memProgressed, "level-2"), "<-- expect down=None (current!=placement)")
    print("  card L2            :", cardcta(memProgressed, "level-2"), "<-- expect View report (completed-lower)")
    b.close()
print("done")
