/*!
 * Dino Feedback — Dino English 产品方案 demo 通用反馈组件。
 * 业务同事在 demo 页面内语音/打字写意见、传图，点提交后经 Cloudflare Worker
 * 中转写入飞书多维表格《Dino English Demo 反馈收集》（图文一体，自动附带演示位置）。
 * 面板顶部可切换界面语言（中/EN/한/ع，默认中文，选择会记住），语音识别语言随界面语言，阿拉伯语自动 RTL。
 *
 * 用法（任意 demo html 的 </body> 前）：
 *   <script src="assets/dino-feedback.js"></script>
 *   <script>
 *     DinoFeedback.init({
 *       demo: "V1.3.0",                       // 必填：版本号，落表「版本」字段
 *       getContext: () => "横屏 App · screen-x", // 选填：返回当前演示位置
 *       api: "https://...",                    // 选填：默认线上中转 Worker
 *     });
 *   </script>
 *
 * 无任何外部依赖；样式自带（dfb- 前缀），不污染宿主页面。
 * window.DINO_FB_API 可在测试时覆盖接口地址。
 */
(function () {
  "use strict";

  var DEFAULT_API = "https://dino-feedback-relay.cyanlee888.workers.dev";
  var NAME_KEY = "dinoFeedbackName";
  var LANG_KEY = "dinoFeedbackLang";

  // ---------- 多语言文案（Dino 人设） ----------
  var I18N = {
    zh: {
      label: "中",
      speech: "zh-CN",
      fab: ["我有个想法！", "吐槽通道", "说两句？", "来点灵感投喂"],
      title: "🦖 Dino 竖起耳朵听",
      subs: [
        "吐槽、夸夸、脑洞，Dino 都收",
        "看到哪里不顺眼？直说，Dino 皮厚",
        "你的一句话，可能改变下个版本",
      ],
      ctxPrefix: "会随反馈带上当前演示位置：",
      namePh: "你的称呼（选填，会记住）",
      textPhBase: "想改哪里、怎么改？直接说或直接写。",
      textPhExamples: [
        "比如：“报告页的星星太小了，建议放大并加动画”",
        "比如：“这个按钮我找了半天，建议挪到右下角”",
        "比如：“竞品 XX 的做法更顺手，截图发你们感受下”",
      ],
      voice: "🎤 懒得打字？直接说",
      voiceRec: "🔴 Dino 在听…点击停止",
      interimPrefix: "Dino 听到：",
      image: "🖼 甩张图（截图/竞品）",
      submit: "🚀 发射给产品团队",
      sending: "📡 发射中…",
      hint: "点发射即送达，图文自动归档，还会带上你正看到的页面 · 欢迎连发",
      ok: [
        "收到！Dino 把建议叼回去研究了 🦖",
        "已送达！产品同学桌面弹出了你的高见 ✨",
        "Get！这条想法已经进需求池排队了 📥",
      ],
      empty: ["Dino 竖着耳朵呢，先说点啥嘛～", "空气投喂无效，写一句或甩张图 🦖"],
      fail: "发射失败，请稍后再点一次（内容还在）",
      network: "网络异常，发射失败，请稍后再点一次（内容还在）",
      voiceUnsupported: "当前浏览器不支持语音转文字，请用 Chrome / Edge，或直接打字",
      micDenied: "麦克风权限被拒绝，请在浏览器设置里允许",
      voiceFail: "语音启动失败，请重试",
      imageFail: "有一张图片读取失败",
      close: "关闭",
    },
    en: {
      label: "EN",
      speech: "en-US",
      fab: ["Got an idea?", "Tell Dino", "Feedback?", "Feed me ideas"],
      title: "🦖 Dino is all ears",
      subs: [
        "Complaints, praise, wild ideas — Dino takes them all",
        "Something looks off? Say it straight, Dino can take it",
        "One line from you might shape the next version",
      ],
      ctxPrefix: "Your feedback will include the screen you're on: ",
      namePh: "Your name (optional, remembered)",
      textPhBase: "What should change, and how? Type it or say it.",
      textPhExamples: [
        "e.g. “The stars on the report page are too small — make them pop”",
        "e.g. “Took me ages to find this button — move it bottom right”",
        "e.g. “Competitor X handles this better — see my screenshot”",
      ],
      voice: "🎤 Too lazy to type? Just talk",
      voiceRec: "🔴 Dino is listening… tap to stop",
      interimPrefix: "Dino hears: ",
      image: "🖼 Drop a pic (screenshot)",
      submit: "🚀 Launch to the product team",
      sending: "📡 Launching…",
      hint: "One tap to deliver — text, images and your current screen are archived automatically. Fire away!",
      ok: [
        "Got it! Dino carried your idea back to the den 🦖",
        "Delivered! The product team just received your hot take ✨",
        "In! Your idea joined the backlog queue 📥",
      ],
      empty: ["Dino's ears are up — say something first 🦖", "Can't feed Dino air — write a line or drop a pic"],
      fail: "Launch failed — try again in a moment (your input is safe)",
      network: "Network hiccup — try again in a moment (your input is safe)",
      voiceUnsupported: "This browser can't do speech-to-text. Use Chrome / Edge, or just type.",
      micDenied: "Microphone blocked — please allow it in browser settings",
      voiceFail: "Couldn't start voice input — try again",
      imageFail: "One image failed to load",
      close: "Close",
    },
    ko: {
      label: "한",
      speech: "ko-KR",
      fab: ["아이디어 있어요!", "피드백 환영", "한마디 할래요?", "Dino에게 알려줘요"],
      title: "🦖 Dino가 듣고 있어요",
      subs: [
        "불만, 칭찬, 아이디어 모두 환영해요",
        "이상한 곳이 보이면 솔직하게 말해 주세요",
        "당신의 한마디가 다음 버전을 바꿀 수 있어요",
      ],
      ctxPrefix: "피드백에 현재 보고 있는 화면 정보가 함께 전송돼요: ",
      namePh: "호칭 (선택, 기억됩니다)",
      textPhBase: "어디를 어떻게 바꾸면 좋을까요? 쓰거나 말해 주세요.",
      textPhExamples: [
        "예: “리포트 화면의 별이 너무 작아요 — 더 크게, 애니메이션도 추가”",
        "예: “이 버튼 찾기가 힘들어요 — 오른쪽 아래로 옮겨 주세요”",
        "예: “경쟁사 XX 방식이 더 편해요 — 스크린샷 보낼게요”",
      ],
      voice: "🎤 타이핑 귀찮다면? 말로 해요",
      voiceRec: "🔴 Dino가 듣는 중… 누르면 정지",
      interimPrefix: "Dino가 들은 내용: ",
      image: "🖼 이미지 첨부 (스크린샷)",
      submit: "🚀 제품팀에게 발사",
      sending: "📡 발사 중…",
      hint: "한 번의 탭으로 전달 완료 — 글, 이미지, 현재 화면이 자동으로 정리돼요. 얼마든지 보내 주세요!",
      ok: [
        "접수 완료! Dino가 의견을 물고 연구하러 갔어요 🦖",
        "전달 완료! 제품팀이 방금 받았어요 ✨",
        "등록! 아이디어가 대기열에 들어갔어요 📥",
      ],
      empty: ["Dino가 귀를 쫑긋 세우고 있어요 — 먼저 한마디 해 주세요 🦖", "글 한 줄이나 이미지 한 장은 있어야 해요"],
      fail: "전송 실패 — 잠시 후 다시 눌러 주세요 (내용은 그대로예요)",
      network: "네트워크 오류 — 잠시 후 다시 눌러 주세요 (내용은 그대로예요)",
      voiceUnsupported: "이 브라우저는 음성 인식을 지원하지 않아요. Chrome / Edge를 쓰거나 직접 입력해 주세요.",
      micDenied: "마이크 권한이 차단됐어요 — 브라우저 설정에서 허용해 주세요",
      voiceFail: "음성 인식을 시작하지 못했어요 — 다시 시도해 주세요",
      imageFail: "이미지 하나를 불러오지 못했어요",
      close: "닫기",
    },
    ar: {
      label: "ع",
      speech: "ar-SA",
      rtl: true,
      fab: ["عندي فكرة!", "شاركنا رأيك", "كلمة واحدة؟", "أخبر Dino"],
      title: "🦖 Dino يصغي إليك",
      subs: [
        "شكاوى أو مديح أو أفكار — Dino يستقبلها كلها",
        "شيء غير مناسب؟ قلها بصراحة، Dino يتحمّل",
        "كلمة منك قد تغيّر الإصدار القادم",
      ],
      ctxPrefix: "سيُرفق مع ملاحظتك موضع الشاشة الحالي: ",
      namePh: "اسمك (اختياري، سيُحفظ)",
      textPhBase: "ما الذي تريد تغييره وكيف؟ اكتب أو تحدّث.",
      textPhExamples: [
        "مثال: «نجوم صفحة التقرير صغيرة جداً — كبّروها وأضيفوا حركة»",
        "مثال: «استغرقت طويلاً للعثور على هذا الزر — انقلوه إلى الأسفل»",
        "مثال: «المنافس X يفعلها بشكل أفضل — أرفقت لقطة شاشة»",
      ],
      voice: "🎤 لا تريد الكتابة؟ تحدّث",
      voiceRec: "🔴 Dino يستمع… اضغط للإيقاف",
      interimPrefix: "سمع Dino: ",
      image: "🖼 أرفق صورة (لقطة شاشة)",
      submit: "🚀 أرسل إلى فريق المنتج",
      sending: "📡 جارٍ الإرسال…",
      hint: "ضغطة واحدة وتصل — النص والصور وموضع الشاشة تُؤرشف تلقائياً. أرسل ما شئت!",
      ok: [
        "وصلت! حمل Dino فكرتك وذهب يدرسها 🦖",
        "تم التسليم! وصل رأيك إلى فريق المنتج للتو ✨",
        "تم! دخلت فكرتك قائمة الانتظار 📥",
      ],
      empty: ["Dino ينتظر بأذنين منتصبتين — قل شيئاً أولاً 🦖", "اكتب سطراً أو أرفق صورة 🦖"],
      fail: "فشل الإرسال — حاول مرة أخرى بعد قليل (محتواك محفوظ)",
      network: "خطأ في الشبكة — حاول مرة أخرى بعد قليل (محتواك محفوظ)",
      voiceUnsupported: "هذا المتصفح لا يدعم تحويل الكلام إلى نص. استخدم Chrome / Edge أو اكتب مباشرة.",
      micDenied: "تم حظر الميكروفون — اسمح به من إعدادات المتصفح",
      voiceFail: "تعذّر بدء الإدخال الصوتي — حاول مجدداً",
      imageFail: "تعذّر تحميل إحدى الصور",
      close: "إغلاق",
    },
  };
  var LANGS = ["zh", "en", "ko", "ar"];

  var CSS = [
    "#dfb-fab{position:fixed;right:18px;bottom:18px;z-index:900;border:none;cursor:pointer;",
    "font-family:'DM Sans',system-ui,sans-serif;font-size:.88rem;font-weight:700;color:#fff;",
    "background:linear-gradient(135deg,#ea6c25,#f08c3a);border-radius:9999px 9999px 4px 9999px;",
    "padding:12px 18px;display:inline-flex;align-items:center;gap:8px;",
    "box-shadow:0 10px 30px rgba(234,108,37,.45);transition:transform .18s ease,box-shadow .18s ease}",
    "#dfb-fab:hover{transform:translateY(-3px) scale(1.03);box-shadow:0 14px 36px rgba(234,108,37,.55)}",
    "#dfb-fab .dfb-dino{font-size:1.15rem;display:inline-block;transform-origin:60% 90%;animation:dfbWiggle 4.5s ease-in-out infinite}",
    "@keyframes dfbWiggle{0%,78%,100%{transform:rotate(0)}84%{transform:rotate(-14deg)}90%{transform:rotate(11deg)}96%{transform:rotate(-6deg)}}",
    "#dfb-panel{position:fixed;right:18px;bottom:76px;z-index:901;width:min(380px,calc(100vw - 24px));",
    "max-height:min(660px,calc(100dvh - 100px));display:flex;flex-direction:column;background:#fff;",
    "border:1px solid #c5ddd2;border-radius:20px;box-shadow:0 24px 70px rgba(0,0,0,.45);",
    "font-family:'DM Sans',system-ui,sans-serif;color:#1a2420;overflow:hidden;animation:dfbIn .26s cubic-bezier(.22,1,.36,1) both}",
    "#dfb-panel[hidden]{display:none}",
    "@keyframes dfbIn{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}",
    ".dfb-langbar{display:flex;align-items:center;gap:6px;padding:10px 16px 0;justify-content:flex-end}",
    ".dfb-langbar .dfb-globe{font-size:.82rem;color:#4a5f54;margin-right:auto}",
    ".dfb-lang{border:1px solid #c5ddd2;background:#fff;color:#4a5f54;font-family:inherit;font-size:.7rem;",
    "font-weight:700;border-radius:9999px;padding:4px 10px;cursor:pointer;line-height:1}",
    ".dfb-lang:hover{border-color:#2d6b45;color:#2d6b45}",
    ".dfb-lang.dfb-on{background:#143d2a;border-color:#143d2a;color:#fff}",
    ".dfb-head{padding:10px 16px 0;display:flex;align-items:flex-start;justify-content:space-between;gap:8px}",
    ".dfb-head h2{font-family:'Sora','DM Sans',system-ui,sans-serif;font-size:1rem;color:#143d2a;margin:0}",
    ".dfb-head p{margin:3px 0 0;font-size:.7rem;color:#4a5f54}",
    ".dfb-close{border:none;background:transparent;cursor:pointer;font-size:1.15rem;line-height:1;color:#4a5f54;padding:4px 6px}",
    ".dfb-body{padding:12px 16px 16px;overflow-y:auto;display:flex;flex-direction:column;gap:10px}",
    ".dfb-ctx{font-size:.68rem;color:#4a5f54;background:#d4f8ec;border-radius:10px;padding:7px 10px;line-height:1.5;margin:0}",
    ".dfb-input,.dfb-textarea{width:100%;box-sizing:border-box;border:1px solid #c5ddd2;border-radius:12px;",
    "font-family:inherit;font-size:.84rem;color:#1a2420;padding:9px 12px;background:#fff;outline:none}",
    ".dfb-input:focus,.dfb-textarea:focus{border-color:#2d6b45}",
    ".dfb-textarea{min-height:96px;resize:vertical;line-height:1.55}",
    ".dfb-row{display:flex;gap:8px}",
    ".dfb-tool{flex:1;border:1.5px dashed #c5ddd2;background:#fff;color:#2d6b45;font-family:inherit;",
    "font-size:.78rem;font-weight:700;border-radius:12px;padding:9px 6px;cursor:pointer;",
    "display:inline-flex;align-items:center;justify-content:center;gap:6px}",
    ".dfb-tool:hover{border-color:#2d6b45;background:#f3f9f5}",
    ".dfb-tool.dfb-rec{border-style:solid;border-color:#d23c2a;color:#d23c2a;background:#fdf0ee;animation:dfbPulse 1.1s ease-in-out infinite}",
    "@keyframes dfbPulse{0%,100%{box-shadow:0 0 0 0 rgba(210,60,42,.35)}50%{box-shadow:0 0 0 6px rgba(210,60,42,0)}}",
    ".dfb-interim{font-size:.72rem;color:#d23c2a;line-height:1.4;margin:0}",
    ".dfb-interim:empty{display:none}",
    ".dfb-thumbs{display:flex;flex-wrap:wrap;gap:8px}",
    ".dfb-thumbs:empty{display:none}",
    ".dfb-thumb{position:relative;width:64px;height:64px;border-radius:10px;overflow:hidden;border:1px solid #c5ddd2}",
    ".dfb-thumb img{width:100%;height:100%;object-fit:cover;display:block}",
    ".dfb-thumb button{position:absolute;top:2px;right:2px;width:18px;height:18px;border:none;border-radius:50%;",
    "background:rgba(20,30,25,.72);color:#fff;font-size:.7rem;line-height:1;cursor:pointer}",
    ".dfb-submit{border:none;cursor:pointer;font-family:inherit;font-size:.88rem;font-weight:700;color:#fff;",
    "background:#143d2a;border-radius:9999px;padding:12px;transition:transform .15s ease}",
    ".dfb-submit:hover{transform:scale(1.015)}",
    ".dfb-submit:disabled{opacity:.5;cursor:default;transform:none}",
    ".dfb-hint{font-size:.66rem;color:#4a5f54;text-align:center;line-height:1.5;margin:0}",
    "#dfb-toast{position:fixed;right:18px;bottom:76px;z-index:902;background:#143d2a;color:#fff;",
    "font-family:'DM Sans',system-ui,sans-serif;font-size:.78rem;font-weight:600;padding:10px 16px;",
    "border-radius:9999px;box-shadow:0 10px 30px rgba(0,0,0,.35);opacity:0;transform:translateY(8px);",
    "pointer-events:none;transition:opacity .22s ease,transform .22s ease}",
    "#dfb-toast.dfb-show{opacity:1;transform:translateY(0)}",
  ].join("");

  function pick(arr) { return arr[Math.floor(Math.random() * arr.length)]; }

  function init(opts) {
    opts = opts || {};
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () { build(opts); });
    } else {
      build(opts);
    }
  }

  function build(opts) {
    if (document.getElementById("dfb-fab")) return; // 防重复注入
    var api = window.DINO_FB_API || opts.api || DEFAULT_API;
    var demo = opts.demo || "";
    var getContext = typeof opts.getContext === "function"
      ? opts.getContext
      : function () {
          var active = document.querySelector(".screen.active");
          return active ? active.id : document.title;
        };

    var saved = localStorage.getItem(LANG_KEY);
    var lang = LANGS.indexOf(saved) >= 0 ? saved : "zh";
    var T = I18N[lang];

    var style = document.createElement("style");
    style.textContent = CSS;
    document.head.appendChild(style);

    var langBtnsHtml = LANGS.map(function (code) {
      return '<button type="button" class="dfb-lang" data-dfb-lang="' + code + '">' + I18N[code].label + "</button>";
    }).join("");

    var root = document.createElement("div");
    root.innerHTML =
      '<button type="button" id="dfb-fab" aria-haspopup="dialog">' +
      '<span class="dfb-dino" aria-hidden="true">🦖</span><span id="dfb-fab-label"></span></button>' +
      '<div id="dfb-panel" role="dialog" aria-label="Feedback" hidden>' +
      '<div class="dfb-langbar" id="dfb-langbar"><span class="dfb-globe" aria-hidden="true">🌐</span>' + langBtnsHtml + "</div>" +
      '<div class="dfb-head"><div><h2 id="dfb-title"></h2><p id="dfb-sub"></p></div>' +
      '<button type="button" class="dfb-close" id="dfb-close">✕</button></div>' +
      '<div class="dfb-body">' +
      '<p class="dfb-ctx" id="dfb-ctx"></p>' +
      '<input type="text" class="dfb-input" id="dfb-name" maxlength="20" />' +
      '<textarea class="dfb-textarea" id="dfb-text" maxlength="2000"></textarea>' +
      '<p class="dfb-interim" id="dfb-interim"></p>' +
      '<div class="dfb-row">' +
      '<button type="button" class="dfb-tool" id="dfb-voice"></button>' +
      '<button type="button" class="dfb-tool" id="dfb-image"></button>' +
      '<input type="file" id="dfb-file" accept="image/*" multiple hidden /></div>' +
      '<div class="dfb-thumbs" id="dfb-thumbs"></div>' +
      '<button type="button" class="dfb-submit" id="dfb-submit"></button>' +
      '<p class="dfb-hint" id="dfb-hint"></p>' +
      "</div></div>" +
      '<div id="dfb-toast" role="status"></div>';
    while (root.firstChild) document.body.appendChild(root.firstChild);

    var $ = function (id) { return document.getElementById(id); };
    var fab = $("dfb-fab");
    var panel = $("dfb-panel");
    var textEl = $("dfb-text");
    var nameEl = $("dfb-name");
    var interimEl = $("dfb-interim");
    var thumbsEl = $("dfb-thumbs");
    var voiceBtn = $("dfb-voice");
    var submitBtn = $("dfb-submit");
    var pendingImages = [];
    var sending = false;

    function toast(msg) {
      var t = $("dfb-toast");
      t.textContent = msg;
      t.classList.add("dfb-show");
      clearTimeout(toast._tm);
      toast._tm = setTimeout(function () { t.classList.remove("dfb-show"); }, 2600);
    }
    function refreshCtx() {
      $("dfb-ctx").textContent = T.ctxPrefix + getContext();
    }

    // ---------- 语言切换 ----------
    function applyLang() {
      T = I18N[lang];
      panel.setAttribute("dir", T.rtl ? "rtl" : "ltr"); // 阿拉伯语从右往左
      $("dfb-fab-label").textContent = pick(T.fab);
      $("dfb-title").textContent = T.title;
      $("dfb-sub").textContent = pick(T.subs);
      nameEl.setAttribute("placeholder", T.namePh);
      textEl.setAttribute("placeholder", T.textPhBase + "\n" + pick(T.textPhExamples));
      voiceBtn.textContent = T.voice;
      $("dfb-image").textContent = T.image;
      if (!sending) submitBtn.textContent = T.submit;
      $("dfb-hint").textContent = T.hint;
      $("dfb-close").setAttribute("aria-label", T.close);
      document.querySelectorAll(".dfb-lang").forEach(function (b) {
        b.classList.toggle("dfb-on", b.getAttribute("data-dfb-lang") === lang);
      });
      if (!panel.hidden) refreshCtx();
    }
    document.querySelectorAll(".dfb-lang").forEach(function (b) {
      b.addEventListener("click", function () {
        var next = b.getAttribute("data-dfb-lang");
        if (next === lang) return;
        stopVoice(); // 识别语言随界面语言，切换前先停
        lang = next;
        localStorage.setItem(LANG_KEY, lang);
        applyLang();
      });
    });

    // ---------- 面板开关 ----------
    function openPanel() {
      panel.hidden = false;
      fab.style.display = "none";
      nameEl.value = localStorage.getItem(NAME_KEY) || "";
      refreshCtx();
    }
    function closePanel() {
      stopVoice();
      panel.hidden = true;
      fab.style.display = "";
    }
    fab.addEventListener("click", openPanel);
    $("dfb-close").addEventListener("click", closePanel);
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !panel.hidden) closePanel();
    });

    // ---------- 语音输入（Web Speech API，语言随界面） ----------
    var SR = window.SpeechRecognition || window.webkitSpeechRecognition;
    var recog = null;
    var recActive = false;
    function stopVoice() {
      recActive = false;
      if (recog) { try { recog.stop(); } catch (e) {} }
      voiceBtn.classList.remove("dfb-rec");
      voiceBtn.textContent = T.voice;
      interimEl.textContent = "";
    }
    function startVoice() {
      if (!SR) {
        toast(T.voiceUnsupported);
        return;
      }
      recog = new SR();
      recog.lang = T.speech;
      recog.continuous = true;
      recog.interimResults = true;
      recog.onresult = function (e) {
        var interim = "";
        for (var i = e.resultIndex; i < e.results.length; i++) {
          var r = e.results[i];
          if (r.isFinal) {
            var piece = r[0].transcript.trim();
            if (piece) textEl.value = (textEl.value ? textEl.value.replace(/\s*$/, "") + "\n" : "") + piece;
          } else {
            interim += r[0].transcript;
          }
        }
        interimEl.textContent = interim ? T.interimPrefix + interim : "";
      };
      recog.onerror = function (e) {
        if (e.error === "not-allowed" || e.error === "service-not-allowed") {
          toast(T.micDenied);
          stopVoice();
        }
      };
      // Chrome 静音时会自动结束会话，未手动停止则自动续上
      recog.onend = function () { if (recActive) { try { recog.start(); } catch (e) {} } };
      try { recog.start(); } catch (e) { toast(T.voiceFail); return; }
      recActive = true;
      voiceBtn.classList.add("dfb-rec");
      voiceBtn.textContent = T.voiceRec;
    }
    voiceBtn.addEventListener("click", function () { recActive ? stopVoice() : startVoice(); });

    // ---------- 传图（前端压缩） ----------
    function compressImage(file) {
      return new Promise(function (resolve, reject) {
        var reader = new FileReader();
        reader.onload = function () {
          var img = new Image();
          img.onload = function () {
            var maxSide = 1100;
            var scale = Math.min(1, maxSide / Math.max(img.width, img.height));
            var w = Math.round(img.width * scale);
            var h = Math.round(img.height * scale);
            var canvas = document.createElement("canvas");
            canvas.width = w;
            canvas.height = h;
            canvas.getContext("2d").drawImage(img, 0, 0, w, h);
            resolve(canvas.toDataURL("image/jpeg", 0.78));
          };
          img.onerror = reject;
          img.src = reader.result;
        };
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
    }
    $("dfb-image").addEventListener("click", function () { $("dfb-file").click(); });
    $("dfb-file").addEventListener("change", async function (e) {
      var files = Array.prototype.slice.call(e.target.files || []).slice(0, 9 - pendingImages.length);
      for (var i = 0; i < files.length; i++) {
        try { pendingImages.push(await compressImage(files[i])); }
        catch (err) { toast(T.imageFail); }
      }
      e.target.value = "";
      renderThumbs();
    });
    function renderThumbs() {
      thumbsEl.innerHTML = pendingImages.map(function (src, i) {
        return '<span class="dfb-thumb"><img src="' + src + '" alt="' + (i + 1) + '" />' +
          '<button type="button" data-dfb-rm="' + i + '" aria-label="✕">✕</button></span>';
      }).join("");
      thumbsEl.querySelectorAll("[data-dfb-rm]").forEach(function (btn) {
        btn.addEventListener("click", function () {
          pendingImages.splice(Number(btn.getAttribute("data-dfb-rm")), 1);
          renderThumbs();
        });
      });
    }

    // ---------- 提交 ----------
    submitBtn.addEventListener("click", async function () {
      var text = textEl.value.trim();
      if (!text && !pendingImages.length) {
        toast(pick(T.empty));
        return;
      }
      stopVoice();
      var name = nameEl.value.trim();
      if (name) localStorage.setItem(NAME_KEY, name);
      sending = true;
      submitBtn.disabled = true;
      submitBtn.textContent = T.sending;
      try {
        var res = await fetch(api, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            name: name || "匿名",
            text: text,
            images: pendingImages,
            context: getContext(),
            page: location.href.split("?")[0],
            demo: demo,
          }),
        });
        var out = await res.json().catch(function () { return {}; });
        if (res.ok && out.ok) {
          textEl.value = "";
          pendingImages = [];
          renderThumbs();
          toast(pick(T.ok));
        } else {
          toast(T.fail);
        }
      } catch (err) {
        toast(T.network);
      } finally {
        sending = false;
        submitBtn.disabled = false;
        submitBtn.textContent = T.submit;
      }
    });

    applyLang();
  }

  window.DinoFeedback = { init: init };
})();
