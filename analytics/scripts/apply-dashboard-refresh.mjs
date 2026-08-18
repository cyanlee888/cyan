import fs from 'node:fs';
import path from 'node:path';

const resultDir = process.argv[2];
if (!resultDir) throw new Error('Usage: node analytics/scripts/apply-dashboard-refresh.mjs <query-result-dir>');

const root = process.cwd();
const readRows = name => {
  const parsed = JSON.parse(fs.readFileSync(path.join(resultDir, `${name}.json`), 'utf8'));
  if (!Array.isArray(parsed)) throw new Error(`${name}.json is not an array`);
  const rows = Array.isArray(parsed.at(-1)) ? parsed.at(-1) : parsed;
  if (!Array.isArray(rows)) throw new Error(`${name}.json has no result array`);
  return rows;
};
const num = value => value == null || value === '' ? null : Number(value);
const compact = value => JSON.stringify(value);
const replaceFrom = (text, start, end, replacement) => {
  const from = text.indexOf(start);
  const to = text.indexOf(end, from + start.length);
  if (from < 0 || to < 0) throw new Error(`Could not replace block: ${start} … ${end}`);
  return `${text.slice(0, from)}${replacement}\n${text.slice(to)}`;
};
const replaceLine = (text, prefix, replacement) => {
  const pattern = new RegExp(`^${prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}.*$`, 'm');
  if (!pattern.test(text)) throw new Error(`Could not replace line: ${prefix}`);
  return text.replace(pattern, replacement);
};
const mapBy = (rows, keyFn) => new Map(rows.map(row => [keyFn(row), row]));
const metricValue = (metrics, key) => Number(metrics.get(key) || 0);
const pct = (value, total, digits = 1) => total ? (value / total * 100).toFixed(digits) : '0.0';

