"""V1.3.1 verify: for FREE, every formal lesson (incl. Lesson 1) is Go Premium;
only the 体验课 (trial card) is free. Member unaffected."""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    pg.goto(URL); pg.wait_for_timeout(300)

    def cta(setup, levelId, unitId, lessonId):
        pg.evaluate(setup)
        return pg.evaluate(f"""
          (() => {{
            const c = buildCourse('{levelId}','{unitId}','{lessonId}');
            const html = renderCourseActionButtons(c);
            const m = html.match(/data-action=\\"([^\\"]+)\\"[^>]*>([^<]+)</);
            return {{ locked: isCourseLocked(c), action: m&&m[1], cta: m&&m[2].trim() }};
          }})()
        """)

    f = """profile.premiumUnlocked=false; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1';"""
    print("=== FREE, current L2 — all formal lessons must be Go Premium ===")
    print("  L2 U1 L1:", cta(f, "level-2","unit-1","lesson-1"), "<-- expect locked / Go Premium")
    print("  L2 U1 L2:", cta(f, "level-2","unit-1","lesson-2"), "<-- expect locked / Go Premium")
    print("  L2 U1 L3:", cta(f, "level-2","unit-1","lesson-3"), "<-- expect locked / Go Premium")
    print("  L3 U1 L1 (next-up):", cta(f, "level-3","unit-1","lesson-1"), "<-- expect Try this level (free placement trial)")

    m = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1'; profile.hasStartedClass=true;"""
    print("=== MEMBER, current L2 — formal Lesson 1 still playable ===")
    print("  L2 U1 L1:", cta(m, "level-2","unit-1","lesson-1"), "<-- expect not locked / Start Class")
    b.close()
print("done")
