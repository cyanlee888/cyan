"""V1.3.1 verify: unified dual-direction level stepper (↑升/↓降) + one-time 体验课.
 - stepper at current level: ↑ Try L+1 / ↓ Switch|Try L-1 (conditions & consumption)
 - consumed up-level → ↑ becomes View report
 - cards never carry Try/Switch (next-up/skipped/higher → Locked or Go Premium)
"""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    pg.goto(URL); pg.wait_for_timeout(300)

    def stepper(setup):
        pg.evaluate(setup)
        return pg.evaluate("""
          (() => {
            const html = renderLevelStepper();
            const grab = (re) => { const m = html.match(re); return m ? m[1].trim() : null; };
            return {
              up:      grab(/data-step-up="[^"]*"[^>]*>([^<]+)</),
              upReport:grab(/data-step-report="[^"]*"[^>]*>([^<]+)</),
              down:    grab(/data-step-down="[^"]*"[^>]*>([^<]+)</),
            };
          })()
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
    print("  stepper:", stepper(freshFree), "<-- expect up=Try Level 3, down=Try Level 1")
    print("  card L3:", cardcta(freshFree, "level-3"), "<-- expect Go Premium (no Try)")

    b1 = """profile.premiumUnlocked=false; profile.placementLevelId='level-3';
      profile.currentLevelId='level-3'; profile.trialDoneLevels=['level-2'];"""
    print("=== FREE · current=L3, trialDone=[L2] (B1) ===")
    print("  stepper:", stepper(b1), "<-- expect up=Try Level 4, down=None (L2 consumed→suppressed)")

    freshMem = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.hasStartedClass=true; profile.trialDoneLevels=[];"""
    print("=== MEMBER · current=L2, fresh ===")
    print("  stepper:", stepper(freshMem), "<-- expect up=Try Level 3, down=Switch to Level 1")
    print("  card L3:", cardcta(freshMem, "level-3"), "<-- expect Locked (no Try)")
    print("  card L1:", cardcta(freshMem, "level-1"), "<-- expect Locked (no Switch)")

    memUpConsumed = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.hasStartedClass=true; profile.trialDoneLevels=['level-3'];"""
    print("=== MEMBER · current=L2, trialDone=[L3] (held) ===")
    print("  stepper:", stepper(memUpConsumed), "<-- expect upReport=View report, down=Switch to Level 1")

    memProgressed = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-3'; profile.hasStartedClass=true; profile.trialDoneLevels=['level-2'];"""
    print("=== MEMBER · current=L3, placement=L2 (progressed) ===")
    print("  stepper:", stepper(memProgressed), "<-- expect up=Try Level 4, down=None (current!=placement)")
    print("  card L2:", cardcta(memProgressed, "level-2"), "<-- expect View report (completed-lower)")

    top = """profile.premiumUnlocked=true; profile.placementLevelId='level-6';
      profile.currentLevelId='level-6'; profile.hasStartedClass=true; profile.trialDoneLevels=[];"""
    print("=== MEMBER · current=L6 (top) ===")
    print("  stepper:", stepper(top), "<-- expect up=None, down=Switch to Level 5")
    b.close()
print("done")