const cutoff = '2026-08-17 02:15 UTC';
const cutoffShort = '08-17 02:15';
const periods = ['all', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6'];
const countries = ['vn', 'kr', 'sa', 'my', 'id', 'th'];
const countryMeta = {
  all:{tab:'全部',label:'全部国家'},
  vn:{tab:'越南',label:'越南',code:'VN'},
  kr:{tab:'韩国',label:'韩国',code:'KR'},
  sa:{tab:'沙特',label:'沙特阿拉伯',code:'SA'},
  my:{tab:'马来',label:'马来西亚',code:'MY'},
  id:{tab:'印尼',label:'印度尼西亚',code:'ID'},
  th:{tab:'泰国',label:'泰国',code:'TH'}
};

const diagnosticRows = readRows('diagnostic');
const diagnosticMap = mapBy(diagnosticRows, row => `${row.period_key}:${row.country_key}`);
const diagnosticData = Object.fromEntries(periods.map(period => [period,
  Object.fromEntries(['all', ...countries].map(country => {
    const row = diagnosticMap.get(`${period}:${country}`);
    if (!row) throw new Error(`Missing diagnostic ${period}:${country}`);
    return [country, {
      journey:{
        first_open:num(row.first_open), signup_success:num(row.registered),
        lesson_start:num(row.lesson_started), lesson_complete:num(row.lesson_completed)
      },
      retention:{devices:num(row.d1_devices), d1:num(row.d1_retained)}
    }];
  }))
]));

const weeklyRows = readRows('weekly');
const weeklyPayload = new Map(weeklyRows.map(row => [row.week_key, JSON.parse(row.payload)]));
const globalModules = {
  all:{explore_users:1860,explore_words_users:1809,explore_listening_users:354,play_users:3458,play_blind_box_users:2515,play_words_pk_users:2418,play_speaking_pk_users:2103},
  w1:{explore_users:517,explore_words_users:502,explore_listening_users:86,play_users:1157,play_blind_box_users:800,play_words_pk_users:769,play_speaking_pk_users:657},
  w2:{explore_users:459,explore_words_users:449,explore_listening_users:68,play_users:751,play_blind_box_users:557,play_words_pk_users:518,play_speaking_pk_users:451},
  w3:{explore_users:372,explore_words_users:366,explore_listening_users:66,play_users:598,play_blind_box_users:455,play_words_pk_users:428,play_speaking_pk_users:370},
  w4:{explore_users:208,explore_words_users:196,explore_listening_users:55,play_users:418,play_blind_box_users:311,play_words_pk_users:292,play_speaking_pk_users:250},
  w5:{explore_users:333,explore_words_users:312,explore_listening_users:74,play_users:610,play_blind_box_users:423,play_words_pk_users:441,play_speaking_pk_users:393},
  w6:{explore_users:186,explore_words_users:171,explore_listening_users:45,play_users:348,play_blind_box_users:254,play_words_pk_users:248,play_speaking_pk_users:235}
};
const stageOrder = ['warmup','lead_in','video','word_teach','word_practice','sentence_teach','sentence_practice','wrapup'];
const groupOrder = ['l1l2','l3l4','l5l6'];
const weeklyData = {};
for (const period of periods.slice(1)) {
  const payload = weeklyPayload.get(period);
  const diag = diagnosticData[period].all;
  const segments = new Map(payload.retention_segments.map(row => [row.segment, [row.devices, row.d1]]));
  const stageMap = new Map(payload.lesson_stages.map(row => [`${row.level_group}:${row.stage}`, row.users]));
  weeklyData[period] = {
    journey:diag.journey,
    core:{
      logged_in_users:payload.journey.core_logged_in_users,
      class_users:payload.journey.core_class_users,
      dino_users:payload.journey.core_dino_users,
      ...globalModules[period]
    },
    retention:diag.retention,
    segments:['completed_trial','registered_no_trial','not_registered'].map(key => segments.get(key) || [0,0]),
    payment:{
      orders:payload.payment.orders, users:payload.payment.users, pending:payload.payment.pending,
      success:payload.payment.production_success, sandbox:payload.payment.sandbox_success,
      failed:payload.payment.failed, apple:payload.payment.apple_success, google:payload.payment.google_success,
      week:payload.payment.week_success, month:payload.payment.month_success, year:payload.payment.year_success
    },
    levels:groupOrder.map(group => stageOrder.map(stage => stageMap.get(`${group}:${stage}`) || 0))
  };
}

const coreMetrics = new Map(readRows('core-ga4').map(row => [row.metric, row.value]));
const retentionRows = readRows('retention');
const globalMetricRows = readRows('core-global');
const allPaymentPayload = JSON.parse(globalMetricRows.find(row => row.row_type === 'metric' && row.period_key === 'all' && row.country_key === 'all').payload);
const allSegments = new Map(retentionRows.filter(row => row.row_type === 'segment').map(row => [row.row_key, [num(row.devices),num(row.v1)]]));
const allLevels = groupOrder.map(group => stageOrder.map(stage => metricValue(coreMetrics, `lesson_stage|${group}|${stage}`)));
const allData = {
  journey:diagnosticData.all.all.journey,
  core:{
    logged_in_users:metricValue(coreMetrics,'core_logged_in_users'),
    class_users:metricValue(coreMetrics,'core_class_users'),
    dino_users:metricValue(coreMetrics,'core_dino_users'),
    ...globalModules.all
  },
  retention:diagnosticData.all.all.retention,
  segments:['completed_trial','registered_no_trial','not_registered'].map(key => allSegments.get(key) || [0,0]),
  payment:{
    orders:allPaymentPayload.orders, users:allPaymentPayload.users, pending:allPaymentPayload.pending,
    success:allPaymentPayload.production_success, sandbox:allPaymentPayload.sandbox_success,
    failed:allPaymentPayload.failed, apple:allPaymentPayload.apple_success, google:allPaymentPayload.google_success,
    week:allPaymentPayload.week_success, month:allPaymentPayload.month_success, year:allPaymentPayload.year_success
  },
  levels:allLevels
};

const countryModuleRows = JSON.parse(fs.readFileSync(path.join(resultDir,'country-modules.json'),'utf8'));
const metricMap = new Map(globalMetricRows.filter(row => row.row_type === 'metric').map(row => [`${row.period_key}:${row.country_key}`, JSON.parse(row.payload)]));
const globalRetentionRows = readRows('retention-global');
const segmentMap = new Map(globalRetentionRows.filter(row => row.row_type === 'segment').map(row => [`${row.period_key}:${row.country_key}:${row.row_key}`, [num(row.devices),num(row.v1)]]));
const countryBusinessData = {};
for (const period of periods) {
  countryBusinessData[period] = {};
  for (const country of countries) {
    const metric = metricMap.get(`${period}:${country}`);
    if (!metric) throw new Error(`Missing country metric ${period}:${country}`);
    countryBusinessData[period][country] = {
      core:{logged_in_users:metric.logged_in_users,class_users:metric.class_users,dino_users:metric.dino_users,...countryModuleRows[country][period]},
      segments:['completed_trial','registered_no_trial','not_registered'].map(key => segmentMap.get(`${period}:${country}:${key}`) || [0,0]),
      payment:{orders:metric.orders,users:metric.users,pending:metric.pending,success:metric.production_success,sandbox:metric.sandbox_success,failed:metric.failed,apple:metric.apple_success,google:metric.google_success,week:metric.week_success,month:metric.month_success,year:metric.year_success}
    };
  }
}

const stagePrefixes = {
  '732':['warm-up-template','reward-chest-intro','lead-in-template','play-video-template','word_teach_image','practice_tap_to_hear','word_practice_bubble_image','word_practice_oral_assessment','reward-chest-step1','sentence_teach','practice_listen_choose_image','sentence_practice_oral_assessment','reward-chest-step2','wrapup_summary','photo_time','reward-chest-step3'],
  '1615':['warm-up-template','reward-chest-intro','lead-in-template','play-video-template','word_teach_image','word_practice_bubble_image','word_practice_img_select_word','word_practice_oral_assessment','reward-chest-step1','sentence_teach','sentence_word_order','sentence_practice_oral_assessment','reward-chest-step2','wrapup_summary','photo_time','reward-chest-step3'],
  '734':['warm-up-template','reward-chest-intro','lead-in-template','play-video-template','word_teach_image','word_practice_bubble_image','word_practice_word_select_img','word_practice_img_select_word','word_practice_oral_assessment','reward-chest-step1','sentence_teach','practice_listen_choose_image','sentence_word_order','sentence_practice_oral_assessment','reward-chest-step2','wrapup_summary','photo_time','reward-chest-step3'],
  '733':['warm-up-template','reward-chest-intro','lead-in-template','play-video-template','word_teach_image','practice_listen_choose_image','word_practice_oral_assessment','word_practice_spelling','reward-chest-step1','sentence_teach','sentence_word_order','sentence_practice_oral_assessment','reward-chest-step2','wrapup_summary','photo_time','reward-chest-step3'],
  '1613':['warm-up-template','reward-chest-intro','lead-in-template','play-video-template','word_teach_image','practice_listen_choose_image','word_practice_word_select_img','word_practice_img_select_word','word_practice_oral_assessment','word_practice_spelling','reward-chest-step1','sentence_teach','sentence_practice_oral_assessment','sentence_word_order','reward-chest-step2','wrapup_summary','photo_time','reward-chest-step3'],
  '1614':['warm-up-template','reward-chest-intro','free_talk_images','play-video-template','decodable_reader_images','discourse_practice','sentence_practice_oral_assessment','reward-chest-step1','reward-chest-step2','photo_time','reward-chest-step3']
};
const lessonIds = ['732','1615','734','733','1613','1614'];
const levelRows = readRows('level-global');
const levelMap = new Map(levelRows.map(row => [`${row.period_key}:${row.country_key}:${row.lesson_id}`, JSON.parse(row.payload)]));
const countryLevelValues = {};
for (const period of periods) {
  countryLevelValues[period] = {};
  for (const country of countries) {
    countryLevelValues[period][country] = lessonIds.map(lessonId => {
      const payload = levelMap.get(`${period}:${country}:${lessonId}`) || [];
      return stagePrefixes[lessonId].map(prefix => payload.find(item => item.template_id.startsWith(prefix))?.users || 0);
    });
  }
}
const countryRetentionRows = Object.fromEntries(countries.map(country => [country,
  globalRetentionRows.filter(row => row.row_type === 'cohort' && row.country_key === country)
    .sort((a,b) => a.row_key.localeCompare(b.row_key))
    .map(row => ({d:row.row_key.slice(5),n:num(row.devices),r:[row.v1,row.v2,row.v3,row.v4,row.v5,row.v6,row.v7].map(num)}))
]));
const allRetention = retentionRows.filter(row => row.row_type === 'cohort').sort((a,b)=>a.row_key.localeCompare(b.row_key))
  .map(row => ({d:row.row_key.slice(5),n:num(row.devices),r:[row.v1,row.v2,row.v3,row.v4,row.v5,row.v6,row.v7].map(num)}));

const abWeeklyRows = readRows('ab-weekly');
const abByPeriod = new Map(abWeeklyRows.map(row => [row.week_key, JSON.parse(row.payload)]));
const makeAbCountries = period => {
  const payload = abByPeriod.get(period);
  return ['all',...countries].map(country => {
    const meta = countryMeta[country];
    const a = payload.find(row => row.country_key === country && row.experiment_group === 'a');
    const b = payload.find(row => row.country_key === country && row.experiment_group === 'b');
    const side = row => ({assigned:row?.assigned||0,payAssigned:row?.pay_assigned||0,paid:row?.paid||0,pending:row?.pending||0,lessonStart:row?.lesson_started||0,counts:row?.counts||[]});
    return {key:country,tab:meta.tab,label:meta.label,...(meta.code?{code:meta.code}:{}),a:side(a),b:side(b)};
  });
};
const abAllCountries = makeAbCountries('all');
const abWeekly = {w4:makeAbCountries('w4'),w5:makeAbCountries('w5'),w6:makeAbCountries('w6')};

const periodConfig = [
  {key:'all',tabEn:'All',tabZh:'全部',label:'07-10~08-17 02:15',statusEn:'Full period · Complete UTC days through Aug 16 + rolling Aug 17',statusZh:'全周期 · 完整 UTC 日截至 08-16 + 08-17 滚动数据'},
  {key:'w1',tabEn:'07-10~07-16',tabZh:'07-10~07-16',label:'07-10~07-16',statusEn:'Week 1 · Complete UTC week',statusZh:'第 1 周 · UTC 完整周'},
  {key:'w2',tabEn:'07-17~07-23',tabZh:'07-17~07-23',label:'07-17~07-23',statusEn:'Week 2 · Complete UTC week',statusZh:'第 2 周 · UTC 完整周'},
  {key:'w3',tabEn:'07-24~07-30',tabZh:'07-24~07-30',label:'07-24~07-30',statusEn:'Week 3 · Complete UTC week',statusZh:'第 3 周 · UTC 完整周'},
  {key:'w4',tabEn:'07-31~08-06',tabZh:'07-31~08-06',label:'07-31~08-06',statusEn:'Week 4 · A/B calculated from Aug 1',statusZh:'第 4 周 · A/B 从 08-01 起计算'},
  {key:'w5',tabEn:'08-07~08-13',tabZh:'08-07~08-13',label:'08-07~08-13',statusEn:'Week 5 · Complete UTC week',statusZh:'第 5 周 · UTC 完整周'},
  {key:'w6',tabEn:'08-14~08-17*',tabZh:'08-14~08-17*',label:'08-14 00:00~08-17 02:15',statusEn:'Week 6 · Complete days through Aug 16 + rolling Aug 17',statusZh:'第 6 周 · 完整日截至 08-16 + 08-17 滚动'}
];

function updateLaunch(html) {
  html = replaceFrom(html,'const PERIODS=','const WEEKLY=',`const PERIODS=${compact(periodConfig)};`);
  html = replaceFrom(html,'const WEEKLY=','const ALL=',`const WEEKLY=${compact(weeklyData)};`);
  html = replaceLine(html,'const ALL=',`const ALL=${compact(allData)};`);
  html = replaceFrom(html,'const DIAGNOSTIC_COUNTRY_DATA=','const COUNTRY_BUSINESS_DATA=',`const DIAGNOSTIC_COUNTRY_DATA=${compact(diagnosticData)};`);
  html = replaceLine(html,'const COUNTRY_BUSINESS_DATA=',`const COUNTRY_BUSINESS_DATA=${compact(countryBusinessData)};`);
  html = replaceLine(html,'const COUNTRY_LEVEL_VALUES=',`const COUNTRY_LEVEL_VALUES=${compact(countryLevelValues)};`);
  html = replaceLine(html,'const COUNTRY_RETENTION_ROWS=',`const COUNTRY_RETENTION_ROWS=${compact(countryRetentionRows)};`);
  html = replaceFrom(html,'const AB_ALL_COUNTRIES=','const AB_WEEKLY=',`const AB_ALL_COUNTRIES=${compact(abAllCountries)};`);
  html = replaceFrom(html,'const AB_WEEKLY=','let AB_MAIN_COUNTRIES=',`const AB_WEEKLY=${compact(abWeekly)};`);
  html = replaceLine(html,'const retAll=',`const retAll=${compact(allRetention)};`);
  html = replaceLine(html,'const RET_RANGES=',`const RET_RANGES={w1:['07-10','07-16'],w2:['07-17','07-23'],w3:['07-24','07-30'],w4:['07-31','08-06'],w5:['08-07','08-13'],w6:['08-14','08-15']};`);
  html = html
    .replaceAll('07-10~08-14 15:08','07-10~08-17 02:15')
    .replaceAll('2026-07-10 00:00 → 08-14 15:08(UTC)','2026-07-10 00:00 → 08-17 02:15（UTC）')
    .replaceAll('07-10~08-13 使用日表，08-14 使用 intraday 滚动数据','07-10~08-15 使用日表，08-16~17 使用 intraday 数据')
    .replaceAll('07-10~08-13 日表 + 08-14 intraday','07-10~08-15 日表 + 08-16~17 intraday')
    .replaceAll('2026-08-14 15:08 UTC','2026-08-17 02:15 UTC')
    .replaceAll('Aug 13 is the latest complete UTC day; Aug 14 is rolling','Aug 16 is the latest complete UTC day; Aug 17 is rolling')
    .replaceAll('08-13 为最近完整 UTC 日，08-14 为滚动日','08-16 为最近完整 UTC 日，08-17 为滚动日')
    .replaceAll('08-14 15:00:52 UTC','08-17 02:15 UTC 截点内')
    .replaceAll('Aug 14 15:00:52 UTC','the Aug 17 02:15 UTC cutoff')
    .replaceAll('D1 可测至 08-12、D3 至 08-10、D7 至 08-06','D1 可测至 08-15、D3 至 08-13、D7 至 08-09')
    .replaceAll('2026-08-14 15:08 UTC（北京时间 23:08）','2026-08-17 02:15 UTC（马来西亚 10:15）')
    .replaceAll('2026-08-14 15:08 UTC (23:08 Beijing time)','2026-08-17 02:15 UTC (10:15 Malaysia time)')
    .replaceAll('（北京时间 23:08）','（马来西亚 10:15）')
    .replaceAll('(23:08 Beijing time)','(10:15 Malaysia time)')
    .replaceAll('08-01~08-14 15:08 UTC','08-01~08-17 02:15 UTC')
    .replaceAll('35 个完整日 + 当日滚动','38 个完整 UTC 日 + 08-17 滚动')
    .replace('期内启动 <b>34,880</b>',`期内启动 <b>${allData.journey.first_open.toLocaleString('en-US')}</b>`)
    .replaceAll("{l:'发起支付订单',s:'payment_order 创建 · GA4 checkout_start 埋点',v:3765",`{l:'发起支付订单',s:'payment_order 创建 · GA4 checkout_start 埋点',v:${allData.payment.orders}`)
    .replaceAll("note:'3,717 PENDING + 43 生产成功 + 4 沙盒 + 1 失败 · 1,920 用户'",`note:'${allData.payment.pending.toLocaleString('en-US')} PENDING + ${allData.payment.success} 生产成功 + ${allData.payment.sandbox} 沙盒 + ${allData.payment.failed} 失败 · ${allData.payment.users.toLocaleString('en-US')} 用户'`)
    .replaceAll("{l:'成功付费订单',s:'payment_order status=SUCCESS · 生产',v:43",`{l:'成功付费订单',s:'payment_order status=SUCCESS · 生产',v:${allData.payment.success}`)
    .replaceAll("note:'生产环境 · 权威口径(Apple 22 / Google 21)'",`note:'生产环境 · 权威口径(Apple ${allData.payment.apple} / Google ${allData.payment.google})'`)
    .replaceAll("{l:'订阅周期分布',s:'43 笔生产成功订单按 billing_period 分布',v:43",`{l:'订阅周期分布',s:'${allData.payment.success} 笔生产成功订单按 billing_period 分布',v:${allData.payment.success}`)
    .replaceAll("note:'周卡 23 / 月卡 19 / 年卡 1'",`note:'周卡 ${allData.payment.week} / 月卡 ${allData.payment.month} / 年卡 ${allData.payment.year}'`);
  return html;
}

const abCoreRows = readRows('ab-core');
const abPaymentRows = readRows('ab-payment');
const abGroups = mapBy(abCoreRows.filter(row=>row.row_type==='group'), row=>row.row_key);
const abPay = mapBy(abPaymentRows, row=>`${row.platform_scope}:${row.country_key}:${row.experiment_group}`);
const groupToTotal = row => ({assigned:num(row.v1),firstOpen:num(row.v7),loginPage:num(row.v8),registered:num(row.v3),registeredDenom:num(row.v2),registeredRolling:num(row.v4),paywall:num(row.v9),checkout:num(row.v10),lessonStart:num(row.v5),lessonComplete:num(row.v6),lessonIndependentStart:num(row.v5),lessonIndependentComplete:num(row.v6)});
const abTotal = {a:groupToTotal(abGroups.get('all-a')),b:groupToTotal(abGroups.get('all-b'))};
for (const side of ['a','b']) {
  const payment = abPay.get(`ANDROID_IOS:all:${side}`);
  abTotal[side].pending = num(payment.pending_orders);
  abTotal[side].paid = num(payment.production_success_orders);
}
const erf = x => {
  const sign=x<0?-1:1, a=Math.abs(x), t=1/(1+0.3275911*a);
  const y=1-(((((1.061405429*t-1.453152027)*t+1.421413741)*t-0.284496736)*t+0.254829592)*t)*Math.exp(-a*a);
  return sign*y;
};
const normalP = z => 1-erf(Math.abs(z)/Math.SQRT2);
const compareRates = (aSuccess,aTotal,bSuccess,bTotal) => {
  const pa=aSuccess/aTotal,pb=bSuccess/bTotal,diff=(pb-pa)*100;
  const se=Math.sqrt(pa*(1-pa)/aTotal+pb*(1-pb)/bTotal);
  const pooled=(aSuccess+bSuccess)/(aTotal+bTotal);
  const z=(pb-pa)/Math.sqrt(pooled*(1-pooled)*(1/aTotal+1/bTotal));
  const low=diff-1.96*se*100,high=diff+1.96*se*100;
  const sign=v=>`${v>=0?'+':'−'}${Math.abs(v).toFixed(1)}`;
  const p=normalP(z);
  return {diff:Number(diff.toFixed(2)),ci:`${sign(low)}~${sign(high)}pp`,p:p<0.00001?'<.00001':p.toFixed(p<0.001?5:3).replace(/^0/,'')};
};
const lessonStats=compareRates(abTotal.a.lessonComplete,abTotal.a.lessonStart,abTotal.b.lessonComplete,abTotal.b.lessonStart);
const platformRows = [['全部平台','all','ANDROID_IOS'],['Android','android','ANDROID'],['iOS','ios','IOS']].map(([label,key])=>{
  const a=abGroups.get(`${key}-a`),b=abGroups.get(`${key}-b`),stats=compareRates(num(a.v3),num(a.v2),num(b.v3),num(b.v2));
  return {platform:label,a:{assigned:num(a.v1),mature:num(a.v2),registered:num(a.v3)},b:{assigned:num(b.v1),mature:num(b.v2),registered:num(b.v3)},...stats};
});
const healthMap = mapBy(abCoreRows.filter(row=>row.row_type==='health'),row=>row.row_key);
const allHealth=healthMap.get('all'),androidHealth=healthMap.get('android'),iosHealth=healthMap.get('ios');
const srmP=normalP(Math.abs(abTotal.a.assigned-abTotal.b.assigned)/Math.sqrt(abTotal.a.assigned+abTotal.b.assigned));
const allStats=platformRows[0],androidStats=platformRows[1],iosStats=platformRows[2];
const abHealth = [
  ['正式 A/B 稳定样本',`${(abTotal.a.assigned+abTotal.b.assigned).toLocaleString('en-US')} 台`,`A ${abTotal.a.assigned.toLocaleString('en-US')} / B ${abTotal.b.assigned.toLocaleString('en-US')}；Android ${(num(abGroups.get('android-a').v1)+num(abGroups.get('android-b').v1)).toLocaleString('en-US')}，iOS ${(num(abGroups.get('ios-a').v1)+num(abGroups.get('ios-b').v1)).toLocaleString('en-US')}；已排除测试账号`,'可监控'],
  ['分流均衡性 SRM',`p=${srmP.toFixed(3).replace(/^0/,'')}`,`A/B ${pct(abTotal.a.assigned,abTotal.a.assigned+abTotal.b.assigned)}% / ${pct(abTotal.b.assigned,abTotal.a.assigned+abTotal.b.assigned)}%；未见样本比例异常`,'通过'],
  ['24h 成熟样本',`${(abTotal.a.registeredDenom+abTotal.b.registeredDenom).toLocaleString('en-US')} 台`,`A ${abTotal.a.registeredDenom.toLocaleString('en-US')} / B ${abTotal.b.registeredDenom.toLocaleString('en-US')}；早期注册 B−A ${allStats.diff>=0?'+':''}${allStats.diff.toFixed(1)}pp，p=${allStats.p}`,'显著'],
  ['Android 早期注册',`B−A ${androidStats.diff>=0?'+':''}${androidStats.diff.toFixed(1)}pp`,`95% CI ${androidStats.ci}；p=${androidStats.p}`,'观察'],
  ['iOS 早期注册',`B−A ${iosStats.diff>=0?'+':''}${iosStats.diff.toFixed(1)}pp`,`95% CI ${iosStats.ci}；p=${iosStats.p}`,'观察'],
  ['生产支付',`SUCCESS A ${abTotal.a.paid} / B ${abTotal.b.paid}`,`PENDING A ${abTotal.a.pending.toLocaleString('en-US')} / B ${abTotal.b.pending.toLocaleString('en-US')}；绝对量仍不足`,'未成熟'],
  ['分组冲突',`${num(allHealth.v3)} 台`,`Android ${num(androidHealth.v3)} / iOS ${num(iosHealth.v3)}；已剔除`,'阻断'],
  ['fallback',`${num(allHealth.v2)} / ${num(allHealth.v1).toLocaleString('en-US')} · ${pct(num(allHealth.v2),num(allHealth.v1))}%`,`Android ${pct(num(androidHealth.v2),num(androidHealth.v1))}%，iOS ${pct(num(iosHealth.v2),num(iosHealth.v1))}%；目标 ≤1%`,'阻断'],
  ['分组真相源','experiment_group_assign','首次稳定进组事件；同设备冲突样本已排除','可监控'],
  ['iOS 页面锚点','未对齐','分组/注册/课程结果可读；Onboarding 页面级漏斗暂不跨端合并','阻断'],
  ['首课识别','Lesson ID 白名单','A=732/1615/734/733/1613/1614/1616；B=1661/1616','可监控']
];
const lessonLabels={'732':'Level 1','1615':'Level 2','734':'Level 3','733':'Level 4','1613':'Level 5','1614':'Level 6','1661':'—','1616':'—'};
const abLesson = abCoreRows.filter(row=>row.row_type==='lesson' && row.row_key.startsWith('all-')).map(row=>{
  const [,group,lessonId]=row.row_key.split('-');
  return {type:lessonId==='1616'?'足球课':group==='a'?'体验课':'新人引导课',level:lessonLabels[lessonId],lessonId,group:group.toUpperCase(),started:num(row.v1),completed:num(row.v2)};
}).sort((a,b)=>lessonIds.concat('1661','1616').indexOf(a.lessonId)-lessonIds.concat('1661','1616').indexOf(b.lessonId));
const bLessonRows = readRows('workbench-ab').filter(row=>row.section==='b_lesson');
const bLessonMap = new Map(bLessonRows.map(row=>[row.dim,{start:num(row.v1),end:num(row.v2)}]));
const abBLesson = [
  {label:'开始新人引导课',phase:'课程',count:bLessonMap.get('class_lesson_start').start,ended:null,anchor:'class_lesson_start · lesson_id=1661'},
  {label:'课堂导入',phase:'课内环节',count:bLessonMap.get('lead-in-template_l1l2').start,ended:bLessonMap.get('lead-in-template_l1l2').end,anchor:'class_stage_start/end · lead-in-template_l1l2'},
  {label:'视频示范',phase:'课内环节',count:bLessonMap.get('play-video-template').start,ended:bLessonMap.get('play-video-template').end,anchor:'class_stage_start/end · play-video-template'},
  {label:'单词教学',phase:'课内环节',count:bLessonMap.get('word_teach_image_l1l2').start,ended:bLessonMap.get('word_teach_image_l1l2').end,anchor:'class_stage_start/end · word_teach_image_l1l2'},
  {label:'单词练习',phase:'课内环节',count:bLessonMap.get('word_practice_bubble_image').start,ended:bLessonMap.get('word_practice_bubble_image').end,anchor:'class_stage_start/end · word_practice_bubble_image'},
  {label:'总结收尾',phase:'课内环节',count:bLessonMap.get('wrapup_summary_video_trail').start,ended:bLessonMap.get('wrapup_summary_video_trail').end,anchor:'class_stage_start/end · wrapup_summary_video_trail'},
  {label:'完成新人引导课',phase:'课程',count:bLessonMap.get('class_lesson_end_complete').start,ended:null,anchor:'class_lesson_end · result=complete · lesson_id=1661'}
];
const pageFunnelRows = readRows('workbench-page-funnel').filter(row=>row.platform_key==='android');
const abFlowCountries = ['all','vn','kr','sa','my','id'].map(country=>{
  const meta=countryMeta[country],a=pageFunnelRows.find(row=>row.country_key===country&&row.experiment_group==='a'),b=pageFunnelRows.find(row=>row.country_key===country&&row.experiment_group==='b');
  const side=row=>({assigned:num(row.assigned_devices),counts:row.reached_devices.split(',').map(Number)});
  return {key:country,tab:meta.tab,label:`${meta.label} · Android`,...(meta.code?{code:meta.code}:{}),a:side(a),b:side(b)};
});
const abDay = abCoreRows.filter(row=>row.row_type==='day'&&row.row_key.startsWith('all-')).map(row=>{
  const match=row.row_key.match(/^all-(\d{2}-\d{2})-([ab])$/);return {d:`${match[1]}${match[1]==='08-17'?'*':''}`,g:match[2].toUpperCase(),assigned:num(row.v1),mature:num(row.v2),registered:num(row.v3),registeredRolling:num(row.v4),lessonComplete:num(row.v6),paid:null,pending:null};
});

const signupRows = readRows('signup-method');
const authDays = [...new Set(signupRows.filter(row=>row.cohort_date>='2026-07-29').map(row=>row.cohort_date))].sort();
const authCountries = ['VN','ID','MY','SA','TH','KR','Other'];
const authData = Object.fromEntries(authCountries.map(country=>[country,authDays.map(day=>{
  const row=signupRows.find(item=>item.cohort_date===day&&item.country_code===country);
  return row?[num(row.first_opens),num(row.registered),num(row.google),num(row.phone),num(row.apple),num(row.facebook),num(row.kakao),num(row.unknown)]:Array(8).fill(0);
})]));
const registrationDaily = [...new Set(signupRows.map(row=>row.cohort_date))].sort().map(day=>{
  const rows=signupRows.filter(row=>row.cohort_date===day),sum=key=>rows.reduce((total,row)=>total+num(row[key]),0);
  return {d:`${day.slice(5)}${day==='2026-08-17'?'*':''}`,n:sum('first_opens'),s:sum('registered'),an:sum('android_first_opens'),as:sum('android_registered')};
});
const retentionCurve = retentionRows.filter(row=>row.row_type==='curve');
const retentionSegments = retentionRows.filter(row=>row.row_type==='segment');
const ret = allRetention;
const segLabels={completed_trial:'当日完成首课',registered_no_trial:'当日注册·未完课',not_registered:'当日未注册'};
const workbenchSeg = ['completed_trial','registered_no_trial','not_registered'].map(key=>{const row=retentionSegments.find(item=>item.row_key===key);return [segLabels[key],num(row.devices),num(row.v1)];});
const curveLabels={d1:'D1 次日(07-10~08-15 cohort)',d3:'D3 第 3 天(07-10~08-13 cohort)',d7:'D7 第 7 天(07-10~08-09 cohort)'};
const workbenchCurve=['d1','d3','d7'].map(key=>{const row=retentionCurve.find(item=>item.row_key===key);return [curveLabels[key],num(row.devices),num(row.v1)];});

const paymentRows = readRows('workbench-payment');
const paymentSection = section => paymentRows.filter(row=>row.section===section);
const paymentTotalRow=paymentSection('order_total')[0],paymentTotal={orders:num(paymentTotalRow.v1),users:num(paymentTotalRow.v2),pending:num(paymentTotalRow.v3),production:num(paymentTotalRow.v4),sandbox:num(paymentTotalRow.v5),failed:num(paymentTotalRow.v6)};
const surfaceTotals=Object.fromEntries(paymentSection('surface_total').map(row=>[row.row_key,{events:num(row.v1),users:num(row.v2)}]));
const clientRow=paymentSection('client_funnel')[0],clientFunnel=[num(clientRow.v1),num(clientRow.v2),num(clientRow.v3),num(clientRow.v4)];
const sourceName=name=>name==='__missing__'?'来源缺失':name;
const paywallSources=paymentSection('surface_source').filter(row=>row.row_key.startsWith('paywall|')).map(row=>[row.row_key.split('|')[1],num(row.v1),num(row.v2)]);
const discountSurface=paymentSection('surface_source').filter(row=>row.row_key.startsWith('discount|'));
const checkoutSources=paymentSection('checkout_source').map(row=>[sourceName(row.row_key),num(row.v1),num(row.v2)]);
const orderSources=paymentSection('order_source').map(row=>[sourceName(row.row_key),num(row.v1),num(row.v2),num(row.v3),num(row.v4),num(row.v5),num(row.v6)]);
const orderSourceMap=new Map(orderSources.map(row=>[row[0],row]));
const discountSources=discountSurface.map(row=>{const name=row.row_key.split('|')[1],order=orderSourceMap.get(name)||[name,0,0,0,0,0,0];return [name,num(row.v1),num(row.v2),order[1],order[4]];});
const orderPlatforms=paymentSection('order_platform').map(row=>[row.row_key,num(row.v1),num(row.v2),num(row.v3),num(row.v4),num(row.v5),num(row.v6)]);
const orderPeriods=paymentSection('order_period').map(row=>[row.row_key,num(row.v1),num(row.v2),num(row.v3),num(row.v4),num(row.v5),num(row.v6)]);
const orderOutcomes=paymentSection('order_outcome').map(row=>({key:row.row_key,total:num(row.v1),pending:num(row.v2),production:num(row.v3),sandbox:num(row.v4),failed:num(row.v5)}));
const pendingRow=paymentSection('pending_health')[0],pendingHealth={pending:num(pendingRow.v1),neverUpdated:num(pendingRow.v2),over7d:num(pendingRow.v3),blankPlatform:num(pendingRow.v4)};
const actionStats=Object.fromEntries(paymentSection('action_stats').map(row=>[row.row_key,{events:num(row.v1),users:num(row.v2)}]));

const newcomerRows=readRows('workbench-newcomer');
const newcomerBy=(type,key)=>newcomerRows.find(row=>row.row_type===type&&row.row_key===key);
const newcomer={
  overall:newcomerBy('participation','overall'),signup:newcomerBy('participation','new_signup'),
  matched:newcomerBy('impact','matched_participant'),control:newcomerBy('impact','matched_control'),
  pre:newcomerBy('prepost','pre_0801_0807'),post:newcomerBy('prepost','post_0808_0810'),
  signupImpact:newcomerRows.filter(row=>row.row_type==='signup_impact'),
  summary:newcomerRows.filter(row=>row.row_type==='summary'),
  progress:newcomerRows.filter(row=>row.row_type==='progress'),
  countries:newcomerRows.filter(row=>row.row_type==='participation_country'),
  daily:newcomerRows.filter(row=>row.row_type==='participation_daily')
};

const refreshedSnapshot={cutoff,completeDay:'2026-08-16',newcomer,payment:{total:paymentTotal,surfaceTotals,clientFunnel,orderOutcomes,pendingHealth,actionStats,checkoutTotal:checkoutSources.reduce((s,r)=>s+r[1],0)}};

function updateWorkbench(html) {
  const previousSnapshot = html.indexOf('\n/* 统一实时快照：');
  if (previousSnapshot >= 0) {
    const scriptEnd = html.indexOf('\n</script>', previousSnapshot);
    if (scriptEnd < 0) throw new Error('Could not remove previous generated snapshot');
    html = `${html.slice(0, previousSnapshot)}${html.slice(scriptEnd)}`;
  }
  html=replaceFrom(html,'const AB_TOTAL=','const AB_PLATFORM_TOTAL=',`const AB_TOTAL=${compact(abTotal)};`);
  html=replaceFrom(html,'const AB_PLATFORM_TOTAL=','const AB_FLOW_A_SCHEMA=',`const AB_PLATFORM_TOTAL=${compact(platformRows)};`);
  html=replaceFrom(html,'const AB_FLOW_COUNTRIES=','const AB_DAY_LEGACY=',`const AB_FLOW_COUNTRIES=${compact(abFlowCountries)};`);
  html=replaceFrom(html,'const AB_DAY=','const AB_HEALTH=',`const AB_DAY=${compact(abDay)};`);
  html=replaceFrom(html,'const AB_HEALTH=','const AB_LESSON=',`const AB_HEALTH=${compact(abHealth)};`);
  html=replaceFrom(html,'const AB_LESSON=','const AB_B_ONBOARDING_LESSON=',`const AB_LESSON=${compact(abLesson)};`);
  html=replaceFrom(html,'const AB_B_ONBOARDING_LESSON=','/* ═══════════ 数据(2026-07-10',`const AB_B_ONBOARDING_LESSON=${compact(abBLesson)};\n\n/* ═══════════ 登录注册最新数据（统一截点 ${cutoff}；排除测试账号） ═══════════ */\n// 国家方式数组：[首启,注册,google,phone,apple,facebook,kakao,unknown]\nconst AUTH_METHOD_DAYS=${compact(authDays.map(day=>`${day.slice(5)}${day==='2026-08-17'?'*':''}`))};\nconst AUTH_METHOD_DATA=${compact(authData)};\nconst REG_DAILY=${compact(registrationDaily)};\n\n`);
  html=replaceFrom(html,'const RET=','// Push · Firebase 自动通知事件',`const RET=${compact(ret)};\nconst SEG=${compact(workbenchSeg)};\nconst CURVE=${compact(workbenchCurve)};\n\n// Push · Firebase 自动通知事件`);
  html=replaceFrom(html,'const PAYMENT_PAYWALL_SOURCES=','(function renderPaymentRefresh(){',`const PAYMENT_PAYWALL_SOURCES=${compact(paywallSources)};\nconst PAYMENT_CHECKOUT_SOURCES=${compact(checkoutSources)};\nconst PAYMENT_DISCOUNT_SOURCES=${compact(discountSources)};\nconst PAYMENT_ORDER_SOURCES=${compact(orderSources)};\nconst PAYMENT_ORDER_PLATFORMS=${compact(orderPlatforms)};\nconst PAYMENT_ORDER_PERIODS=${compact(orderPeriods)};`);
  while (html.includes('(function renderPaymentRefresh(){\n(function renderPaymentRefresh(){')) {
    html=html.replace('(function renderPaymentRefresh(){\n(function renderPaymentRefresh(){','(function renderPaymentRefresh(){');
  }
  html=html
    .replaceAll('sourceTable(\'paywallSourceTable\',PAYMENT_PAYWALL_SOURCES,10377)','sourceTable(\'paywallSourceTable\',PAYMENT_PAYWALL_SOURCES,12869)')
    .replaceAll('pct(r[1],2579)','pct(r[1],3050)')
    .replaceAll('pct(r[1],3057)','pct(r[1],3050)')
    .replaceAll('pct(r[1],7301)','pct(r[1],8243)')
    .replaceAll('pct(r[1],3695)','pct(r[1],4182)')
    .replaceAll('2026-08-14 09:01 UTC','2026-08-17 02:15 UTC')
    .replaceAll('08-14 09:01 UTC','08-17 02:15 UTC')
    .replaceAll('08-14 08:00 UTC','08-17 02:15 UTC 截点内')
    .replaceAll('截至 08-13；08-14* 为滚动日','截至 08-16；08-17* 为滚动日')
    .replaceAll('08-13 是最近完整日，08-14* 为滚动部分日','08-16 是最近完整日，08-17* 为滚动部分日')
    .replaceAll('08-13 仅部分设备完成 24h 观察，08-14* 为滚动部分日','08-16 仅部分设备完成 24h 观察，08-17* 为滚动部分日')
    .replaceAll('08-12 及以前使用日表，08-13~14 补 intraday','08-15 及以前使用日表，08-16~17 补 intraday')
    .replaceAll('当前日表到 08-12，08-13~14 补 intraday','当前日表到 08-15，08-16~17 补 intraday')
    .replaceAll('北京时间 17:01','马来西亚时间 10:15')
    .replaceAll('2026-08-08 00:00~08-14 09:01 UTC','2026-08-08 00:00~08-17 02:15 UTC')
    .replaceAll('95% CI +2.4~+7.4pp · p=.00013',`95% CI ${allStats.ci} · p=${allStats.p}`)
    .replaceAll('B +10.9pp · 课程不同',`B ${lessonStats.diff>=0?'+':''}${lessonStats.diff.toFixed(1)}pp · 课程不同`);
  const abConclusion=`    <div class="note"><b>当前结论:</b>排除测试账号后，总体 24h 早期注册率 A <b>${pct(abTotal.a.registered,abTotal.a.registeredDenom)}%</b> / B <b>${pct(abTotal.b.registered,abTotal.b.registeredDenom)}%</b>，B−A <b>${allStats.diff>=0?'+':''}${allStats.diff.toFixed(1)}pp</b>（p=${allStats.p.replace('<','&lt;')}）；Android 为 ${androidStats.diff>=0?'+':''}${androidStats.diff.toFixed(1)}pp，iOS 为 ${iosStats.diff>=0?'+':''}${iosStats.diff.toFixed(1)}pp。独立首课完课率 B−A ${lessonStats.diff>=0?'+':''}${lessonStats.diff.toFixed(1)}pp，但两组课程构成不同；生产支付成功 A ${abTotal.a.paid} / B ${abTotal.b.paid} 单。<b>当前仍不能仅凭单一早期指标判定胜负，继续实验。</b></div>`;
  html=html.replace(/    <div class="note"><b>当前结论:<\/b>[^\n]*<\/div>/,abConclusion);

  const updater=`\n/* 统一实时快照：${cutoff}。静态摘要在运行时用同一批查询结果覆盖。 */\nconst REFRESHED_SNAPSHOT=${compact(refreshedSnapshot)};\n(function applyRefreshedSnapshot(){\n const snap=REFRESHED_SNAPSHOT,n=v=>Number(v).toLocaleString('en-US'),rate=(a,b,d=1)=>b?(a/b*100).toFixed(d):'0.0';\n const setKpi=(section,index,value,note)=>{const k=section?.querySelectorAll('.kpi')[index];if(!k)return;k.querySelector('.kv').textContent=value;k.querySelector('.kn').textContent=note};\n const section=(group,tab)=>document.querySelector(\`.sec[data-group="\${group}"][data-tab="\${tab}"]\`);\n const card=(sec,title)=>[...sec.querySelectorAll('.card')].find(item=>item.querySelector('.card-t')?.textContent.includes(title));\n const login=section('login','注册总览'),complete=REG_DAILY.filter(r=>!r.d.endsWith('*')).slice(-3),rolling=REG_DAILY.at(-1);\n const cn=complete.reduce((s,r)=>s+r.n,0),cs=complete.reduce((s,r)=>s+r.s,0);\n if(login){login.querySelector('.sec-desc').innerHTML='核心只保留一条主指标：<b>首启当日注册成功设备 ÷ 当日首启设备</b>。按 GA4 user_pseudo_id 去重、UTC 日 cohort，并排除 <b>user_type=test</b>；08-16 是最近完整日，08-17* 为滚动部分日。';const tip=login.querySelector('.tip');if(tip)tip.innerHTML=\`<b>核心洞察:</b>最近三个完整日 08-14~16 注册率为 <b>\${rate(cs,cn)}%</b>（\${n(cs)} / \${n(cn)}）；当前滚动日 08-17* 为 \${rate(rolling.s,rolling.n)}%（\${n(rolling.s)} / \${n(rolling.n)}），只作实时观察。\`;}\n const nw=section('retention','签到欢迎礼');if(nw){const x=snap.newcomer,o=x.overall,s=x.signup,m=x.matched,c=x.control,pre=x.pre,post=x.post,diff=Number(m.rate)-Number(c.rate),preDiff=Number(post.rate)-Number(pre.rate);nw.querySelector('.sec-desc').innerHTML='V1.5.1 上线首轮观测，窗口为 <b>2026-08-08 00:00~08-17 02:15 UTC</b>。活动资格覆盖新老注册用户；当前仅纳入越南、韩国、沙特、马来西亚、印度尼西亚五国并排除 test / debug。';nw.querySelector('.note').innerHTML=\`<b>核心结论：</b>当前首要问题仍是参与覆盖：Day1 参与率 <b>\${Number(o.rate).toFixed(1)}%</b>。参与者 D1 比同日、同国家、同平台未参与者高 <b>\${diff.toFixed(1)}pp</b>；新注册全量 D1 上线前后变化 <b>\${preDiff>=0?'+':''}\${preDiff.toFixed(1)}pp</b>。两者均为相关观察，不代表因果净提升。\`;setKpi(nw,0,n(o.v1),\`含新老用户；参与分母代理\`);setKpi(nw,1,\`\${Number(o.rate).toFixed(1)}%\`,\`\${n(o.v2)} / \${n(o.v1)}；账号级去重\`);setKpi(nw,2,\`\${Number(s.rate).toFixed(1)}%\`,\`\${n(s.v2)} / \${n(s.v1)}；注册同日参与 \${n(s.v3)}\`);setKpi(nw,3,\`\${Number(x.progress[0].rate).toFixed(1)}%\`,\`\${n(x.progress[0].v1)} / \${n(x.progress[0].v2)} 个已成熟 cohort\`);setKpi(nw,4,\`+\${diff.toFixed(1)}pp\`,\`\${Number(m.rate).toFixed(1)}% vs 匹配未参与 \${Number(c.rate).toFixed(1)}%；非因果\`);setKpi(nw,5,\`\${preDiff>=0?'+':''}\${preDiff.toFixed(1)}pp\`,\`\${Number(pre.rate).toFixed(1)}% → \${Number(post.rate).toFixed(1)}%\`);const flow=card(nw,'参与主漏斗')?.querySelectorAll('.flow-step');if(flow){const vals=[[o.v1,'含新老用户 · 账号级去重'],[o.v2,\`\${Number(o.rate).toFixed(1)}%\`],[x.progress[0].v1,\`\${n(x.progress[0].v1)} / \${n(x.progress[0].v2)} · \${Number(x.progress[0].rate).toFixed(1)}%\`],[x.progress[1].v1,\`\${n(x.progress[1].v1)} / \${n(x.progress[1].v2)} · \${Number(x.progress[1].rate).toFixed(1)}%\`]];flow.forEach((el,i)=>{el.querySelector('.flow-num').textContent=n(vals[i][0]);el.querySelector('.flow-rate').textContent=vals[i][1]})}const countryTable=card(nw,'按国家看 Day1 参与')?.querySelector('table');if(countryTable)countryTable.innerHTML='<tr><th>国家</th><th>可识别活跃</th><th>参与账号</th><th>参与率</th></tr>'+x.countries.sort((a,b)=>Number(b.rate)-Number(a.rate)).map(r=>\`<tr><td>\${r.label}</td><td>\${n(r.v1)}</td><td>\${n(r.v2)}</td><td><b>\${Number(r.rate).toFixed(1)}%</b></td></tr>\`).join('');const dailyTable=card(nw,'每日 Day1 参与')?.querySelector('table');if(dailyTable)dailyTable.innerHTML='<tr><th>日期</th><th>可识别活跃</th><th>参与账号</th><th>参与率</th><th style="text-align:left">阶段</th></tr>'+x.daily.map(r=>\`<tr\${r.row_key==='2026-08-17'?' class="warnrow"':''}><td>\${r.row_key.slice(5)}\${r.row_key==='2026-08-17'?'*':''}</td><td>\${n(r.v1)}</td><td>\${n(r.v2)}</td><td>\${Number(r.rate).toFixed(1)}%</td><td style="text-align:left">\${r.row_key==='2026-08-17'?'滚动日':'完整日'}</td></tr>\`).join('');}\n const pay=section('payment','转化总览');if(pay){const p=snap.payment,t=p.total,sf=p.surfaceTotals,cf=p.clientFunnel;setKpi(pay,0,n(sf.paywall.users),\`\${n(sf.paywall.events)} 次曝光 · GA4 设备去重\`);setKpi(pay,1,n(sf.discount.users),\`\${n(sf.discount.events)} 次曝光 · 折扣订阅页\`);setKpi(pay,2,n(sf.any.users),'Paywall 与折扣页跨页面去重');setKpi(pay,3,\`\${rate(cf[1],cf[0])}%\`,\`\${n(cf[0])} 台曝光设备中 \${n(cf[1])} 台随后发起支付\`);setKpi(pay,4,\`\${rate(t.production,t.orders,2)}%\`,\`\${n(t.production)} / \${n(t.orders)} 笔；PENDING \${n(t.pending)} 笔\`);const missing=PAYMENT_ORDER_SOURCES.find(r=>r[0]==='来源缺失');setKpi(pay,5,\`\${rate(missing[1],t.orders)}%\`,\`\${n(missing[1])} / \${n(t.orders)} 笔 subscription_source 为空\`);const flow=pay.querySelectorAll('.push-flow .flow-step');const flowVals=[[cf[0],'Paywall / 折扣页跨页面去重'],[cf[1],\`\${rate(cf[1],cf[0])}% · 可归因 checkout\`],[cf[2],\`\${rate(cf[2],cf[1])}% · 含取消 / 失败 / 成功\`],[cf[3],\`\${rate(cf[3],cf[2])}% · 仅诊断，不作财务口径\`]];flow.forEach((el,i)=>{el.querySelector('.flow-num').textContent=n(flowVals[i][0]);el.querySelector('.flow-rate').textContent=flowVals[i][1]});const settle=card(pay,'生产订单结算漏斗')?.querySelector('table');if(settle)settle.innerHTML=\`<tr><th>环节 / 状态</th><th>订单</th><th>占全部订单</th><th>说明</th></tr><tr><td>创建订单</td><td><b>\${n(t.orders)}</b></td><td>100%</td><td>进入结算即建单</td></tr><tr class="warnrow"><td>PENDING</td><td><b>\${n(t.pending)}</b></td><td class="down">\${rate(t.pending,t.orders)}%</td><td>未收到可确认的生产成功结果</td></tr><tr><td>生产成功</td><td><b>\${n(t.production)}</b></td><td class="up">\${rate(t.production,t.orders,2)}%</td><td>Apple 22 / Google 24</td></tr><tr><td>沙盒成功</td><td>\${t.sandbox}</td><td>\${rate(t.sandbox,t.orders,2)}%</td><td>测试环境，排除商业转化</td></tr><tr><td>失败</td><td>\${t.failed}</td><td>\${rate(t.failed,t.orders,2)}%</td><td>显式 FAILED</td></tr>\`;const note=pay.querySelector('.note');if(note)note.innerHTML=\`<b>当前第一优先级仍是修复链路可解释性与支付回执：</b>生产订单有 \${rate(missing[1],t.orders)}% 来源缺失，且 \${rate(t.pending,t.orders)}% 停在 PENDING。先把 source 和订单终态打通，再比较入口优劣。\`;}\n const diag=section('payment','支付结果诊断');if(diag){const p=snap.payment,t=p.total,ph=p.pendingHealth,matched=t.orders-p.orderOutcomes.find(r=>r.key==='unmatched_checkout_start').total,client=p.orderOutcomes.find(r=>r.key==='client_success');setKpi(diag,0,n(t.orders),\`\${n(t.users)} 个账号 · ODS 权威口径\`);setKpi(diag,1,\`\${rate(t.pending,t.orders,2)}%\`,\`\${n(t.pending)} 笔；创建后均未再更新\`);setKpi(diag,2,n(t.production+t.sandbox+t.failed),\`生产成功 \${t.production} · 沙盒 \${t.sandbox} · 失败 \${t.failed}\`);setKpi(diag,3,\`\${rate(ph.over7d,ph.pending)}%\`,\`\${n(ph.over7d)} / \${n(ph.pending)}；不是正常短时等待\`);setKpi(diag,4,\`\${rate(matched,t.orders)}%\`,\`\${n(matched)} / \${n(t.orders)} 可按 order_id 串联\`);setKpi(diag,5,\`\${rate(client.production,client.total)}%\`,\`\${client.production} / \${client.total}；仅 \${client.pending} 笔成功信号仍 Pending\`);const status=card(diag,'后端订单终态')?.querySelector('table');if(status)status.innerHTML=\`<tr><th>后端状态</th><th>订单</th><th>占全部订单</th><th>判读</th></tr><tr class="warnrow"><td>PENDING</td><td><b>\${n(t.pending)}</b></td><td class="down">\${rate(t.pending,t.orders,2)}%</td><td>默认购买意图状态；创建后未更新</td></tr><tr><td>SUCCESS · PRODUCTION</td><td><b>\${t.production}</b></td><td class="up">\${rate(t.production,t.orders,2)}%</td><td>唯一计入商业支付成功的终态</td></tr><tr><td>SUCCESS · SANDBOX</td><td>\${t.sandbox}</td><td>\${rate(t.sandbox,t.orders,2)}%</td><td>测试环境成功</td></tr><tr><td>FAILED</td><td>\${t.failed}</td><td>\${rate(t.failed,t.orders,2)}%</td><td>后端明确记录失败</td></tr><tr><td>CANCELED / ABANDONED</td><td>0</td><td>0%</td><td>客户端取消与无结果尚未同步收口</td></tr>\`;const outcome=card(diag,'5 类互斥去向')?.querySelector('table');if(outcome){const names={client_fail_or_cancel:'客户端失败 / 取消',unmatched_checkout_start:'未匹配 checkout_start',checkout_start_no_result:'已拉起 · 无结果',result_missing_is_success:'结果字段缺失',client_success:'客户端成功'};outcome.innerHTML='<tr><th>互斥去向</th><th>订单</th><th>PENDING</th><th>生产成功</th><th>沙盒</th><th>失败</th></tr>'+p.orderOutcomes.map(r=>\`<tr><td>\${names[r.key]}</td><td>\${n(r.total)}</td><td>\${n(r.pending)}</td><td>\${r.production}</td><td>\${r.sandbox}</td><td>\${r.failed}</td></tr>\`).join('')}}\n})();\n`;
  const updaterExtras=`\n(function refineSnapshotCards(){
 const snap=REFRESHED_SNAPSHOT,n=v=>Number(v).toLocaleString('en-US'),rate=(a,b,d=1)=>b?(Number(a)/Number(b)*100).toFixed(d):'0.0';
 const sec=(group,tab)=>document.querySelector('.sec[data-group="'+group+'"][data-tab="'+tab+'"]');
 const findCard=(section,title)=>[...section.querySelectorAll('.card')].find(item=>item.querySelector('.card-t')?.textContent.includes(title));
 const nw=sec('retention','签到欢迎礼');
 if(nw){
  const x=snap.newcomer,o=x.overall,s=x.signup,m=x.matched,c=x.control,pre=x.pre,post=x.post;
  const si=Object.fromEntries(x.signupImpact.map(r=>[r.row_key,r])),learning=x.summary.find(r=>r.row_key==='learning_24h');
  const main=findCard(nw,'参与主漏斗'),daily=findCard(nw,'每日 Day1 参与');
  main.querySelector('.card-s').textContent='Day2 / Day3 使用各自已成熟 cohort 作分母，不能直接用 '+n(o.v1)+' 作为后续节点分母';
  main.querySelector('.legend').textContent='当前已可观察 D7 成熟小样本；完整 14 日窗口仍需继续等待。';
  daily.querySelector('.card-s').textContent='每日账号去重；08-17* 截至 02:15 UTC，为滚动部分日';
  const triangle=findCard(nw,'留存影响 · 三角验证').querySelector('table');
  triangle.innerHTML='<tr><th style="text-align:left">比较</th><th>组别</th><th>样本</th><th>D1 回访</th><th>D1</th><th>差异</th><th style="text-align:left">可以怎么解释</th></tr>'+
   '<tr><td rowspan="2" style="text-align:left">同日 × 国家 × 平台</td><td>参与</td><td>'+n(m.v1)+'</td><td>'+n(m.v2)+'</td><td><b>'+Number(m.rate).toFixed(1)+'%</b></td><td rowspan="2" class="up"><b>+'+(Number(m.rate)-Number(c.rate)).toFixed(1)+'pp</b></td><td rowspan="2" style="text-align:left">匹配了日期、国家、平台，但未控制用户意愿；只能说明相关</td></tr>'+
   '<tr><td>未参与 · 标准化</td><td>'+n(c.v1)+'</td><td>'+n(c.v2)+'</td><td>'+Number(c.rate).toFixed(1)+'%</td></tr>'+
   '<tr><td rowspan="2" style="text-align:left">同期新注册账号</td><td>注册同日参与</td><td>'+n(si.participated.v1)+'</td><td>'+n(si.participated.v2)+'</td><td><b>'+Number(si.participated.rate).toFixed(1)+'%</b></td><td rowspan="2" class="up"><b>+'+(Number(si.participated.rate)-Number(si.not_participated.rate)).toFixed(1)+'pp</b></td><td rowspan="2" style="text-align:left">仍有主动参与选择偏差，不能解释为功能净提升</td></tr>'+
   '<tr><td>未参与</td><td>'+n(si.not_participated.v1)+'</td><td>'+n(si.not_participated.v2)+'</td><td>'+Number(si.not_participated.rate).toFixed(1)+'%</td></tr>'+
   '<tr><td rowspan="2" style="text-align:left">全量新注册 · 前后</td><td>上线前 08-01~07</td><td>'+n(pre.v1)+'</td><td>'+n(pre.v2)+'</td><td>'+Number(pre.rate).toFixed(1)+'%</td><td rowspan="2" class="flat"><b>+'+(Number(post.rate)-Number(pre.rate)).toFixed(1)+'pp</b></td><td rowspan="2" style="text-align:left">全量层尚未看到足以确认因果的提升</td></tr>'+
   '<tr><td>上线后 08-08~10</td><td>'+n(post.v1)+'</td><td>'+n(post.v2)+'</td><td>'+Number(post.rate).toFixed(1)+'%</td></tr>';
  findCard(nw,'新注册子群参与拆分').querySelector('table').innerHTML='<tr><th>口径</th><th>账号</th><th>占 '+n(s.v1)+' 个新注册账号</th></tr><tr><td>窗口内参与</td><td>'+n(s.v2)+'</td><td><b>'+rate(s.v2,s.v1)+'%</b></td></tr><tr><td>注册同日参与</td><td>'+n(s.v3)+'</td><td>'+rate(s.v3,s.v1)+'%</td></tr><tr><td>窗口内未参与</td><td>'+n(Number(s.v1)-Number(s.v2))+'</td><td>'+rate(Number(s.v1)-Number(s.v2),s.v1)+'%</td></tr>';
  findCard(nw,'参与后的学习承接').querySelector('table').innerHTML='<tr><th>观察点</th><th>可观察账号</th><th>达成</th><th>比率</th></tr><tr><td>Day1 领取后 24h 进课</td><td>'+n(learning.v3)+'</td><td>'+n(learning.v1)+'</td><td><b>'+rate(learning.v1,learning.v3)+'%</b></td></tr><tr><td>Day1 领取后 24h 完课</td><td>'+n(learning.v3)+'</td><td>'+n(learning.v2)+'</td><td>'+rate(learning.v2,learning.v3)+'%</td></tr>';
  nw.querySelector('.tip').innerHTML='<b>数据限制：</b>当前 '+Number(o.rate).toFixed(1)+'% 是“参与账号 ÷ 可识别活跃账号”，不是严格资格曝光转化率；资格 / unlock / calendar / claim / continue / close 事件仍缺失。优先补齐资格、日历曝光与领取点击事件，再按新老用户复查真实曝光→参与→留存转化。';
 }
 const pay=sec('payment','转化总览');
 if(pay){const p=snap.payment,t=p.total,flow=findCard(pay,'客户端可串联漏斗'),settle=findCard(pay,'生产订单结算漏斗');flow.querySelector('.legend').textContent='全部 checkout：'+n(p.actionStats.subscription_checkout_start.events)+' 次 / '+n(p.checkoutTotal)+' 个 order_id / '+n(p.actionStats.subscription_checkout_start.users)+' 台设备；其中 '+n(p.clientFunnel[1])+' 台能在同设备向前串到已知付费页面。';settle.querySelector('.card-s').textContent='de_ods.payment_order · '+n(t.orders)+' 笔 / '+n(t.users)+' 个账号';}
 const diag=sec('payment','支付结果诊断');
 if(diag){const p=snap.payment,t=p.total,client=p.orderOutcomes.find(r=>r.key==='client_success');diag.querySelector('.note').innerHTML='<b>核心判断：</b>PENDING 的主体仍是购买意图创建后没有被写回终态。'+n(t.pending)+' 笔 PENDING 中，仅 '+n(client.pending)+' 笔出现客户端成功但后端未结算；其余集中在失败 / 取消、未拉起支付面板、无结果或结果字段缺失。';findCard(diag,'后端订单终态').querySelector('.card-s').textContent='payment_order 权威状态；统计截止 '+snap.cutoff;}
})();\n`;
  html=html.replace('\n</script>\n</body>\n</html>',`${updater}${updaterExtras}\n</script>\n</body>\n</html>`);
  return html;
}

const launchPath=path.join(root,'dino-launch-dashboard.html');
const workbenchPath=path.join(root,'dino-analysis-workbench.html');
const launch=updateLaunch(fs.readFileSync(launchPath,'utf8'));
const workbench=updateWorkbench(fs.readFileSync(workbenchPath,'utf8'));
fs.writeFileSync(launchPath,launch);
fs.writeFileSync(workbenchPath,workbench);
fs.writeFileSync(path.join(root,'docs/dino-english/dino-launch-dashboard.html'),launch);
fs.writeFileSync(path.join(root,'docs/dino-english/dino-analysis-workbench.html'),workbench);
process.stdout.write(JSON.stringify({cutoff,launch:{firstOpen:allData.journey.first_open,orders:allData.payment.orders,productionSuccess:allData.payment.success},workbench:{abAssigned:abTotal.a.assigned+abTotal.b.assigned,registrationDays:registrationDaily.length,paymentOrders:paymentTotal.orders}},null,2));
