"""V1.3.1 verify: free user gets a placement 'Try this level' on current+1, and the
upgrade trial branches free→placement vs member→level-up gate."""
import pathlib
from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
URL = (ROOT / "V1.3.1-ui-demo.html").as_uri()

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1400, "height": 900})
    pg.goto(URL); pg.wait_for_timeout(300)

    def cta(setup, levelId, unitId="unit-1", lessonId="lesson-1"):
        pg.evaluate(setup)
        return pg.evaluate(f"""
          (() => {{
            const c = buildCourse('{levelId}','{unitId}','{lessonId}');
            const html = renderCourseActionButtons(c);
            const m = html.match(/data-action=\\"([^\\"]+)\\"[^>]*>([^<]+)</);
            return {{ rel: levelRel(c), action: m&&m[1], cta: m&&m[2].trim() }};
          }})()
        """)

    print("=== FREE, current L2 ===")
    f = """profile.premiumUnlocked=false; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1';"""
    print("  L1 (lower):    ", cta(f, "level-1"))
    print("  L2 l1 (cur):   ", cta(f, "level-2"))
    print("  L2 l2 (cur):   ", cta(f, "level-2","unit-1","lesson-2"))
    print("  L3 (next-up):  ", cta(f, "level-3"), "<-- expect try-level / Try this level")
    print("  L4 (higher):   ", cta(f, "level-4"), "<-- expect unlock / Go Premium")

    print("=== MEMBER, current L2 (next-up still level-up gate) ===")
    m = """profile.premiumUnlocked=true; profile.placementLevelId='level-2';
      profile.currentLevelId='level-2'; profile.currentUnitId='unit-1'; profile.currentLessonId='lesson-1'; profile.hasStartedClass=true;"""
    print("  L3 (next-up):  ", cta(m, "level-3"), "<-- expect try-level / Try this level")

    print("=== FREE try-higher routes to placement trial (not level-up report) ===")
    # Set free L2, run the trial on L3 via startPlacementTrial, then inspect mode/state.
    pg.evaluate(f)
    pg.evaluate("demoState.trialResult='up'; startPlacementTrial('level-3');")
    pg.wait_for_timeout(200)
    st = pg.evaluate("""(() => ({
        levelUpInProgress: levelUpInProgress,
        trialReportMode: trialReportMode,
        placement: profile.placementLevelId,
        trialTaken: profile.trialTakenLevelId,
    }))()""")
    print("  after startPlacementTrial('level-3'):", st,
          "<-- expect levelUpInProgress=false, trialReportMode='trial', placement=level-3")

    # Finish the in-class trial and confirm it lands on the PORTRAIT trial report.
    pg.evaluate("finishInclass();")
    pg.wait_for_timeout(200)
    # settle page -> continue
    cont = pg.query_selector("#lc-continue") or pg.query_selector("#btn-lc-continue")
    rep = pg.evaluate("""(() => {
        const portrait = document.querySelector('#screen-trial-report');
        const levelup = document.querySelector('#screen-levelup-report');
        return { trialReportActive: !!(portrait && portrait.classList.contains('active')),
                 levelupActive: !!(levelup && levelup.classList.contains('active')),
                 mode: trialReportMode };
    })()""")
    print("  (note: settle page may gate Continue; mode now:", rep, ")")

    b.close()
print("done")
