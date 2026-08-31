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

const cutoff = '2026-08-31 03:01 UTC';
const cutoffShort = '08-31 03:01';
const periods = ['all', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6', 'w7'];
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
const moduleKeys = ['explore_users','explore_words_users','explore_listening_users','play_users','play_blind_box_users','play_words_pk_users','play_speaking_pk_users'];
const moduleRows = JSON.parse(fs.readFileSync(path.join(resultDir,'modules.json'),'utf8'));
const globalModules = Object.fromEntries(moduleRows.filter(row=>row.row_type==='summary').map(row=>[
  row.period_key,
  Object.fromEntries(moduleKeys.map(key=>[key,num(row[key])||0]))
]));
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

const userCountryMap = new Map(globalMetricRows.filter(row=>row.row_type==='user_map').map(row=>[String(row.user_id),row.country_key]));
const countryModuleRows = Object.fromEntries(countries.map(country=>[country,Object.fromEntries(periods.map(period=>{
  const totals=Object.fromEntries(moduleKeys.map(key=>[key,0]));
  for(const row of moduleRows){
    if(row.row_type!=='user'||row.period_key!==period||userCountryMap.get(String(row.user_id))!==country)continue;
    for(const key of moduleKeys)totals[key]+=num(row[key])||0;
  }
  return [period,totals];
}))]));
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
const levelValuesFor = (period,country) => lessonIds.map(lessonId => {
  const payload = levelMap.get(`${period}:${country}:${lessonId}`) || [];
  return stagePrefixes[lessonId].map(prefix => payload.find(item => item.template_id.startsWith(prefix))?.users || 0);
});
const levelValues = Object.fromEntries(periods.map(period => [period,levelValuesFor(period,'all')]));
const countryLevelValues = {};
for (const period of periods) {
  countryLevelValues[period] = {};
  for (const country of countries) {
    countryLevelValues[period][country] = levelValuesFor(period,country);
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
const abWeekly = {w4:makeAbCountries('w4'),w5:makeAbCountries('w5'),w6:makeAbCountries('w6'),w7:makeAbCountries('w7')};

const periodConfig = [
  {key:'all',tabEn:'All',tabZh:'全部',label:'07-10~08-31 03:01',statusEn:'Full period · Complete UTC days through Aug 30 + rolling Aug 31',statusZh:'全周期 · 完整 UTC 日截至 08-30 + 08-31 滚动数据'},
  {key:'w1',tabEn:'07-10~07-16',tabZh:'07-10~07-16',label:'07-10~07-16',statusEn:'Week 1 · Complete UTC week',statusZh:'第 1 周 · UTC 完整周'},
  {key:'w2',tabEn:'07-17~07-23',tabZh:'07-17~07-23',label:'07-17~07-23',statusEn:'Week 2 · Complete UTC week',statusZh:'第 2 周 · UTC 完整周'},
  {key:'w3',tabEn:'07-24~07-30',tabZh:'07-24~07-30',label:'07-24~07-30',statusEn:'Week 3 · Complete UTC week',statusZh:'第 3 周 · UTC 完整周'},
  {key:'w4',tabEn:'07-31~08-06',tabZh:'07-31~08-06',label:'07-31~08-06',statusEn:'Week 4 · A/B calculated from Aug 1',statusZh:'第 4 周 · A/B 从 08-01 起计算'},
  {key:'w5',tabEn:'08-07~08-13',tabZh:'08-07~08-13',label:'08-07~08-13',statusEn:'Week 5 · Complete UTC week',statusZh:'第 5 周 · UTC 完整周'},
  {key:'w6',tabEn:'08-14~08-20',tabZh:'08-14~08-20',label:'08-14~08-20',statusEn:'Week 6 · Complete UTC week',statusZh:'第 6 周 · UTC 完整周'},
  {key:'w7',tabEn:'08-21~08-31',tabZh:'08-21~08-31',label:'08-21~08-31 03:01',statusEn:'Week 7 · Rolling through Aug 31 03:01 UTC',statusZh:'第 7 周 · 截至 08-31 03:01 UTC 的滚动周期'}
];

function normalizeForCurrentCutoff(html) {
  return html
    .replaceAll('2026-08-23 04:55 UTC','2026-08-24 03:01 UTC')
    .replaceAll('2026-08-23 04:55','2026-08-24 03:01')
    .replaceAll('08-23 04:55 UTC','08-24 03:01 UTC')
    .replaceAll('08-23 04:55','08-24 03:01')
    .replaceAll('2026-08-23*','2026-08-24*')
    .replaceAll('08-23*','08-24*')
    .replaceAll('08-22 是最近完整日','08-23 是最近完整日')
    .replaceAll('08-22 为最近完整 UTC 日，08-23 为滚动日','08-23 为最近完整 UTC 日，08-24 为滚动日')
    .replaceAll('Aug 22 is the latest complete UTC day; Aug 23 is rolling','Aug 23 is the latest complete UTC day; Aug 24 is rolling')
    .replaceAll('截至 08-22；08-23* 为滚动日','截至 08-23；08-24* 为滚动日')
    .replaceAll('截至 08-22；08-24* 为滚动日','截至 08-23；08-24* 为滚动日')
    .replaceAll('最近三个完整日 08-20~22','最近三个完整日 08-21~23')
    .replaceAll('当前日表到 08-22，08-23 补 intraday','当前日表到 08-22，08-23~24 补 intraday')
    .replaceAll('08-22 及以前使用日表，08-23 补 intraday','08-22 及以前使用日表，08-23~24 补 intraday')
    .replaceAll('07-10~08-22 使用日表，08-23 使用 intraday 数据','07-10~08-22 使用日表，08-23~24 使用 intraday 数据')
    .replaceAll('07-10~08-22 日表 + 08-23 intraday','07-10~08-22 日表 + 08-23~24 intraday')
    .replace(/daily tables Jul 10–Aug 22 \+ intraday Aug 23(?:–24)*/g,'daily tables Jul 10–Aug 22 + intraday Aug 23–24')
    .replaceAll('D1 可测至 08-21、D3 至 08-19、D7 至 08-15','D1 可测至 08-22、D3 至 08-20、D7 至 08-16')
    .replaceAll('Retention is exact-day (D1 through Aug 21, D3 through Aug 19, D7 through Aug 15).','Retention is exact-day (D1 through Aug 22, D3 through Aug 20, D7 through Aug 16).')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 23 04:55 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 24 03:01 UTC cutoff.')
    .replaceAll('44 个完整 UTC 日 + 08-23 滚动','45 个完整 UTC 日 + 08-24 滚动')
    .replaceAll('马来西亚时间 12:55','马来西亚时间 11:01')
    .replaceAll('12:55 Malaysia time','11:01 Malaysia time')
    .replaceAll('马来西亚 12:55','马来西亚 11:01')
    .replaceAll('2026-08-24 03:01 UTC','2026-08-25 03:01 UTC')
    .replaceAll('2026-08-24 03:01','2026-08-25 03:01')
    .replaceAll('08-24 03:01 UTC','08-25 03:01 UTC')
    .replaceAll('08-24 03:01','08-25 03:01')
    .replaceAll('2026-08-24*','2026-08-25*')
    .replaceAll('08-24*','08-25*')
    .replaceAll('08-23 是最近完整日','08-24 是最近完整日')
    .replaceAll('08-23 为最近完整 UTC 日，08-24 为滚动日','08-24 为最近完整 UTC 日，08-25 为滚动日')
    .replaceAll('Aug 23 is the latest complete UTC day; Aug 24 is rolling','Aug 24 is the latest complete UTC day; Aug 25 is rolling')
    .replaceAll('截至 08-23；08-24* 为滚动日','截至 08-24；08-25* 为滚动日')
    .replaceAll('最近三个完整日 08-21~23','最近三个完整日 08-22~24')
    .replaceAll('当前日表到 08-22，08-23~24 补 intraday','当前日表到 08-23，08-24~25 补 intraday')
    .replaceAll('08-22 及以前使用日表，08-23~24 补 intraday','08-23 及以前使用日表，08-24~25 补 intraday')
    .replaceAll('07-10~08-22 使用日表，08-23~24 使用 intraday 数据','07-10~08-23 使用日表，08-24~25 使用 intraday 数据')
    .replaceAll('07-10~08-22 日表 + 08-23~24 intraday','07-10~08-23 日表 + 08-24~25 intraday')
    .replaceAll('daily tables Jul 10–Aug 22 + intraday Aug 23–24','daily tables Jul 10–Aug 23 + intraday Aug 24–25')
    .replaceAll('D1 可测至 08-22、D3 至 08-20、D7 至 08-16','D1 可测至 08-23、D3 至 08-21、D7 至 08-17')
    .replaceAll('Retention is exact-day (D1 through Aug 22, D3 through Aug 20, D7 through Aug 16).','Retention is exact-day (D1 through Aug 23, D3 through Aug 21, D7 through Aug 17).')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 24 03:01 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 25 03:01 UTC cutoff.')
    .replaceAll('45 个完整 UTC 日 + 08-24 滚动','46 个完整 UTC 日 + 08-25 滚动')
    .replaceAll("row_key==='2026-08-23'","row_key==='2026-08-25'")
    .replaceAll('完整日:</b>截至 08-23','完整日:</b>截至 08-24')
    .replaceAll('08-23* 截至 04:55 UTC','08-25* 截至 03:01 UTC')
    .replaceAll('08-25* 截至 04:55 UTC','08-25* 截至 03:01 UTC')
    .replaceAll('2026-08-25 03:01 UTC','2026-08-26 03:01 UTC')
    .replaceAll('2026-08-25 03:01','2026-08-26 03:01')
    .replaceAll('08-25 03:01 UTC','08-26 03:01 UTC')
    .replaceAll('08-25 03:01','08-26 03:01')
    .replaceAll('2026-08-25*','2026-08-26*')
    .replaceAll('08-25*','08-26*')
    .replaceAll('08-24 是最近完整日','08-25 是最近完整日')
    .replaceAll('08-24 为最近完整 UTC 日，08-25 为滚动日','08-25 为最近完整 UTC 日，08-26 为滚动日')
    .replaceAll('Aug 24 is the latest complete UTC day; Aug 25 is rolling','Aug 25 is the latest complete UTC day; Aug 26 is rolling')
    .replaceAll('截至 08-24；08-25* 为滚动日','截至 08-25；08-26* 为滚动日')
    .replaceAll('最近三个完整日 08-22~24','最近三个完整日 08-23~25')
    .replaceAll('当前日表到 08-23，08-24~25 补 intraday','当前日表到 08-23，08-24~26 补 intraday')
    .replaceAll('08-23 及以前使用日表，08-24~25 补 intraday','08-23 及以前使用日表，08-24~26 补 intraday')
    .replaceAll('07-10~08-23 使用日表，08-24~25 使用 intraday 数据','07-10~08-23 使用日表，08-24~26 使用 intraday 数据')
    .replaceAll('07-10~08-23 日表 + 08-24~25 intraday','07-10~08-23 日表 + 08-24~26 intraday')
    .replaceAll('daily tables Jul 10–Aug 23 + intraday Aug 24–25','daily tables Jul 10–Aug 23 + intraday Aug 24–26')
    .replaceAll('D1 可测至 08-23、D3 至 08-21、D7 至 08-17','D1 可测至 08-24、D3 至 08-22、D7 至 08-18')
    .replaceAll('Retention is exact-day (D1 through Aug 23, D3 through Aug 21, D7 through Aug 17).','Retention is exact-day (D1 through Aug 24, D3 through Aug 22, D7 through Aug 18).')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 25 03:01 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 26 03:01 UTC cutoff.')
    .replaceAll('46 个完整 UTC 日 + 08-25 滚动','47 个完整 UTC 日 + 08-26 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–24 rolling through 03:01 UTC','6 complete UTC weeks + Aug 21–26 rolling through 03:01 UTC')
    .replaceAll('UTC 日 07-10~08-24（08-26* 截止 03:01 UTC）','UTC 日 07-10~08-25（08-26* 截止 03:01 UTC）')
    .replaceAll("row_key==='2026-08-25'","row_key==='2026-08-26'")
    .replaceAll('完整日:</b>截至 08-24','完整日:</b>截至 08-25')
    .replaceAll('08-26* 截至 04:55 UTC','08-26* 截至 03:01 UTC')
    .replaceAll('2026-08-26 03:01 UTC','2026-08-27 03:02 UTC')
    .replaceAll('2026-08-26 03:01','2026-08-27 03:02')
    .replaceAll('08-26 03:01 UTC','08-27 03:02 UTC')
    .replaceAll('08-26 03:01','08-27 03:02')
    .replaceAll('2026-08-26*','2026-08-27*')
    .replaceAll('08-26*','08-27*')
    .replaceAll('08-25 是最近完整日','08-26 是最近完整日')
    .replaceAll('08-25 为最近完整 UTC 日，08-26 为滚动日','08-26 为最近完整 UTC 日，08-27 为滚动日')
    .replaceAll('Aug 25 is the latest complete UTC day; Aug 26 is rolling','Aug 26 is the latest complete UTC day; Aug 27 is rolling')
    .replaceAll('截至 08-25；08-26* 为滚动日','截至 08-26；08-27* 为滚动日')
    .replaceAll('最近三个完整日 08-23~25','最近三个完整日 08-24~26')
    .replaceAll('当前日表到 08-23，08-24~26 补 intraday','当前日表到 08-25，08-26~27 补 intraday')
    .replaceAll('08-23 及以前使用日表，08-24~26 补 intraday','08-25 及以前使用日表，08-26~27 补 intraday')
    .replaceAll('07-10~08-23 使用日表，08-24~26 使用 intraday 数据','07-10~08-25 使用日表，08-26~27 使用 intraday 数据')
    .replaceAll('07-10~08-23 日表 + 08-24~26 intraday','07-10~08-25 日表 + 08-26~27 intraday')
    .replaceAll('daily tables Jul 10–Aug 23 + intraday Aug 24–26','daily tables Jul 10–Aug 25 + intraday Aug 26–27')
    .replaceAll('D1 可测至 08-24、D3 至 08-22、D7 至 08-18','D1 可测至 08-25、D3 至 08-23、D7 至 08-19')
    .replaceAll('Retention is exact-day (D1 through Aug 24, D3 through Aug 22, D7 through Aug 18).','Retention is exact-day (D1 through Aug 25, D3 through Aug 23, D7 through Aug 19).')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 26 03:01 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 27 03:02 UTC cutoff.')
    .replaceAll('47 个完整 UTC 日 + 08-26 滚动','48 个完整 UTC 日 + 08-27 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–26 rolling through 03:01 UTC','6 complete UTC weeks + Aug 21–27 rolling through 03:02 UTC')
    .replaceAll('UTC 日 07-10~08-25（08-26* 截止 03:01 UTC）','UTC 日 07-10~08-26（08-27* 截止 03:02 UTC）')
    .replaceAll("row_key==='2026-08-26'","row_key==='2026-08-27'")
    .replaceAll('完整日:</b>截至 08-25','完整日:</b>截至 08-26')
    .replaceAll('08-27* 截至 03:01 UTC','08-27* 截至 03:02 UTC')
    .replaceAll('UTC 日 07-10~08-25（08-27* 截止 03:02 UTC）','UTC 日 07-10~08-26（08-27* 截止 03:02 UTC）')
    .replaceAll('03:01 UTC','03:02 UTC')
    .replaceAll('马来西亚时间 11:01','马来西亚时间 11:02')
    .replaceAll('11:01 Malaysia time','11:02 Malaysia time')
    .replaceAll('马来西亚 11:01','马来西亚 11:02')
    .replaceAll('2026-08-27 03:02 UTC','2026-08-28 03:01 UTC')
    .replaceAll('2026-08-27 03:02','2026-08-28 03:01')
    .replaceAll('08-27 03:02 UTC','08-28 03:01 UTC')
    .replaceAll('08-27 03:02','08-28 03:01')
    .replaceAll('2026-08-27*','2026-08-28*')
    .replaceAll('08-27*','08-28*')
    .replaceAll('08-26 是最近完整日','08-27 是最近完整日')
    .replaceAll('08-26 为最近完整 UTC 日，08-27 为滚动日','08-27 为最近完整 UTC 日，08-28 为滚动日')
    .replaceAll('Aug 26 is the latest complete UTC day; Aug 27 is rolling','Aug 27 is the latest complete UTC day; Aug 28 is rolling')
    .replaceAll('截至 08-26；08-27* 为滚动日','截至 08-27；08-28* 为滚动日')
    .replaceAll('最近三个完整日 08-24~26','最近三个完整日 08-25~27')
    .replaceAll('当前日表到 08-25，08-26~27 补 intraday','当前日表到 08-26，08-27~28 补 intraday')
    .replaceAll('08-25 及以前使用日表，08-26~27 补 intraday','08-26 及以前使用日表，08-27~28 补 intraday')
    .replaceAll('07-10~08-25 使用日表，08-26~27 使用 intraday 数据','07-10~08-26 使用日表，08-27~28 使用 intraday 数据')
    .replaceAll('07-10~08-25 日表 + 08-26~27 intraday','07-10~08-26 日表 + 08-27~28 intraday')
    .replaceAll('daily tables Jul 10–Aug 25 + intraday Aug 26–27','daily tables Jul 10–Aug 26 + intraday Aug 27–28')
    .replaceAll('D1 可测至 08-25、D3 至 08-23、D7 至 08-19','D1 可测至 08-26、D3 至 08-24、D7 至 08-20')
    .replaceAll('Retention is exact-day (D1 through Aug 25, D3 through Aug 23, D7 through Aug 19).','Retention is exact-day (D1 through Aug 26, D3 through Aug 24, D7 through Aug 20).')
    .replaceAll('D1 is measurable through Aug 22, D3 through Aug 20, and D7 through Aug 16.','D1 is measurable through Aug 26, D3 through Aug 24, and D7 through Aug 20.')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 27 03:02 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 28 03:01 UTC cutoff.')
    .replaceAll('48 个完整 UTC 日 + 08-27 滚动','49 个完整 UTC 日 + 08-28 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–27 rolling through 03:02 UTC','6 complete UTC weeks + Aug 21–28 rolling through 03:01 UTC')
    .replaceAll('UTC 日 07-10~08-26（08-27* 截止 03:02 UTC）','UTC 日 07-10~08-27（08-28* 截止 03:01 UTC）')
    .replaceAll("row_key==='2026-08-27'","row_key==='2026-08-28'")
    .replaceAll('完整日:</b>截至 08-26','完整日:</b>截至 08-27')
    .replaceAll('03:02 UTC','03:01 UTC')
    .replaceAll('马来西亚时间 11:02','马来西亚时间 11:01')
    .replaceAll('11:02 Malaysia time','11:01 Malaysia time')
    .replaceAll('马来西亚 11:02','马来西亚 11:01')
    .replaceAll('2026-08-28 03:01 UTC','2026-08-29 03:00 UTC')
    .replaceAll('2026-08-28 03:01','2026-08-29 03:00')
    .replaceAll('08-28 03:01 UTC','08-29 03:00 UTC')
    .replaceAll('08-28 03:01','08-29 03:00')
    .replaceAll('2026-08-28*','2026-08-29*')
    .replaceAll('08-28*','08-29*')
    .replaceAll('08-27 是最近完整日','08-28 是最近完整日')
    .replaceAll('08-27 为最近完整 UTC 日，08-28 为滚动日','08-28 为最近完整 UTC 日，08-29 为滚动日')
    .replaceAll('Aug 27 is the latest complete UTC day; Aug 28 is rolling','Aug 28 is the latest complete UTC day; Aug 29 is rolling')
    .replaceAll('截至 08-27；08-28* 为滚动日','截至 08-28；08-29* 为滚动日')
    .replaceAll('最近三个完整日 08-25~27','最近三个完整日 08-26~28')
    .replaceAll('当前日表到 08-26，08-27~28 补 intraday','当前日表到 08-27，08-28~29 补 intraday')
    .replaceAll('08-26 及以前使用日表，08-27~28 补 intraday','08-27 及以前使用日表，08-28~29 补 intraday')
    .replaceAll('07-10~08-26 使用日表，08-27~28 使用 intraday 数据','07-10~08-27 使用日表，08-28~29 使用 intraday 数据')
    .replaceAll('07-10~08-26 日表 + 08-27~28 intraday','07-10~08-27 日表 + 08-28~29 intraday')
    .replaceAll('daily tables Jul 10–Aug 26 + intraday Aug 27–28','daily tables Jul 10–Aug 27 + intraday Aug 28–29')
    .replaceAll('D1 可测至 08-26、D3 至 08-24、D7 至 08-20','D1 可测至 08-27、D3 至 08-25、D7 至 08-21')
    .replaceAll('Retention is exact-day (D1 through Aug 26, D3 through Aug 24, D7 through Aug 20).','Retention is exact-day (D1 through Aug 27, D3 through Aug 25, D7 through Aug 21).')
    .replaceAll('D1 is measurable through Aug 26, D3 through Aug 24, and D7 through Aug 20.','D1 is measurable through Aug 27, D3 through Aug 25, and D7 through Aug 21.')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 28 03:01 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 29 03:00 UTC cutoff.')
    .replaceAll('49 个完整 UTC 日 + 08-28 滚动','50 个完整 UTC 日 + 08-29 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–28 rolling through 03:01 UTC','6 complete UTC weeks + Aug 21–29 rolling through 03:00 UTC')
    .replaceAll('UTC 日 07-10~08-27（08-28* 截止 03:01 UTC）','UTC 日 07-10~08-28（08-29* 截止 03:00 UTC）')
    .replaceAll("row_key==='2026-08-28'","row_key==='2026-08-29'")
    .replaceAll('完整日:</b>截至 08-27','完整日:</b>截至 08-28')
    .replaceAll('03:01 UTC','03:00 UTC')
    .replaceAll('马来西亚时间 11:01','马来西亚时间 11:00')
    .replaceAll('11:01 Malaysia time','11:00 Malaysia time')
    .replaceAll('马来西亚 11:01','马来西亚 11:00')
    .replaceAll('2026-08-29 03:00 UTC','2026-08-30 05:11 UTC')
    .replaceAll('2026-08-29 03:00','2026-08-30 05:11')
    .replaceAll('08-29 03:00 UTC','08-30 05:11 UTC')
    .replaceAll('08-29 03:00','08-30 05:11')
    .replaceAll('2026-08-29*','2026-08-30*')
    .replaceAll('08-29*','08-30*')
    .replaceAll('08-28 是最近完整日','08-29 是最近完整日')
    .replaceAll('08-28 为最近完整 UTC 日，08-29 为滚动日','08-29 为最近完整 UTC 日，08-30 为滚动日')
    .replaceAll('Aug 28 is the latest complete UTC day; Aug 29 is rolling','Aug 29 is the latest complete UTC day; Aug 30 is rolling')
    .replaceAll('截至 08-28；08-29* 为滚动日','截至 08-29；08-30* 为滚动日')
    .replaceAll('最近三个完整日 08-26~28','最近三个完整日 08-27~29')
    .replaceAll('当前日表到 08-27，08-28~29 补 intraday','当前日表到 08-28，08-29~30 补 intraday')
    .replaceAll('08-27 及以前使用日表，08-28~29 补 intraday','08-28 及以前使用日表，08-29~30 补 intraday')
    .replaceAll('07-10~08-27 使用日表，08-28~29 使用 intraday 数据','07-10~08-28 使用日表，08-29~30 使用 intraday 数据')
    .replaceAll('07-10~08-27 日表 + 08-28~29 intraday','07-10~08-28 日表 + 08-29~30 intraday')
    .replaceAll('daily tables Jul 10–Aug 27 + intraday Aug 28–29','daily tables Jul 10–Aug 28 + intraday Aug 29–30')
    .replaceAll('D1 可测至 08-27、D3 至 08-25、D7 至 08-21','D1 可测至 08-28、D3 至 08-26、D7 至 08-22')
    .replaceAll('Retention is exact-day (D1 through Aug 27, D3 through Aug 25, D7 through Aug 21).','Retention is exact-day (D1 through Aug 28, D3 through Aug 26, D7 through Aug 22).')
    .replaceAll('D1 is measurable through Aug 27, D3 through Aug 25, and D7 through Aug 21.','D1 is measurable through Aug 28, D3 through Aug 26, and D7 through Aug 22.')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 29 03:00 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 30 05:11 UTC cutoff.')
    .replaceAll('50 个完整 UTC 日 + 08-29 滚动','51 个完整 UTC 日 + 08-30 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–29 rolling through 03:00 UTC','6 complete UTC weeks + Aug 21–30 rolling through 05:11 UTC')
    .replaceAll('UTC 日 07-10~08-28（08-29* 截止 03:00 UTC）','UTC 日 07-10~08-29（08-30* 截止 05:11 UTC）')
    .replaceAll("row_key==='2026-08-29'","row_key==='2026-08-30'")
    .replaceAll('完整日:</b>截至 08-28','完整日:</b>截至 08-29')
    .replaceAll('03:00 UTC','05:11 UTC')
    .replaceAll('马来西亚时间 11:00','马来西亚时间 13:11')
    .replaceAll('11:00 Malaysia time','13:11 Malaysia time')
    .replaceAll('马来西亚 11:00','马来西亚 13:11')
    .replaceAll('2026-08-30 05:11 UTC','2026-08-31 03:01 UTC')
    .replaceAll('2026-08-30 05:11','2026-08-31 03:01')
    .replaceAll('08-30 05:11 UTC','08-31 03:01 UTC')
    .replaceAll('08-30 05:11','08-31 03:01')
    .replaceAll('2026-08-30*','2026-08-31*')
    .replaceAll('08-30*','08-31*')
    .replaceAll('08-29 是最近完整日','08-30 是最近完整日')
    .replaceAll('08-29 为最近完整 UTC 日，08-30 为滚动日','08-30 为最近完整 UTC 日，08-31 为滚动日')
    .replaceAll('Aug 29 is the latest complete UTC day; Aug 30 is rolling','Aug 30 is the latest complete UTC day; Aug 31 is rolling')
    .replaceAll('截至 08-29；08-30* 为滚动日','截至 08-30；08-31* 为滚动日')
    .replaceAll('最近三个完整日 08-27~29','最近三个完整日 08-28~30')
    .replaceAll('当前日表到 08-28，08-29~30 补 intraday','当前日表到 08-29，08-30~31 补 intraday')
    .replaceAll('08-28 及以前使用日表，08-29~30 补 intraday','08-29 及以前使用日表，08-30~31 补 intraday')
    .replaceAll('07-10~08-28 使用日表，08-29~30 使用 intraday 数据','07-10~08-29 使用日表，08-30~31 使用 intraday 数据')
    .replaceAll('07-10~08-28 日表 + 08-29~30 intraday','07-10~08-29 日表 + 08-30~31 intraday')
    .replaceAll('daily tables Jul 10–Aug 28 + intraday Aug 29–30','daily tables Jul 10–Aug 29 + intraday Aug 30–31')
    .replaceAll('D1 可测至 08-28、D3 至 08-26、D7 至 08-22','D1 可测至 08-29、D3 至 08-27、D7 至 08-23')
    .replaceAll('Retention is exact-day (D1 through Aug 28, D3 through Aug 26, D7 through Aug 22).','Retention is exact-day (D1 through Aug 29, D3 through Aug 27, D7 through Aug 23).')
    .replaceAll('D1 is measurable through Aug 28, D3 through Aug 26, and D7 through Aug 22.','D1 is measurable through Aug 29, D3 through Aug 27, and D7 through Aug 23.')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 30 05:11 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 31 03:01 UTC cutoff.')
    .replaceAll('51 个完整 UTC 日 + 08-30 滚动','52 个完整 UTC 日 + 08-31 滚动')
    .replaceAll('6 complete UTC weeks + Aug 21–30 rolling through 05:11 UTC','6 complete UTC weeks + Aug 21–31 rolling through 03:01 UTC')
    .replaceAll('UTC 日 07-10~08-29（08-30* 截止 05:11 UTC）','UTC 日 07-10~08-30（08-31* 截止 03:01 UTC）')
    .replaceAll("row_key==='2026-08-30'","row_key==='2026-08-31'")
    .replaceAll('完整日:</b>截至 08-29','完整日:</b>截至 08-30')
    .replaceAll('05:11 UTC','03:01 UTC')
    .replaceAll('马来西亚时间 13:11','马来西亚时间 11:01')
    .replaceAll('13:11 Malaysia time','11:01 Malaysia time')
    .replaceAll('马来西亚 13:11','马来西亚 11:01');
}

function updateLaunch(html) {
  html = html
    .replaceAll('2026-08-22 03:15 UTC','2026-08-23 04:55 UTC')
    .replaceAll('08-22 03:15','08-23 04:55')
    .replaceAll('07-10~08-20 使用日表，08-21~22 使用 intraday 数据','07-10~08-21 使用日表，08-22~23 使用 intraday 数据')
    .replaceAll('07-10~08-20 日表 + 08-21~22 intraday','07-10~08-21 日表 + 08-22~23 intraday')
    .replaceAll('08-21 为最近完整 UTC 日，08-22 为滚动日','08-22 为最近完整 UTC 日，08-23 为滚动日')
    .replaceAll('Aug 21 is the latest complete UTC day; Aug 22 is rolling','Aug 22 is the latest complete UTC day; Aug 23 is rolling')
    .replaceAll('D1 可测至 08-20、D3 至 08-18、D7 至 08-14','D1 可测至 08-21、D3 至 08-19、D7 至 08-15')
    .replaceAll('Aug 20, D3 through Aug 18, and D7 through Aug 14','Aug 21, D3 through Aug 19, and D7 through Aug 15')
    .replaceAll('daily tables Jul 10–Aug 13 + intraday Aug 14','daily tables Jul 10–Aug 21 + intraday Aug 22–23')
    .replaceAll('The latest payment-source record in this refresh is within the Aug 22 03:15 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 23 04:55 UTC cutoff.')
    .replaceAll('Retention is exact-day (D1 through Aug 12, D3 through Aug 10, D7 through Aug 6).','Retention is exact-day (D1 through Aug 21, D3 through Aug 19, D7 through Aug 15).')
    .replaceAll('43 个完整 UTC 日 + 08-22 滚动','44 个完整 UTC 日 + 08-23 滚动')
    .replaceAll('马来西亚 11:15','马来西亚 12:55')
    .replaceAll('11:15 Malaysia time','12:55 Malaysia time');
  html = html
    .replaceAll('07-10~08-21 使用日表，08-22~23 使用 intraday 数据','07-10~08-22 使用日表，08-23 使用 intraday 数据')
    .replaceAll('07-10~08-21 日表 + 08-22~23 intraday','07-10~08-22 日表 + 08-23 intraday')
    .replaceAll('daily tables Jul 10–Aug 21 + intraday Aug 22–23','daily tables Jul 10–Aug 22 + intraday Aug 23');
  html = replaceFrom(html,'const PERIODS=','const WEEKLY=',`const PERIODS=${compact(periodConfig)};`);
  html = replaceFrom(html,'const WEEKLY=','const ALL=',`const WEEKLY=${compact(weeklyData)};`);
  html = replaceLine(html,'const ALL=',`const ALL=${compact(allData)};`);
  html = replaceFrom(html,'const DIAGNOSTIC_COUNTRY_DATA=','const COUNTRY_BUSINESS_DATA=',`const DIAGNOSTIC_COUNTRY_DATA=${compact(diagnosticData)};`);
  html = replaceLine(html,'const COUNTRY_BUSINESS_DATA=',`const COUNTRY_BUSINESS_DATA=${compact(countryBusinessData)};`);
  html = replaceFrom(html,'const LEVEL_VALUES=','const buildLevels=',`const LEVEL_VALUES=${compact(levelValues)};`);
  html = replaceLine(html,'const COUNTRY_LEVEL_VALUES=',`const COUNTRY_LEVEL_VALUES=${compact(countryLevelValues)};`);
  html = replaceLine(html,'const COUNTRY_RETENTION_ROWS=',`const COUNTRY_RETENTION_ROWS=${compact(countryRetentionRows)};`);
  html = replaceFrom(html,'const AB_ALL_COUNTRIES=','const AB_WEEKLY=',`const AB_ALL_COUNTRIES=${compact(abAllCountries)};`);
  html = replaceFrom(html,'const AB_WEEKLY=','let AB_MAIN_COUNTRIES=',`const AB_WEEKLY=${compact(abWeekly)};`);
  html = replaceLine(html,'const retAll=',`const retAll=${compact(allRetention)};`);
  html = replaceLine(html,'const RET_RANGES=',`const RET_RANGES={w1:['07-10','07-16'],w2:['07-17','07-23'],w3:['07-24','07-30'],w4:['07-31','08-06'],w5:['08-07','08-13'],w6:['08-14','08-20'],w7:['08-21','08-28']};`);
  html = replaceLine(html,'const TREND_LABELS=',`const TREND_LABELS=['07/10-07/16','07/17-07/23','07/24-07/30','07/31-08/06','08/07-08/13','08/14-08/20','08/21-08/30*'];`);
  html = html
    .replaceAll('07-10~08-14 15:08','07-10~08-23 04:55')
    .replaceAll('2026-07-10 00:00 → 08-14 15:08(UTC)','2026-07-10 00:00 → 08-23 04:55（UTC）')
    .replaceAll('07-10~08-13 使用日表，08-14 使用 intraday 滚动数据','07-10~08-20 使用日表，08-21~22 使用 intraday 数据')
    .replaceAll('07-10~08-13 日表 + 08-14 intraday','07-10~08-20 日表 + 08-21~22 intraday')
    .replaceAll('2026-08-14 15:08 UTC','2026-08-23 04:55 UTC')
    .replaceAll('Aug 13 is the latest complete UTC day; Aug 14 is rolling','Aug 16 is the latest complete UTC day; Aug 17 is rolling')
    .replaceAll('08-13 为最近完整 UTC 日，08-14 为滚动日','08-21 为最近完整 UTC 日，08-22 为滚动日')
    .replaceAll('08-14 15:00:52 UTC','08-23 04:55 UTC 截点内')
    .replaceAll('Aug 14 15:00:52 UTC','the Aug 17 03:15 UTC cutoff')
    .replaceAll('D1 可测至 08-12、D3 至 08-10、D7 至 08-06','D1 可测至 08-20、D3 至 08-18、D7 至 08-14')
    .replaceAll('2026-08-14 15:08 UTC（北京时间 23:08）','2026-08-23 04:55 UTC（马来西亚 10:15）')
    .replaceAll('2026-08-14 15:08 UTC (23:08 Beijing time)','2026-08-23 04:55 UTC (10:15 Malaysia time)')
    .replaceAll('（北京时间 23:08）','（马来西亚 10:15）')
    .replaceAll('(23:08 Beijing time)','(10:15 Malaysia time)')
    .replaceAll('08-01~08-14 15:08 UTC','08-01~08-23 04:55 UTC')
    .replaceAll('35 个完整日 + 当日滚动','43 个完整 UTC 日 + 08-22 滚动')
    .replaceAll('07-10~08-21 03:02','07-10~08-23 04:55')
    .replaceAll('08-21 03:02 UTC','08-23 04:55 UTC')
    .replaceAll('2026-08-21 03:02 UTC','2026-08-23 04:55 UTC')
    .replaceAll('08-21 03:02','08-23 04:55')
    .replaceAll('07-10~08-19 使用日表，08-20~21 使用 intraday 数据','07-10~08-20 使用日表，08-21~22 使用 intraday 数据')
    .replaceAll('07-10~08-19 日表 + 08-20~21 intraday','07-10~08-20 日表 + 08-21~22 intraday')
    .replaceAll('08-20 为最近完整 UTC 日，08-21 为滚动日','08-21 为最近完整 UTC 日，08-22 为滚动日')
    .replaceAll('Aug 20 is the latest complete UTC day; Aug 21 is rolling','Aug 21 is the latest complete UTC day; Aug 22 is rolling')
    .replaceAll('D1 可测至 08-19、D3 至 08-22、D7 至 08-13','D1 可测至 08-20、D3 至 08-18、D7 至 08-14')
    .replaceAll('42 个完整 UTC 日 + 08-21 滚动','43 个完整 UTC 日 + 08-22 滚动')
    .replace('期内启动 <b>34,880</b>',`期内启动 <b>${allData.journey.first_open.toLocaleString('en-US')}</b>`)
    .replaceAll("{l:'发起支付订单',s:'payment_order 创建 · GA4 checkout_start 埋点',v:3765",`{l:'发起支付订单',s:'payment_order 创建 · GA4 checkout_start 埋点',v:${allData.payment.orders}`)
    .replaceAll("note:'3,717 PENDING + 43 生产成功 + 4 沙盒 + 1 失败 · 1,920 用户'",`note:'${allData.payment.pending.toLocaleString('en-US')} PENDING + ${allData.payment.success} 生产成功 + ${allData.payment.sandbox} 沙盒 + ${allData.payment.failed} 失败 · ${allData.payment.users.toLocaleString('en-US')} 用户'`)
    .replaceAll("{l:'成功付费订单',s:'payment_order status=SUCCESS · 生产',v:43",`{l:'成功付费订单',s:'payment_order status=SUCCESS · 生产',v:${allData.payment.success}`)
    .replaceAll("note:'生产环境 · 权威口径(Apple 22 / Google 21)'",`note:'生产环境 · 权威口径(Apple ${allData.payment.apple} / Google ${allData.payment.google})'`)
    .replaceAll("{l:'订阅周期分布',s:'43 笔生产成功订单按 billing_period 分布',v:43",`{l:'订阅周期分布',s:'${allData.payment.success} 笔生产成功订单按 billing_period 分布',v:${allData.payment.success}`)
    .replaceAll("note:'周卡 23 / 月卡 19 / 年卡 1'",`note:'周卡 ${allData.payment.week} / 月卡 ${allData.payment.month} / 年卡 ${allData.payment.year}'`);
  html=html
    .replace(/期内启动 <b>[\d,]+<\/b>/,`期内启动 <b>${allData.journey.first_open.toLocaleString('en-US')}</b>`)
    .replaceAll('19,136 / 38,865',`${allData.journey.signup_success.toLocaleString('en-US')} / ${allData.journey.first_open.toLocaleString('en-US')}`)
    .replaceAll('14,323 / 38,865',`${allData.journey.lesson_start.toLocaleString('en-US')} / ${allData.journey.first_open.toLocaleString('en-US')}`)
    .replaceAll('3,257 / 14,323',`${allData.journey.lesson_complete.toLocaleString('en-US')} / ${allData.journey.lesson_start.toLocaleString('en-US')}`)
    .replaceAll('成熟 cohort 38,228 → 4,835',`成熟 cohort ${allData.retention.devices.toLocaleString('en-US')} → ${allData.retention.d1.toLocaleString('en-US')}`)
    .replace('<div class="val">49.2<small>%</small></div>',`<div class="val">${pct(allData.journey.signup_success,allData.journey.first_open)}<small>%</small></div>`)
    .replace('<div class="val">36.8<small>%</small></div>',`<div class="val">${pct(allData.journey.lesson_start,allData.journey.first_open)}<small>%</small></div>`)
    .replace('<div class="val">22.7<small>%</small></div>',`<div class="val">${pct(allData.journey.lesson_complete,allData.journey.lesson_start)}<small>%</small></div>`)
    .replace('<div class="val">12.6<small>%</small></div>',`<div class="val">${pct(allData.retention.d1,allData.retention.devices)}<small>%</small></div>`)
    .replace(/<div class="it">✓ 全部 · 07-10~08-23 04:55：[^<]+<\/div>/,`<div class="it">✓ 全部 · 07-10~08-23 04:55：${surfaceTotals.any.users.toLocaleString('en-US')} 台支付页触达设备 → ${allData.payment.users.toLocaleString('en-US')} 个创建订单账号 → ${allData.payment.success} 笔生产成功订单</div>`)
    .replaceAll('账号漏斗：支付页触达 → 创建订单 → 成功付费','设备触达 → 订单账号 → 生产成功订单')
    .replaceAll('D1 可测至 08-19、D3 至 08-17、D7 至 08-13','D1 可测至 08-20、D3 至 08-18、D7 至 08-14')
    .replaceAll('D1 is measurable through Aug 12, D3 through Aug 10, and D7 through Aug 6.','D1 is measurable through Aug 20, D3 through Aug 18, and D7 through Aug 14.')
    .replaceAll('The latest payment-source record in this refresh is the Aug 21 03:02 UTC cutoff.','The latest payment-source record in this refresh is within the Aug 22 03:15 UTC cutoff.');
  return normalizeForCurrentCutoff(html);
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
  const match=row.row_key.match(/^all-(\d{2}-\d{2})-([ab])$/);return {d:`${match[1]}${match[1]==='08-31'?'*':''}`,g:match[2].toUpperCase(),assigned:num(row.v1),mature:num(row.v2),registered:num(row.v3),registeredRolling:num(row.v4),lessonComplete:num(row.v6),paid:null,pending:null};
});

const signupRows = readRows('signup-method');
const loginFunnelRows = readRows('login-signup-funnel');
const loginFailureRows = readRows('login-failure-reasons');
const milestoneTimeRows = readRows('milestone-time');
const authCountryMethodWindow={start:'2026-08-01',cutoff:'2026-08-31 03:01 UTC'};
const authCountryMethodOutcomes=loginFunnelRows.map(row=>({
  week:row.week_key,country:row.country_code,method:row.method_key,
  clicks:num(row.click_events),clickDevices:num(row.click_devices),clickShare:num(row.click_share_pct),
  loginSuccess:num(row.login_success_events),loginSuccessShare:num(row.login_success_share_pct),signupSuccess:num(row.signup_success_events),
  outcomes:num(row.outcome_events),outcomeDevices:num(row.outcome_devices),success:num(row.success_outcomes),failure:num(row.failure_outcomes),deferred:num(row.deferred_outcomes),
  successRate:num(row.success_rate_pct),coverage:num(row.outcome_coverage_pct)
}));
const authCountryMethodFailures=loginFailureRows.map(row=>({
  week:row.week_key,country:row.country_code,method:row.method_key,type:row.failure_type,reason:row.reason_label,
  events:num(row.failure_events),devices:num(row.failure_devices),share:num(row.share_within_selection_pct)
}));
const registrationDaily = [...new Set(signupRows.map(row=>row.cohort_date))].sort().map(day=>{
  const rows=signupRows.filter(row=>row.cohort_date===day),sum=key=>rows.reduce((total,row)=>total+num(row[key]),0);
  return {d:`${day.slice(5)}${day==='2026-08-31'?'*':''}`,n:sum('first_opens'),s:sum('registered'),an:sum('android_first_opens'),as:sum('android_registered'),iosN:sum('ios_first_opens'),iosS:sum('ios_registered')};
});
const milestoneTime = Object.fromEntries(['all','android','ios'].map(platform=>[platform,
  Object.fromEntries(['auth_complete','lesson_start','lesson_complete','payment'].map(milestone=>{
    const summary=milestoneTimeRows.find(row=>row.row_type==='summary'&&row.platform_scope===platform&&row.milestone_key===milestone);
    if(!summary)throw new Error(`Missing milestone-time summary ${platform}:${milestone}`);
    const buckets=milestoneTimeRows.filter(row=>row.row_type==='bucket'&&row.platform_scope===platform&&row.milestone_key===milestone)
      .sort((a,b)=>num(a.bucket_order)-num(b.bucket_order))
      .map(row=>({key:row.bucket_key,label:row.bucket_label,count:num(row.entities),share:num(row.share_pct)}));
    return [milestone,{sample:num(summary.entities),population:num(summary.population_entities),source:num(summary.source_entities),p50:num(summary.p50_seconds),p75:num(summary.p75_seconds),p90:num(summary.p90_seconds),buckets}];
  }))
]));
const retentionCurve = retentionRows.filter(row=>row.row_type==='curve');
const retentionSegments = retentionRows.filter(row=>row.row_type==='segment');
const ret = allRetention;
const segLabels={completed_trial:'当日完成首课',registered_no_trial:'当日注册·未完课',not_registered:'当日未注册'};
const workbenchSeg = ['completed_trial','registered_no_trial','not_registered'].map(key=>{const row=retentionSegments.find(item=>item.row_key===key);return [segLabels[key],num(row.devices),num(row.v1)];});
const curveLabels={d1:'D1 次日(07-10~08-28 cohort)',d3:'D3 第 3 天(07-10~08-26 cohort)',d7:'D7 第 7 天(07-10~08-22 cohort)'};
const workbenchCurve=['d1','d3','d7'].map(key=>{const row=retentionCurve.find(item=>item.row_key===key);return [curveLabels[key],num(row.devices),num(row.v1)];});

const paymentRows = readRows('workbench-payment');
const sourceName=name=>name==='__missing__'?'来源缺失':name;
const paymentOutcomeKeys=['client_fail_or_cancel','unmatched_checkout_start','checkout_start_no_result','result_missing_is_success','client_success'];
const buildPaymentWeek=week=>{
  const section=name=>paymentRows.filter(row=>row.week_key===week&&row.section===name);
  const totalRow=section('order_total')[0]||{},pendingRow=section('pending_health')[0]||{},retryRow=section('payment_retry_health')[0]||{},clientRow=section('client_funnel')[0]||{};
  const orderSources=section('order_source').map(row=>[sourceName(row.row_key),num(row.v1)||0,num(row.v2)||0,num(row.v3)||0,num(row.v4)||0,num(row.v5)||0,num(row.v6)||0]);
  const orderSourceMap=new Map(orderSources.map(row=>[row[0],row]));
  const discountSources=section('surface_source').filter(row=>row.row_key.startsWith('discount|')).map(row=>{
    const name=row.row_key.split('|')[1],order=orderSourceMap.get(name)||[name,0,0,0,0,0,0];
    return [name,num(row.v1)||0,num(row.v2)||0,order[1],order[4]];
  });
  const outcomeMap=new Map(section('order_outcome').map(row=>[row.row_key,row]));
  const totals=Object.fromEntries(section('surface_total').map(row=>[row.row_key,{events:num(row.v1)||0,users:num(row.v2)||0}]));
  return {
    total:{orders:num(totalRow.v1)||0,users:num(totalRow.v2)||0,pending:num(totalRow.v3)||0,production:num(totalRow.v4)||0,sandbox:num(totalRow.v5)||0,failed:num(totalRow.v6)||0},
    surfaceTotals:{any:totals.any||{events:0,users:0},paywall:totals.paywall||{events:0,users:0},discount:totals.discount||{events:0,users:0}},
    clientFunnel:[num(clientRow.v1)||0,num(clientRow.v2)||0,num(clientRow.v3)||0,num(clientRow.v4)||0],
    paywallSources:section('surface_source').filter(row=>row.row_key.startsWith('paywall|')).map(row=>[row.row_key.split('|')[1],num(row.v1)||0,num(row.v2)||0]),
    checkoutSources:section('checkout_source').map(row=>[sourceName(row.row_key),num(row.v1)||0,num(row.v2)||0,num(row.v3)||0]),
    discountSources,
    orderSources,
    orderPlatforms:section('order_platform').map(row=>[row.row_key,num(row.v1)||0,num(row.v2)||0,num(row.v3)||0,num(row.v4)||0,num(row.v5)||0,num(row.v6)||0]),
    orderPeriods:section('order_period').map(row=>[row.row_key,num(row.v1)||0,num(row.v2)||0,num(row.v3)||0,num(row.v4)||0,num(row.v5)||0,num(row.v6)||0]),
    orderOutcomes:paymentOutcomeKeys.map(key=>{const row=outcomeMap.get(key)||{};return {key,total:num(row.v1)||0,pending:num(row.v2)||0,production:num(row.v3)||0,sandbox:num(row.v4)||0,failed:num(row.v5)||0,canceled:num(row.v6)||0}}),
    pendingHealth:{pending:num(pendingRow.v1)||0,neverUpdated:num(pendingRow.v2)||0,over7d:num(pendingRow.v3)||0,blankPlatform:num(pendingRow.v4)||0},
    retryHealth:{pairs:num(retryRow.v1)||0,retriedPairs:num(retryRow.v2)||0,pendingBefore:num(retryRow.v3)||0},
    actionStats:Object.fromEntries(section('action_stats').map(row=>[row.row_key,{events:num(row.v1)||0,users:num(row.v2)||0}])),
    checkoutTotal:section('checkout_source').reduce((sum,row)=>sum+(num(row.v1)||0),0)
  };
};
const paymentWeekKeys=[...new Set(paymentRows.map(row=>row.week_key).filter(Boolean))];
const paymentByWeek=Object.fromEntries(paymentWeekKeys.map(week=>[week,buildPaymentWeek(week)]));
const paymentAll=paymentByWeek.all;
if(!paymentAll)throw new Error('Missing all-window payment data');
const {total:paymentTotal,surfaceTotals,clientFunnel,paywallSources,checkoutSources,discountSources,orderSources,orderPlatforms,orderPeriods,orderOutcomes,pendingHealth,actionStats}=paymentAll;

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

const skinMysql=JSON.parse(fs.readFileSync(path.join(resultDir,'skin-mysql.json'),'utf8'));
const skin={
  snapshotUtc:skinMysql[0][0].snapshot_utc,
  summary:skinMysql[0][0],
  sources:skinMysql[1],
  prices:skinMysql[2],
  buyerUnits:skinMysql[3],
  purchaseTop:skinMysql[4],
  wearingTop:skinMysql[5],
  ga4:readRows('skin-ga4')
};
const refreshedSnapshot={cutoff,completeDay:'2026-08-30',newcomer,skin,payment:paymentAll,paymentByWeek};

const authCountryMethodRuntime='/* ═══════════ 国家 × 注册方式 ═══════════ */\n('+(
function(){
  const countries=['All','VN','ID','MY','SA','TH','KR','Other'];
  const methods=[
    {key:'google',label:'Google'},
    {key:'phone',label:'Phone'},
    {key:'apple',label:'Apple'},
    {key:'facebook',label:'Facebook'},
    {key:'kakao',label:'Kakao'}
  ];
  const methodFilters=[{key:'All',label:'全部'},...methods];
  let currentCountry='All';
  let currentMethod='All';
  const fmt=value=>Number(value||0).toLocaleString();
  const countryLabel=country=>country==='All'?'全部国家':CN[country];
  const methodLabel=method=>methodFilters.find(item=>item.key===method)?.label||method;
  const currentWeek=()=>globalThis.DASHBOARD_WEEK_KEY||'all';
  const outcome=(country,method)=>AUTH_COUNTRY_METHOD_OUTCOMES.find(row=>row.week===currentWeek()&&row.country===country&&row.method===method)||{
    clicks:0,clickDevices:0,clickShare:0,loginSuccess:0,loginSuccessShare:0,signupSuccess:0,
    outcomes:0,outcomeDevices:0,success:0,failure:0,deferred:0,successRate:0,coverage:0
  };
  const outcomeRows=country=>methods.map(method=>({...method,...outcome(country,method.key)}));
  const rateClass=rate=>rate>=65?'up':rate<50?'down':'flat';
  const coverageClass=coverage=>coverage<80?'down':coverage>105?'warnrow':'';

  el('authCountryPills').innerHTML=countries.map((country,index)=>
    `<div class="pill${index===0?' on':''}" data-country="${country}">${country==='All'?'全部':CN[country]}</div>`
  ).join('');
  el('authMethodTabs').innerHTML=methodFilters.map((method,index)=>
    `<button class="segment-tab${index===0?' on':''}" data-method="${method.key}">${method.label}</button>`
  ).join('');

  function renderKpis(){
    const row=outcome(currentCountry,'All');
    el('authOutcomeKpis').innerHTML=`
      <div class="kpi"><div class="kl">方式选择事件</div><div class="kv">${fmt(row.clicks)}</div><div class="kn">${fmt(row.clickDevices)} 台设备 · 各方式占比的分母</div></div>
      <div class="kpi"><div class="kl">服务端登录成功</div><div class="kv">${fmt(row.loginSuccess)}</div><div class="kn">login_result 仅上报成功，用于成功量核对</div></div>
      <div class="kpi"><div class="kl">诊断成功</div><div class="kv">${fmt(row.success)}</div><div class="kn">auth_login_result 终态事件</div></div>
      <div class="kpi warn"><div class="kl">诊断失败</div><div class="kv">${fmt(row.failure)}</div><div class="kn">用户中止 + 业务拒绝 + 技术失败</div></div>
      <div class="kpi hot"><div class="kl">诊断成功率</div><div class="kv">${fp(row.successRate)}</div><div class="kn">成功 ÷（成功 + 失败）；不含 deferred</div></div>
      <div class="kpi${row.coverage<80?' warn':''}"><div class="kl">诊断结果覆盖信号</div><div class="kv">${fp(row.coverage)}</div><div class="kn">终态事件 ÷ 方式点击；用于识别埋点缺口</div></div>`;
  }

  function renderOutcomeTable(){
    const rows=outcomeRows(currentCountry);
    el('authOutcomeTitle').textContent=`${countryLabel(currentCountry)} · 各登录方式成功与失败`;
    const periodLabel=globalThis.dashboardWeekLabel?.()||`${AUTH_COUNTRY_METHOD_WINDOW.start} 至 ${AUTH_COUNTRY_METHOD_WINDOW.cutoff}`;
    el('authOutcomeSubtitle').textContent=`${periodLabel}；事件量口径，点击方式可联动下方失败原因`;
    el('authOutcomeTable').innerHTML='<tr><th>登录方式</th><th>方式选择</th><th>方式占比</th><th>诊断成功</th><th>诊断失败</th><th>成功率</th><th>覆盖信号</th><th>服务端成功</th></tr>'+rows.map(row=>{
      const noOutcome=row.success+row.failure===0;
      return `<tr>
        <td><button class="deep-link auth-method-link" data-method="${row.key}">${row.label}</button></td>
        <td><b>${fmt(row.clicks)}</b><span class="n">${fmt(row.clickDevices)} 台设备</span></td>
        <td><b>${fp(row.clickShare)}</b></td>
        <td class="up"><b>${fmt(row.success)}</b></td>
        <td class="down"><b>${fmt(row.failure)}</b></td>
        <td class="${noOutcome?'flat':rateClass(row.successRate)}"><b>${noOutcome?'—':fp(row.successRate)}</b><span class="n">${fmt(row.success+row.failure)} 个有效终态</span></td>
        <td class="${coverageClass(row.coverage)}"><b>${row.clicks?fp(row.coverage):'—'}</b><span class="n">${fmt(row.outcomes)} 个终态</span></td>
        <td><b>${fmt(row.loginSuccess)}</b><span class="n">注册成功 ${fmt(row.signupSuccess)}</span></td>
      </tr>`;
    }).join('');
    el('authOutcomeLegend').innerHTML='<span><b>方式占比</b> 当前国家内该方式点击 ÷ 全部方式点击</span><span><b>诊断成功率</b> 成功 ÷（成功 + 失败）</span><span><b>服务端成功</b> 仅作量级校验，不作为成功率分子</span><span><b>覆盖信号</b> 可能因重试或静默回调超过 100%</span>';
    el('authOutcomeTable').querySelectorAll('.auth-method-link').forEach(button=>button.addEventListener('click',()=>{
      currentMethod=button.dataset.method;
      renderMethodTabs();
      renderFailureReasons();
      renderNote();
      el('authFailureTitle').scrollIntoView({behavior:'smooth',block:'center'});
    }));
  }

  function renderMethodTabs(){
    el('authMethodTabs').querySelectorAll('.segment-tab').forEach(tab=>tab.classList.toggle('on',tab.dataset.method===currentMethod));
  }

  function renderFailureReasons(){
    const rows=AUTH_COUNTRY_METHOD_FAILURES
      .filter(row=>row.week===currentWeek()&&row.country===currentCountry&&row.method===currentMethod)
      .sort((a,b)=>b.events-a.events);
    const methodName=currentMethod==='All'?'全部方式':methodLabel(currentMethod);
    const total=rows.reduce((sum,row)=>sum+row.events,0);
    const totalDevices=rows.reduce((sum,row)=>sum+row.devices,0);
    el('authFailureTitle').textContent=`${countryLabel(currentCountry)} · ${methodName} · 失败原因`;
    el('authFailureSubtitle').textContent='仅统计诊断终态中的 user_abort / rejected / tech_fail；同一设备可多次失败，设备列不可跨原因相加去重';
    if(!rows.length){
      el('authFailureTable').innerHTML='<tr><th>失败类型</th><th>失败原因</th><th>失败事件</th><th>设备</th><th>原因占比</th></tr><tr><td colspan="5" style="text-align:left;white-space:normal">当前国家与登录方式没有可归类的失败终态；不等同于真实失败为 0，请同时查看上方诊断覆盖信号。</td></tr>';
      el('authFailureLegend').innerHTML='<span><b>当前筛选</b> 无可归类失败原因</span><span>覆盖不足时不推断失败为 0</span>';
      return;
    }
    el('authFailureTable').innerHTML='<tr><th>失败类型</th><th>失败原因</th><th>失败事件</th><th>设备</th><th>原因占比</th></tr>'+rows.map(row=>
      `<tr><td>${row.type}</td><td style="text-align:left"><b>${row.reason}</b></td><td class="down"><b>${fmt(row.events)}</b></td><td>${fmt(row.devices)}</td><td><b>${fp(row.share)}</b></td></tr>`
    ).join('');
    const byType=[...rows.reduce((groups,row)=>groups.set(row.type,(groups.get(row.type)||0)+row.events),new Map()).entries()].sort((a,b)=>b[1]-a[1]);
    el('authFailureLegend').innerHTML=`<span><b>失败事件</b> ${fmt(total)} 次</span><span><b>原因行设备数相加</b> ${fmt(totalDevices)}，存在跨原因重复</span>`+byType.map(([type,count])=>`<span><b>${type}</b> ${fmt(count)} · ${fp(pct(count,total))}</span>`).join('');
  }

  function renderNote(){
    const eligible=outcomeRows(currentCountry).filter(row=>row.success+row.failure>=50).sort((a,b)=>a.successRate-b.successRate);
    const weakest=eligible[0];
    const reasons=AUTH_COUNTRY_METHOD_FAILURES.filter(row=>row.week===currentWeek()&&row.country===currentCountry&&row.method===currentMethod).sort((a,b)=>b.events-a.events);
    const lowCoverage=outcomeRows(currentCountry).filter(row=>row.clicks>=50&&row.coverage<80).map(row=>row.label);
    const parts=[];
    if(weakest)parts.push(`可比较样本中成功率最低的是 <b>${weakest.label} ${fp(weakest.successRate)}</b>（成功 ${fmt(weakest.success)} / 失败 ${fmt(weakest.failure)}）`);
    if(reasons[0])parts.push(`${currentMethod==='All'?'全部方式':methodLabel(currentMethod)}首要失败原因是 <b>${reasons[0].reason}</b>，占 ${fp(reasons[0].share)}`);
    if(lowCoverage.length)parts.push(`<b>${lowCoverage.join('、')}</b> 的诊断覆盖低于 80%，成败率需结合埋点缺口谨慎解读`);
    el('authOutcomeNote').innerHTML=`<b>当前信号：</b>${parts.join('；')||'当前筛选暂无足够的可比较终态样本。'}。`;
  }

  function renderAll(){
    renderKpis();
    renderOutcomeTable();
    renderMethodTabs();
    renderFailureReasons();
    renderNote();
  }

  el('authCountryPills').querySelectorAll('.pill').forEach(pill=>pill.addEventListener('click',()=>{
    currentCountry=pill.dataset.country;
    el('authCountryPills').querySelectorAll('.pill').forEach(item=>item.classList.toggle('on',item===pill));
    renderAll();
  }));
  el('authMethodTabs').querySelectorAll('.segment-tab').forEach(tab=>tab.addEventListener('click',()=>{
    currentMethod=tab.dataset.method;
    renderMethodTabs();
    renderFailureReasons();
    renderNote();
  }));
  window.addEventListener('dashboard-week-change',renderAll);
  renderAll();
}
).toString()+')();\n\n';

const paymentWeekRuntime='/* ═══════════ 支付模块自然周联动 ═══════════ */\n('+(
function(){
  const snapshot=REFRESHED_SNAPSHOT;
  const fmt=value=>Number(value||0).toLocaleString('en-US');
  const rate=(value,total,digits=1)=>total?(Number(value)/Number(total)*100).toFixed(digits):'0.0';
  const section=tab=>document.querySelector(`.sec[data-group="payment"][data-tab="${tab}"]`);
  const card=(sec,title)=>[...(sec?.querySelectorAll('.card')||[])].find(item=>item.querySelector('.card-t')?.textContent.includes(title));
  const setKpi=(sec,index,value,note)=>{const kpi=sec?.querySelectorAll('.kpi')[index];if(!kpi)return;kpi.querySelector('.kv').textContent=value;kpi.querySelector('.kn').textContent=note};
  const emptyRow=(columns,message='所选自然周暂无数据。')=>`<tr><td colspan="${columns}" style="text-align:left;white-space:normal">${message}</td></tr>`;
  const current=()=>snapshot.paymentByWeek?.[globalThis.DASHBOARD_WEEK_KEY||'all']||snapshot.paymentByWeek?.all;
  const period=()=>globalThis.dashboardWeekLabel?.()||'全部数据周期';
  const platform=(p,key)=>p.orderPlatforms.find(row=>row[0]===key)||[key,0,0,0,0,0,0];
  const source=(p,key)=>p.orderSources.find(row=>row[0]===key)||[key,0,0,0,0,0,0];

  function settlementTable(target,rows,label){
    target.innerHTML=`<tr><th>${label}</th><th>订单</th><th>账号</th><th>PENDING</th><th>生产成功</th><th>沙盒</th><th>失败</th><th>生产成功率</th></tr>`+
      (rows.length?rows.map(row=>`<tr><td>${row[0]}</td><td>${fmt(row[1])}</td><td>${fmt(row[2])}</td><td>${fmt(row[3])}</td><td${row[4]?' class="up"':''}>${fmt(row[4])}</td><td>${fmt(row[5])}</td><td>${fmt(row[6])}</td><td><b>${rate(row[4],row[1],2)}%</b></td></tr>`).join(''):emptyRow(8));
  }

  function renderOverview(p){
    const sec=section('转化总览'),t=p.total,sf=p.surfaceTotals,cf=p.clientFunnel,missing=source(p,'来源缺失'),apple=platform(p,'APPLE'),google=platform(p,'GOOGLE');
    if(!sec)return;
    sec.querySelector('.sec-desc').innerHTML=`当前筛选 <b>${period()}</b>。GA4 页面触达与 checkout 按事件发生时间归周，订单按 <b>created_at</b> 归周；订单终态观察截至 ${snapshot.cutoff}。最终成功只认 <b>status=SUCCESS 且 env_type=PRODUCTION</b>。`;
    setKpi(sec,0,fmt(sf.paywall.users),`${fmt(sf.paywall.events)} 次曝光 · GA4 设备去重`);
    setKpi(sec,1,fmt(sf.discount.users),`${fmt(sf.discount.events)} 次曝光 · 折扣订阅页`);
    setKpi(sec,2,fmt(sf.any.users),'Paywall 与折扣页跨页面去重');
    setKpi(sec,3,`${rate(cf[1],cf[0])}%`,`${fmt(cf[0])} 台曝光设备中 ${fmt(cf[1])} 台在同周随后发起支付`);
    setKpi(sec,4,`${rate(t.production,t.orders,2)}%`,`${fmt(t.production)} / ${fmt(t.orders)} 笔；PENDING ${fmt(t.pending)} 笔`);
    setKpi(sec,5,`${rate(missing[1],t.orders)}%`,`${fmt(missing[1])} / ${fmt(t.orders)} 笔 subscription_source 为空`);
    const flow=sec.querySelectorAll('.push-flow .flow-step'),flowValues=[[cf[0],'Paywall / 折扣页跨页面去重'],[cf[1],`${rate(cf[1],cf[0])}% · 同周可归因 checkout`],[cf[2],`${rate(cf[2],cf[1])}% · 含取消 / 失败 / 成功`],[cf[3],`${rate(cf[3],cf[2])}% · 仅诊断，不作财务口径`]];
    flow.forEach((node,index)=>{node.querySelector('.flow-num').textContent=fmt(flowValues[index][0]);node.querySelector('.flow-rate').textContent=flowValues[index][1]});
    const funnel=card(sec,'客户端可串联漏斗');
    funnel.querySelector('.card-s').textContent=`${period()} · 同设备且后一步晚于前一步，跨周事件不并入所选周`;
    const checkout=p.actionStats.subscription_checkout_start||{events:0,users:0};
    funnel.querySelector('.legend').textContent=`全部 checkout：${fmt(checkout.events)} 次 / ${fmt(p.checkoutTotal)} 个 order_id / ${fmt(checkout.users)} 台设备；其中 ${fmt(cf[1])} 台能在同周向前串到已知付费页面。`;
    const settle=card(sec,'生产订单结算漏斗');
    settle.querySelector('.card-s').textContent=`${period()} 创建 · de_ods.payment_order · ${fmt(t.orders)} 笔 / ${fmt(t.users)} 个账号`;
    settle.querySelector('table').innerHTML=`<tr><th>环节 / 状态</th><th>订单</th><th>占全部订单</th><th>说明</th></tr><tr><td>创建订单</td><td><b>${fmt(t.orders)}</b></td><td>${t.orders?'100%':'—'}</td><td>所选周创建的购买意图</td></tr><tr class="warnrow"><td>PENDING</td><td><b>${fmt(t.pending)}</b></td><td class="down">${rate(t.pending,t.orders,2)}%</td><td>截至数据截点仍未确认生产成功</td></tr><tr><td>生产成功</td><td><b>${fmt(t.production)}</b></td><td class="up">${rate(t.production,t.orders,2)}%</td><td>Apple ${fmt(apple[4])} / Google ${fmt(google[4])}</td></tr><tr><td>沙盒成功</td><td>${fmt(t.sandbox)}</td><td>${rate(t.sandbox,t.orders,2)}%</td><td>测试环境，排除商业转化</td></tr><tr><td>失败</td><td>${fmt(t.failed)}</td><td>${rate(t.failed,t.orders,2)}%</td><td>后端显式 FAILED</td></tr>`;
    sec.querySelector('.note').innerHTML=`<b>当前周信号：</b>订单来源缺失 ${rate(missing[1],t.orders)}%，PENDING ${rate(t.pending,t.orders)}%。该周订单终态按截至 ${snapshot.cutoff} 的最新状态读取。`;
  }

  function renderDiagnostics(p){
    const sec=section('支付结果诊断'),t=p.total,ph=p.pendingHealth,retry=p.retryHealth,outcomes=p.orderOutcomes;
    if(!sec)return;
    const byKey=Object.fromEntries(outcomes.map(row=>[row.key,row])),unmatched=byKey.unmatched_checkout_start,client=byKey.client_success,matched=t.orders-unmatched.total,explicit=t.production+t.sandbox+t.failed,other=Math.max(0,t.orders-t.pending-explicit);
    sec.querySelector('.sec-desc').innerHTML=`当前筛选 <b>${period()}</b> 创建的 payment_order，并用同周 GA4 order_id 串联购买意图、商店面板与客户端结果；订单终态观察截至 ${snapshot.cutoff}。`;
    setKpi(sec,0,fmt(t.orders),`${fmt(t.users)} 个账号 · 所选周创建`);
    setKpi(sec,1,`${rate(t.pending,t.orders,2)}%`,`${fmt(t.pending)} 笔；截至截点仍为 PENDING`);
    setKpi(sec,2,fmt(explicit),`生产成功 ${fmt(t.production)} · 沙盒 ${fmt(t.sandbox)} · 失败 ${fmt(t.failed)}`);
    setKpi(sec,3,`${rate(ph.over7d,ph.pending)}%`,`${fmt(ph.over7d)} / ${fmt(ph.pending)}；按当前截点计算年龄`);
    setKpi(sec,4,`${rate(matched,t.orders)}%`,`${fmt(matched)} / ${fmt(t.orders)} 可按同周 order_id 串联`);
    setKpi(sec,5,`${rate(client.production,client.total)}%`,`${fmt(client.production)} / ${fmt(client.total)}；客户端成功仍 Pending ${fmt(client.pending)}`);
    sec.querySelector('.note').innerHTML=`<b>当前周判断：</b>${fmt(t.pending)} 笔 PENDING 中，${fmt(client.pending)} 笔出现客户端成功但后端未结算；其余分布在失败 / 取消、未拉起、无结果或结果字段缺失。`;
    const status=card(sec,'后端订单终态');
    status.querySelector('.card-s').textContent=`${period()} 创建的订单 · 状态观察截至 ${snapshot.cutoff}`;
    status.querySelector('table').innerHTML=`<tr><th>后端状态</th><th>订单</th><th>占全部订单</th><th>判读</th></tr><tr class="warnrow"><td>PENDING</td><td><b>${fmt(t.pending)}</b></td><td class="down">${rate(t.pending,t.orders,2)}%</td><td>截至截点尚未写入明确终态</td></tr><tr><td>SUCCESS · PRODUCTION</td><td><b>${fmt(t.production)}</b></td><td class="up">${rate(t.production,t.orders,2)}%</td><td>唯一计入商业支付成功</td></tr><tr><td>SUCCESS · SANDBOX</td><td>${fmt(t.sandbox)}</td><td>${rate(t.sandbox,t.orders,2)}%</td><td>测试环境成功</td></tr><tr><td>FAILED</td><td>${fmt(t.failed)}</td><td>${rate(t.failed,t.orders,2)}%</td><td>后端明确失败</td></tr><tr><td>CANCELED / ABANDONED / 其他</td><td>${fmt(other)}</td><td>${rate(other,t.orders,2)}%</td><td>当前订单状态字典中的其他终态</td></tr>`;
    const outcomeCard=card(sec,'5 类互斥去向'),meta={client_fail_or_cancel:['客户端失败 / 取消','result-fail'],unmatched_checkout_start:['未匹配 checkout_start','result-unmatched'],checkout_start_no_result:['已发起但无结果','result-no-result'],result_missing_is_success:['结果缺 is_success','result-missing'],client_success:['客户端成功','result-success']};
    outcomeCard.querySelector('.card-s').textContent=`${period()} 创建的订单；只与同周 checkout 事件串联`;
    outcomeCard.querySelector('.result-stack').innerHTML=outcomes.map(row=>`<span class="${meta[row.key][1]}" style="width:${rate(row.total,t.orders,3)}%" title="${meta[row.key][0]} ${rate(row.total,t.orders)}%"></span>`).join('');
    outcomeCard.querySelector('.result-keys').innerHTML=outcomes.map(row=>`<div class="result-key"><i class="${meta[row.key][1]}"></i>${meta[row.key][0]}<b>${fmt(row.total)} · ${rate(row.total,t.orders)}%</b></div>`).join('');
    outcomeCard.querySelector('table').innerHTML='<tr><th>互斥去向</th><th>订单</th><th>PENDING</th><th>生产成功</th><th>沙盒</th><th>失败</th></tr>'+outcomes.map(row=>`<tr${row.pending&&row.key!=='client_success'?' class="warnrow"':''}><td>${meta[row.key][0]}</td><td>${fmt(row.total)}</td><td>${fmt(row.pending)}</td><td>${fmt(row.production)}</td><td>${fmt(row.sandbox)}</td><td>${fmt(row.failed)}</td></tr>`).join('');
    const health=card(sec,'Pending 状态健康检查').querySelectorAll('.mv');
    const healthValues=[[`${rate(ph.neverUpdated,ph.pending)}%`,`${fmt(ph.neverUpdated)} / ${fmt(ph.pending)}`],[`${rate(ph.blankPlatform,ph.pending)}%`,`${fmt(ph.blankPlatform)} / ${fmt(ph.pending)}`],[`${rate(ph.over7d,ph.pending)}%`,`${fmt(ph.over7d)} / ${fmt(ph.pending)}`],[fmt(client.pending),'客户端成功但后端未成功']];
    health.forEach((node,index)=>node.innerHTML=`${healthValues[index][0]}<span class="sub2">${healthValues[index][1]}</span>`);
    const retryNodes=card(sec,'重复尝试造成的 Pending 膨胀').querySelectorAll('.mv');
    retryNodes[0].textContent=fmt(retry.pairs);retryNodes[1].innerHTML=`${fmt(retry.retriedPairs)}<span class="sub2">${rate(retry.retriedPairs,retry.pairs)}%</span>`;retryNodes[2].textContent=fmt(retry.pendingBefore);
  }

  function renderPaywall(p){
    const sec=section('Paywall 来源'),paywall=p.surfaceTotals.paywall,checkoutTotal=p.checkoutTotal;
    if(!sec)return;
    sec.querySelector('.sec-desc').innerHTML=`当前筛选 <b>${period()}</b> 的 Paywall 曝光与 checkout_start；均按 GA4 事件发生时间归周。UV 在来源内去重，同一设备跨来源会重复。`;
    const sourceCard=card(sec,'Paywall 曝光来源');sourceCard.querySelector('.card-s').textContent=`${period()} · ${fmt(paywall.events)} 次曝光 · ${fmt(paywall.users)} 台去重设备`;
    sec.querySelector('#paywallSourceTable').innerHTML='<tr><th>subscription_source</th><th>曝光次数</th><th>曝光占比</th><th>设备 UV</th></tr>'+(p.paywallSources.length?p.paywallSources.map(row=>`<tr><td>${row[0]}</td><td>${fmt(row[1])}</td><td><b>${rate(row[1],paywall.events)}%</b></td><td>${fmt(row[2])}</td></tr>`).join(''):emptyRow(4));
    const checkoutCard=card(sec,'支付发起来源');checkoutCard.querySelector('.card-s').textContent=`${period()} · ${fmt(checkoutTotal)} 个 order_id；source 缺失单列`;
    sec.querySelector('#checkoutSourceTable').innerHTML='<tr><th>来源</th><th>order_id</th><th>占支付发起</th><th>来源内设备 UV</th></tr>'+(p.checkoutSources.length?p.checkoutSources.map(row=>`<tr${row[0]==='来源缺失'?' class="warnrow"':''}><td>${row[0]}</td><td>${fmt(row[1])}</td><td${row[0]==='来源缺失'?' class="down"':''}>${rate(row[1],checkoutTotal)}%</td><td>${fmt(row[2])}</td></tr>`).join(''):emptyRow(4));
    const missing=p.checkoutSources.find(row=>row[0]==='来源缺失')||['来源缺失',0,0];
    sec.querySelector('.tip').innerHTML=`<b>解释边界：</b>曝光来源与支付发起来源不能直接逐行相除；当前周 ${rate(missing[1],checkoutTotal)}% checkout order_id 缺 source。`;
  }

  function renderDiscount(p){
    const sec=section('折扣订阅'),discount=p.surfaceTotals.discount,t=p.total;
    if(!sec)return;
    sec.querySelector('.sec-desc').innerHTML=`当前筛选 <b>${period()}</b>：折扣曝光按 GA4 事件发生周，订单与生产成功按订单创建周；设备与账号口径不同，不计算“订单 ÷ UV”。`;
    const main=card(sec,'折扣入口');main.querySelector('.card-s').textContent=`曝光占比按 ${fmt(discount.events)} 次折扣页曝光计算；订单成功率在同周创建订单内计算`;
    sec.querySelector('#discountSourceTable').innerHTML='<tr><th>source</th><th>曝光次数</th><th>曝光占比</th><th>设备 UV</th><th>订单</th><th>生产成功</th><th>订单成功率</th></tr>'+(p.discountSources.length?p.discountSources.map(row=>`<tr><td>${row[0]}</td><td>${fmt(row[1])}</td><td>${rate(row[1],discount.events)}%</td><td>${fmt(row[2])}</td><td>${fmt(row[3])}</td><td>${fmt(row[4])}</td><td>${rate(row[4],row[3],2)}%</td></tr>`).join(''):emptyRow(7));
    const groups=[['取消 / 关闭 Paywall 挽留',['winback_paywall_close','winback_payment_cancel']],['每日折扣（两代命名）',['daily_offer','winback_daily_launch']],['留存挽回',['winback_retention']]].map(([label,keys])=>{const rows=keys.map(key=>source(p,key));return [label,rows.reduce((sum,row)=>sum+row[1],0),rows.reduce((sum,row)=>sum+row[4],0)]});
    const totalOrders=groups.reduce((sum,row)=>sum+row[1],0),totalSuccess=groups.reduce((sum,row)=>sum+row[2],0),contribution=card(sec,'折扣来源生产成功贡献');
    contribution.querySelector('.card-s').textContent=`${period()} · 成功贡献以 ${fmt(t.production)} 笔生产成功订单为分母`;
    contribution.querySelector('table').innerHTML='<tr><th>来源集合</th><th>订单</th><th>生产成功</th><th>成功贡献</th></tr>'+groups.map(row=>`<tr><td>${row[0]}</td><td>${fmt(row[1])}</td><td>${fmt(row[2])}</td><td>${rate(row[2],t.production)}%</td></tr>`).join('')+`<tr><td>折扣 / 挽留合计</td><td><b>${fmt(totalOrders)}</b></td><td><b>${fmt(totalSuccess)}</b></td><td><b>${rate(totalSuccess,t.production)}%</b></td></tr>`;
    const cancel=source(p,'winback_payment_cancel'),close=source(p,'winback_paywall_close'),tips=card(sec,'读数建议').querySelectorAll('.tip');
    tips[0].innerHTML=`<b>取消支付挽留</b>同周创建订单成功率 ${rate(cancel[4],cancel[1],2)}%（${fmt(cancel[4])} / ${fmt(cancel[1])}）；无随机对照时不作因果解释。`;
    tips[1].innerHTML=`<b>关闭 Paywall 挽留</b>占当前周折扣曝光 ${rate((p.discountSources.find(row=>row[0]==='winback_paywall_close')||['',0])[1],discount.events)}%，生产成功 ${fmt(close[4])} 单。`;
  }

  function renderOrders(p){
    const sec=section('订单来源'),t=p.total,missing=source(p,'来源缺失');
    if(!sec)return;
    sec.querySelector('.sec-desc').innerHTML=`当前筛选 <b>${period()}</b> 创建的 ${fmt(t.orders)} 笔生产订单；生产成功率 = 同来源生产成功 ÷ 同来源订单，订单状态观察截至 ${snapshot.cutoff}。`;
    sec.querySelector('#orderSourceTable').innerHTML='<tr><th>来源</th><th>订单</th><th>订单占比</th><th>账号</th><th>PENDING</th><th>生产成功</th><th>沙盒</th><th>失败</th><th>生产成功率</th></tr>'+(p.orderSources.length?p.orderSources.map(row=>`<tr${row[0]==='来源缺失'?' class="warnrow"':''}><td>${row[0]}</td><td>${fmt(row[1])}</td><td${row[0]==='来源缺失'?' class="down"':''}>${rate(row[1],t.orders)}%</td><td>${fmt(row[2])}</td><td>${fmt(row[3])}</td><td${row[4]?' class="up"':''}>${fmt(row[4])}</td><td>${fmt(row[5])}</td><td>${fmt(row[6])}</td><td>${rate(row[4],row[1],2)}%</td></tr>`).join(''):emptyRow(9));
    settlementTable(sec.querySelector('#orderPlatformTable'),p.orderPlatforms,'平台');
    settlementTable(sec.querySelector('#orderPeriodTable'),p.orderPeriods,'周期');
    const periodMap=Object.fromEntries(p.orderPeriods.map(row=>[row[0],row])),week=periodMap.WEEK||['WEEK',0,0,0,0],month=periodMap.MONTH||['MONTH',0,0,0,0],year=periodMap.YEAR||['YEAR',0,0,0,0];
    sec.querySelector('.note').innerHTML=`<b>当前周结构：</b>来源缺失 ${rate(missing[1],t.orders)}%；生产成功 ${fmt(t.production)} 单（周卡 ${fmt(week[4])} / 月卡 ${fmt(month[4])} / 年卡 ${fmt(year[4])}）；PENDING ${rate(t.pending,t.orders)}%。`;
  }

  function renderAll(){
    const p=current();if(!p)return;
    renderOverview(p);renderDiagnostics(p);renderPaywall(p);renderDiscount(p);renderOrders(p);
  }
  window.addEventListener('dashboard-week-change',renderAll);
  renderAll();
}
).toString()+')();\n\n';

function updateWorkbench(html) {
  const previousSnapshot = html.indexOf('\n/* 统一实时快照：');
  if (previousSnapshot >= 0) {
    const scriptEnd = html.indexOf('\n</script>', previousSnapshot);
    if (scriptEnd < 0) throw new Error('Could not remove previous generated snapshot');
    html = `${html.slice(0, previousSnapshot)}${html.slice(scriptEnd)}`;
  }
  html = html
    .replaceAll('2026-08-22 03:15 UTC','2026-08-23 04:55 UTC')
    .replaceAll('08-22 03:15','08-23 04:55')
    .replaceAll('08-21 是最近完整日，08-22* 为滚动部分日','08-22 是最近完整日，08-23* 为滚动部分日')
    .replaceAll('截至 08-21；08-22* 为滚动日','截至 08-22；08-23* 为滚动日')
    .replaceAll('当前日表到 08-20，08-21~22 补 intraday','当前日表到 08-21，08-22~23 补 intraday')
    .replaceAll('08-20 及以前使用日表，08-21~22 补 intraday','08-21 及以前使用日表，08-22~23 补 intraday')
    .replaceAll('马来西亚时间 11:15','马来西亚时间 12:55');
  html = html
    .replaceAll('08-21 及以前使用日表，08-22~23 补 intraday','08-22 及以前使用日表，08-23 补 intraday')
    .replaceAll('当前日表到 08-21，08-22~23 补 intraday','当前日表到 08-22，08-23 补 intraday');
  const skinSnapshotLabel=String(skin.snapshotUtc).slice(0,19).replace('T',' ');
  html=html.replace(/<b>皮肤快照:<\/b>[^·]+·/,`<b>皮肤快照:</b>${skinSnapshotLabel} UTC ·`);
  html=replaceFrom(html,'const AB_TOTAL=','const AB_PLATFORM_TOTAL=',`const AB_TOTAL=${compact(abTotal)};`);
  html=replaceFrom(html,'const AB_PLATFORM_TOTAL=','const AB_FLOW_A_SCHEMA=',`const AB_PLATFORM_TOTAL=${compact(platformRows)};`);
  html=replaceFrom(html,'const AB_FLOW_COUNTRIES=','const AB_ONBOARDING_LOCALIZED=',`const AB_FLOW_COUNTRIES=${compact(abFlowCountries)};`);
  html=replaceFrom(html,'const AB_DAY=','const AB_HEALTH=',`const AB_DAY=${compact(abDay)};`);
  html=replaceFrom(html,'const AB_HEALTH=','const AB_LESSON=',`const AB_HEALTH=${compact(abHealth)};`);
  html=replaceFrom(html,'const AB_LESSON=','const AB_B_ONBOARDING_LESSON=',`const AB_LESSON=${compact(abLesson)};`);
  html=replaceFrom(html,'const AB_B_ONBOARDING_LESSON=','/* ═══════════ 数据(2026-07-10',`const AB_B_ONBOARDING_LESSON=${compact(abBLesson)};\n\n/* ═══════════ 登录注册国家 × 方式最新数据（页面独立截点 ${authCountryMethodWindow.cutoff}；排除测试账号） ═══════════ */\nconst AUTH_COUNTRY_METHOD_WINDOW=${compact(authCountryMethodWindow)};\nconst AUTH_COUNTRY_METHOD_OUTCOMES=${compact(authCountryMethodOutcomes)};\nconst AUTH_COUNTRY_METHOD_FAILURES=${compact(authCountryMethodFailures)};\nconst REG_DAILY=${compact(registrationDaily)};\nconst MILESTONE_TIME=${compact(milestoneTime)};\n\n`);
  html=replaceFrom(html,'/* ═══════════ 国家 × 注册方式 ═══════════ */','/* ═══════════ TAB4 注册方式 ═══════════ */',authCountryMethodRuntime);
  if(html.includes('const RET=')&&html.includes('// Push · Firebase 自动通知事件')){
    html=replaceFrom(html,'const RET=','// Push · Firebase 自动通知事件',`const RET=${compact(ret)};\nconst SEG=${compact(workbenchSeg)};\nconst CURVE=${compact(workbenchCurve)};\n`);
  }
  while (html.includes('// Push · Firebase 自动通知事件\n// Push · Firebase 自动通知事件')) {
    html=html.replace('// Push · Firebase 自动通知事件\n// Push · Firebase 自动通知事件','// Push · Firebase 自动通知事件');
  }
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
    .replaceAll('2026-08-14 09:01 UTC','2026-08-23 04:55 UTC')
    .replaceAll('08-14 09:01 UTC','08-23 04:55 UTC')
    .replaceAll('08-14 08:00 UTC','08-23 04:55 UTC 截点内')
    .replaceAll('截至 08-13；08-14* 为滚动日','截至 08-21；08-22* 为滚动日')
    .replaceAll('08-13 是最近完整日，08-14* 为滚动部分日','08-22 是最近完整日，08-23* 为滚动部分日')
    .replaceAll('08-13 仅部分设备完成 24h 观察，08-14* 为滚动部分日','08-21 仅部分设备完成 24h 观察，08-22* 为滚动部分日')
    .replaceAll('08-12 及以前使用日表，08-13~14 补 intraday','08-20 及以前使用日表，08-21~22 补 intraday')
    .replaceAll('当前日表到 08-12，08-13~14 补 intraday','当前日表到 08-20，08-21~22 补 intraday')
    .replaceAll('北京时间 17:01','马来西亚时间 10:15')
    .replaceAll('2026-08-08 00:00~08-14 09:01 UTC','2026-08-08 00:00~08-23 04:55 UTC')
    .replaceAll('2026-08-21 03:02 UTC','2026-08-23 04:55 UTC')
    .replaceAll('08-21 03:02 UTC','08-23 04:55 UTC')
    .replaceAll('08-21 03:02','08-23 04:55')
    .replaceAll('截至 08-20；08-21* 为滚动日','截至 08-21；08-22* 为滚动日')
    .replaceAll('08-20 是最近完整日，08-21* 为滚动部分日','08-22 是最近完整日，08-23* 为滚动部分日')
    .replaceAll('当前日表到 08-19，08-20~21 补 intraday','当前日表到 08-20，08-21~22 补 intraday')
    .replaceAll('08-19 及以前使用日表，08-20~21 补 intraday','08-20 及以前使用日表，08-21~22 补 intraday')
    .replaceAll('<b>皮肤快照:</b>2026-08-21 03:13 UTC','<b>皮肤快照:</b>2026-08-22 08:26 UTC')
    .replaceAll('95% CI +2.4~+7.4pp · p=.00013',`95% CI ${allStats.ci} · p=${allStats.p}`)
    .replaceAll('B +10.9pp · 课程不同',`B ${lessonStats.diff>=0?'+':''}${lessonStats.diff.toFixed(1)}pp · 课程不同`);
  const abConclusion=`    <div class="note"><b>当前结论:</b>排除测试账号后，总体 24h 早期注册率 A <b>${pct(abTotal.a.registered,abTotal.a.registeredDenom)}%</b> / B <b>${pct(abTotal.b.registered,abTotal.b.registeredDenom)}%</b>，B−A <b>${allStats.diff>=0?'+':''}${allStats.diff.toFixed(1)}pp</b>（p=${allStats.p.replace('<','&lt;')}）；Android 为 ${androidStats.diff>=0?'+':''}${androidStats.diff.toFixed(1)}pp，iOS 为 ${iosStats.diff>=0?'+':''}${iosStats.diff.toFixed(1)}pp。独立首课完课率 B−A ${lessonStats.diff>=0?'+':''}${lessonStats.diff.toFixed(1)}pp，但两组课程构成不同；生产支付成功 A ${abTotal.a.paid} / B ${abTotal.b.paid} 单。<b>当前仍不能仅凭单一早期指标判定胜负，继续实验。</b></div>`;
  html=html.replace(/    <div class="note"><b>当前结论:<\/b>[^\n]*<\/div>/,abConclusion);

  const updater=`\n/* 统一实时快照：${cutoff}。静态摘要在运行时用同一批查询结果覆盖。 */\nconst REFRESHED_SNAPSHOT=${compact(refreshedSnapshot)};\n(function applyRefreshedSnapshot(){\n const snap=REFRESHED_SNAPSHOT,n=v=>Number(v).toLocaleString('en-US'),rate=(a,b,d=1)=>b?(a/b*100).toFixed(d):'0.0';\n const setKpi=(section,index,value,note)=>{const k=section?.querySelectorAll('.kpi')[index];if(!k)return;k.querySelector('.kv').textContent=value;k.querySelector('.kn').textContent=note};\n const section=(group,tab)=>document.querySelector(\`.sec[data-group="\${group}"][data-tab="\${tab}"]\`);\n const card=(sec,title)=>[...sec.querySelectorAll('.card')].find(item=>item.querySelector('.card-t')?.textContent.includes(title));\n const login=section('login','注册总览'),complete=REG_DAILY.filter(r=>!r.d.endsWith('*')).slice(-3),rolling=REG_DAILY.at(-1);\n const cn=complete.reduce((s,r)=>s+r.n,0),cs=complete.reduce((s,r)=>s+r.s,0);\n if(login){login.querySelector('.sec-desc').innerHTML='核心只保留一条主指标：<b>首启当日注册成功设备 ÷ 当日首启设备</b>。按 GA4 user_pseudo_id 去重、UTC 日 cohort，并排除 <b>user_type=test</b>；08-22 是最近完整日，08-23* 为滚动部分日。';const tip=login.querySelector('.tip');if(tip)tip.innerHTML=\`<b>核心洞察:</b>最近三个完整日 08-20~22 注册率为 <b>\${rate(cs,cn)}%</b>（\${n(cs)} / \${n(cn)}）；当前滚动日 08-23* 为 \${rate(rolling.s,rolling.n)}%（\${n(rolling.s)} / \${n(rolling.n)}），只作实时观察。\`;}\n const nw=section('retention','签到欢迎礼');if(nw){const x=snap.newcomer,o=x.overall,s=x.signup,m=x.matched,c=x.control,pre=x.pre,post=x.post,diff=Number(m.rate)-Number(c.rate),preDiff=Number(post.rate)-Number(pre.rate);nw.querySelector('.sec-desc').innerHTML='V1.5.1 上线首轮观测，窗口为 <b>2026-08-08 00:00~08-23 04:55 UTC</b>。活动资格覆盖新老注册用户；当前仅纳入越南、韩国、沙特、马来西亚、印度尼西亚五国并排除 test / debug。';nw.querySelector('.note').innerHTML=\`<b>核心结论：</b>当前首要问题仍是参与覆盖：Day1 参与率 <b>\${Number(o.rate).toFixed(1)}%</b>。参与者 D1 比同日、同国家、同平台未参与者高 <b>\${diff.toFixed(1)}pp</b>；新注册全量 D1 上线前后变化 <b>\${preDiff>=0?'+':''}\${preDiff.toFixed(1)}pp</b>。两者均为相关观察，不代表因果净提升。\`;setKpi(nw,0,n(o.v1),\`含新老用户；参与分母代理\`);setKpi(nw,1,\`\${Number(o.rate).toFixed(1)}%\`,\`\${n(o.v2)} / \${n(o.v1)}；账号级去重\`);setKpi(nw,2,\`\${Number(s.rate).toFixed(1)}%\`,\`\${n(s.v2)} / \${n(s.v1)}；注册同日参与 \${n(s.v3)}\`);setKpi(nw,3,\`\${Number(x.progress[0].rate).toFixed(1)}%\`,\`\${n(x.progress[0].v1)} / \${n(x.progress[0].v2)} 个已成熟 cohort\`);setKpi(nw,4,\`+\${diff.toFixed(1)}pp\`,\`\${Number(m.rate).toFixed(1)}% vs 匹配未参与 \${Number(c.rate).toFixed(1)}%；非因果\`);setKpi(nw,5,\`\${preDiff>=0?'+':''}\${preDiff.toFixed(1)}pp\`,\`\${Number(pre.rate).toFixed(1)}% → \${Number(post.rate).toFixed(1)}%\`);const flow=card(nw,'参与主漏斗')?.querySelectorAll('.flow-step');if(flow){const vals=[[o.v1,'含新老用户 · 账号级去重'],[o.v2,\`\${Number(o.rate).toFixed(1)}%\`],[x.progress[0].v1,\`\${n(x.progress[0].v1)} / \${n(x.progress[0].v2)} · \${Number(x.progress[0].rate).toFixed(1)}%\`],[x.progress[1].v1,\`\${n(x.progress[1].v1)} / \${n(x.progress[1].v2)} · \${Number(x.progress[1].rate).toFixed(1)}%\`]];flow.forEach((el,i)=>{el.querySelector('.flow-num').textContent=n(vals[i][0]);el.querySelector('.flow-rate').textContent=vals[i][1]})}const countryTable=card(nw,'按国家看 Day1 参与')?.querySelector('table');if(countryTable)countryTable.innerHTML='<tr><th>国家</th><th>可识别活跃</th><th>参与账号</th><th>参与率</th></tr>'+x.countries.sort((a,b)=>Number(b.rate)-Number(a.rate)).map(r=>\`<tr><td>\${r.label}</td><td>\${n(r.v1)}</td><td>\${n(r.v2)}</td><td><b>\${Number(r.rate).toFixed(1)}%</b></td></tr>\`).join('');const dailyTable=card(nw,'每日 Day1 参与')?.querySelector('table');if(dailyTable)dailyTable.innerHTML='<tr><th>日期</th><th>可识别活跃</th><th>参与账号</th><th>参与率</th><th style="text-align:left">阶段</th></tr>'+x.daily.map(r=>\`<tr\${r.row_key==='2026-08-23'?' class="warnrow"':''}><td>\${r.row_key.slice(5)}\${r.row_key==='2026-08-23'?'*':''}</td><td>\${n(r.v1)}</td><td>\${n(r.v2)}</td><td>\${Number(r.rate).toFixed(1)}%</td><td style="text-align:left">\${r.row_key==='2026-08-23'?'滚动日':'完整日'}</td></tr>\`).join('');}\n const pay=section('payment','转化总览');if(pay){const p=snap.payment,t=p.total,sf=p.surfaceTotals,cf=p.clientFunnel;setKpi(pay,0,n(sf.paywall.users),\`\${n(sf.paywall.events)} 次曝光 · GA4 设备去重\`);setKpi(pay,1,n(sf.discount.users),\`\${n(sf.discount.events)} 次曝光 · 折扣订阅页\`);setKpi(pay,2,n(sf.any.users),'Paywall 与折扣页跨页面去重');setKpi(pay,3,\`\${rate(cf[1],cf[0])}%\`,\`\${n(cf[0])} 台曝光设备中 \${n(cf[1])} 台随后发起支付\`);setKpi(pay,4,\`\${rate(t.production,t.orders,2)}%\`,\`\${n(t.production)} / \${n(t.orders)} 笔；PENDING \${n(t.pending)} 笔\`);const missing=PAYMENT_ORDER_SOURCES.find(r=>r[0]==='来源缺失');setKpi(pay,5,\`\${rate(missing[1],t.orders)}%\`,\`\${n(missing[1])} / \${n(t.orders)} 笔 subscription_source 为空\`);const flow=pay.querySelectorAll('.push-flow .flow-step');const flowVals=[[cf[0],'Paywall / 折扣页跨页面去重'],[cf[1],\`\${rate(cf[1],cf[0])}% · 可归因 checkout\`],[cf[2],\`\${rate(cf[2],cf[1])}% · 含取消 / 失败 / 成功\`],[cf[3],\`\${rate(cf[3],cf[2])}% · 仅诊断，不作财务口径\`]];flow.forEach((el,i)=>{el.querySelector('.flow-num').textContent=n(flowVals[i][0]);el.querySelector('.flow-rate').textContent=flowVals[i][1]});const settle=card(pay,'生产订单结算漏斗')?.querySelector('table');if(settle)settle.innerHTML=\`<tr><th>环节 / 状态</th><th>订单</th><th>占全部订单</th><th>说明</th></tr><tr><td>创建订单</td><td><b>\${n(t.orders)}</b></td><td>100%</td><td>进入结算即建单</td></tr><tr class="warnrow"><td>PENDING</td><td><b>\${n(t.pending)}</b></td><td class="down">\${rate(t.pending,t.orders)}%</td><td>未收到可确认的生产成功结果</td></tr><tr><td>生产成功</td><td><b>\${n(t.production)}</b></td><td class="up">\${rate(t.production,t.orders,2)}%</td><td>Apple ${allData.payment.apple} / Google ${allData.payment.google}</td></tr><tr><td>沙盒成功</td><td>\${t.sandbox}</td><td>\${rate(t.sandbox,t.orders,2)}%</td><td>测试环境，排除商业转化</td></tr><tr><td>失败</td><td>\${t.failed}</td><td>\${rate(t.failed,t.orders,2)}%</td><td>显式 FAILED</td></tr>\`;const note=pay.querySelector('.note');if(note)note.innerHTML=\`<b>当前第一优先级仍是修复链路可解释性与支付回执：</b>生产订单有 \${rate(missing[1],t.orders)}% 来源缺失，且 \${rate(t.pending,t.orders)}% 停在 PENDING。先把 source 和订单终态打通，再比较入口优劣。\`;}\n const diag=section('payment','支付结果诊断');if(diag){const p=snap.payment,t=p.total,ph=p.pendingHealth,matched=t.orders-p.orderOutcomes.find(r=>r.key==='unmatched_checkout_start').total,client=p.orderOutcomes.find(r=>r.key==='client_success');setKpi(diag,0,n(t.orders),\`\${n(t.users)} 个账号 · ODS 权威口径\`);setKpi(diag,1,\`\${rate(t.pending,t.orders,2)}%\`,\`\${n(t.pending)} 笔；创建后均未再更新\`);setKpi(diag,2,n(t.production+t.sandbox+t.failed),\`生产成功 \${t.production} · 沙盒 \${t.sandbox} · 失败 \${t.failed}\`);setKpi(diag,3,\`\${rate(ph.over7d,ph.pending)}%\`,\`\${n(ph.over7d)} / \${n(ph.pending)}；不是正常短时等待\`);setKpi(diag,4,\`\${rate(matched,t.orders)}%\`,\`\${n(matched)} / \${n(t.orders)} 可按 order_id 串联\`);setKpi(diag,5,\`\${rate(client.production,client.total)}%\`,\`\${client.production} / \${client.total}；仅 \${client.pending} 笔成功信号仍 Pending\`);const status=card(diag,'后端订单终态')?.querySelector('table');if(status)status.innerHTML=\`<tr><th>后端状态</th><th>订单</th><th>占全部订单</th><th>判读</th></tr><tr class="warnrow"><td>PENDING</td><td><b>\${n(t.pending)}</b></td><td class="down">\${rate(t.pending,t.orders,2)}%</td><td>默认购买意图状态；创建后未更新</td></tr><tr><td>SUCCESS · PRODUCTION</td><td><b>\${t.production}</b></td><td class="up">\${rate(t.production,t.orders,2)}%</td><td>唯一计入商业支付成功的终态</td></tr><tr><td>SUCCESS · SANDBOX</td><td>\${t.sandbox}</td><td>\${rate(t.sandbox,t.orders,2)}%</td><td>测试环境成功</td></tr><tr><td>FAILED</td><td>\${t.failed}</td><td>\${rate(t.failed,t.orders,2)}%</td><td>后端明确记录失败</td></tr><tr><td>CANCELED / ABANDONED</td><td>0</td><td>0%</td><td>客户端取消与无结果尚未同步收口</td></tr>\`;const outcome=card(diag,'5 类互斥去向')?.querySelector('table');if(outcome){const names={client_fail_or_cancel:'客户端失败 / 取消',unmatched_checkout_start:'未匹配 checkout_start',checkout_start_no_result:'已拉起 · 无结果',result_missing_is_success:'结果字段缺失',client_success:'客户端成功'};outcome.innerHTML='<tr><th>互斥去向</th><th>订单</th><th>PENDING</th><th>生产成功</th><th>沙盒</th><th>失败</th></tr>'+p.orderOutcomes.map(r=>\`<tr><td>\${names[r.key]}</td><td>\${n(r.total)}</td><td>\${n(r.pending)}</td><td>\${r.production}</td><td>\${r.sandbox}</td><td>\${r.failed}</td></tr>\`).join('')}}\n})();\n`;
  const updaterExtras=`\n(function refineSnapshotCards(){
 const snap=REFRESHED_SNAPSHOT,n=v=>Number(v).toLocaleString('en-US'),rate=(a,b,d=1)=>b?(Number(a)/Number(b)*100).toFixed(d):'0.0';
 const setKpi=(section,index,value,note)=>{const k=section?.querySelectorAll('.kpi')[index];if(!k)return;k.querySelector('.kv').textContent=value;k.querySelector('.kn').textContent=note};
 const sec=(group,tab)=>document.querySelector('.sec[data-group="'+group+'"][data-tab="'+tab+'"]');
 const findCard=(section,title)=>[...section.querySelectorAll('.card')].find(item=>item.querySelector('.card-t')?.textContent.includes(title));
 const nw=sec('retention','签到欢迎礼');
 if(nw){
  const x=snap.newcomer,o=x.overall,s=x.signup,m=x.matched,c=x.control,pre=x.pre,post=x.post;
  const si=Object.fromEntries(x.signupImpact.map(r=>[r.row_key,r])),learning=x.summary.find(r=>r.row_key==='learning_24h');
  const main=findCard(nw,'参与主漏斗'),daily=findCard(nw,'每日 Day1 参与');
  main.querySelector('.card-s').textContent='Day2 / Day3 使用各自已成熟 cohort 作分母，不能直接用 '+n(o.v1)+' 作为后续节点分母';
  main.querySelector('.legend').textContent='当前已可观察 D7 成熟小样本；完整 14 日窗口仍需继续等待。';
  daily.querySelector('.card-s').textContent='每日账号去重；08-23* 截至 04:55 UTC，为滚动部分日';
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
 const skinSec=sec('incentive','皮肤概览');
 if(skinSec){
  const x=snap.skin,s=x.summary,skinTime=String(x.snapshotUtc).slice(0,19).replace('T',' ');
  const ga4=(sectionName,metric,segment='全部平台')=>x.ga4.find(r=>r.section===sectionName&&r.metric===metric&&r.segment===segment);
  const shop=ga4('page_view','Shop'),backpack=ga4('page_view','Backpack'),both=ga4('audience','Shop ∩ Backpack'),ordered=ga4('audience','Shop → Backpack（首次访问时序）');
  document.querySelector('.meta').innerHTML=document.querySelector('.meta').innerHTML.replace(new RegExp('<b>皮肤快照:</b>[^·]+·'),'<b>皮肤快照:</b>'+skinTime+' UTC ·');
  skinSec.querySelector('.sec-desc').innerHTML='生产 MySQL 当前状态快照，时间 <b>'+skinTime+' UTC</b>；仅纳入 <b>user_profile.user_type=0</b>。拥有来自 <b>user_item</b>，当前穿戴来自 <b>user_equip</b>。';
  setKpi(skinSec,0,n(s.non_default_owners),'占 '+n(s.production_users)+' 个生产账号 '+rate(s.non_default_owners,s.production_users)+'%');
  setKpi(skinSec,1,n(s.non_default_wearers),'占 '+n(s.equipped_users)+' 个有装备记录用户 '+rate(s.non_default_wearers,s.equipped_users)+'%');
  setKpi(skinSec,2,rate(s.non_default_wearers,s.non_default_owners)+'%',n(s.non_default_wearers)+' / '+n(s.non_default_owners));
  setKpi(skinSec,3,rate(s.buyers_wearing_purchased,s.buyers)+'%',n(s.buyers_wearing_purchased)+' / '+n(s.buyers));
  setKpi(skinSec,4,rate(s.reward_owners_wearing_reward,s.reward_owners)+'%',n(s.reward_owners_wearing_reward)+' / '+n(s.reward_owners));
  setKpi(skinSec,5,rate(s.buyers,s.coin_accounts)+'%',n(s.buyers)+' / '+n(s.coin_accounts)+'；累计买家口径');
  skinSec.querySelector('.note').innerHTML='<b>核心判断:</b>皮肤本身有使用价值，但价值主要在用户主动购买后兑现。购买用户当前穿戴率 '+rate(s.buyers_wearing_purchased,s.buyers)+'%，奖励用户为 '+rate(s.reward_owners_wearing_reward,s.reward_owners)+'%。';
  const entry=findCard(skinSec,'GA4 入口触达');entry.querySelector('.card-t').textContent='GA4 入口触达 · 2026-07-28~08-23 04:55 UTC';entry.querySelector('table').innerHTML='<tr><th>入口</th><th>页面 PV</th><th>设备 UV</th><th>账号 UV</th><th>PV / 设备</th></tr>'+[shop,backpack].map(r=>'<tr><td>'+r.metric+'</td><td>'+n(r.events)+'</td><td>'+n(r.devices)+'</td><td>'+n(r.accounts)+'</td><td>'+(Number(r.events)/Number(r.devices)).toFixed(2)+'</td></tr>').join('');
  const cross=findCard(skinSec,'跨入口访问'),crossRows=cross.querySelectorAll('.minirow .mv');cross.querySelector('.card-s').textContent='同一 GA4 设备去重；比例均以 '+n(shop.devices)+' 台 Shop 设备为分母';crossRows[0].innerHTML=Number(both.rate_pct).toFixed(1)+'%<span class="sub2">'+n(both.devices)+' / '+n(shop.devices)+' 台设备</span>';crossRows[1].innerHTML=Number(ordered.rate_pct).toFixed(1)+'%<span class="sub2">'+n(ordered.devices)+' / '+n(shop.devices)+' 台设备</span>';
  findCard(skinSec,'获得来源与当前使用').querySelector('table').innerHTML='<tr><th>来源</th><th>拥有者</th><th>库存件数</th><th>当前穿戴</th><th>当前穿戴率</th></tr>'+x.sources.map(r=>'<tr><td>'+r.source+'</td><td>'+n(r.owners)+'</td><td>'+n(r.units)+'</td><td>'+n(r.wearing_same_source_skin)+'</td><td>'+rate(r.wearing_same_source_skin,r.owners)+'%</td></tr>').join('');
  findCard(skinSec,'购买价格档表现').querySelector('table').innerHTML='<tr><th>价格</th><th>SKU</th><th>买家</th><th>件数</th><th>当前穿戴</th><th>买家穿戴率</th></tr>'+x.prices.map(r=>'<tr><td>'+n(r.price)+'</td><td>'+n(r.sku)+'</td><td>'+n(r.buyers)+'</td><td>'+n(r.units)+'</td><td>'+n(r.current_wearers)+'</td><td>'+rate(r.current_wearers,r.buyers)+'%</td></tr>').join('');
  findCard(skinSec,'每位买家累计购买').querySelector('table').innerHTML='<tr><th>购买件数</th><th>买家</th><th>占买家</th></tr>'+x.buyerUnits.map(r=>'<tr><td>'+r.purchase_units+' 件</td><td>'+n(r.buyers)+'</td><td>'+rate(r.buyers,s.buyers)+'%</td></tr>').join('');
  const detail=sec('incentive','皮肤明细');findCard(detail,'当前穿戴 Top 12').querySelector('table').innerHTML='<tr><th style="text-align:left">皮肤</th><th>价格</th><th>购买来源</th><th>奖励来源</th><th>当前穿戴</th></tr>'+x.wearingTop.map(r=>'<tr><td style="text-align:left">'+r.name+'</td><td>'+n(r.price)+'</td><td>'+n(r.purchase_owned_wearers)+'</td><td>'+n(r.reward_owned_wearers)+'</td><td>'+n(r.current_wearers)+'</td></tr>').join('');findCard(detail,'购买 Top 10 与当前使用').querySelector('table').innerHTML='<tr><th style="text-align:left">皮肤</th><th>件数</th><th>买家</th><th>当前穿戴</th><th>单品穿戴率</th></tr>'+x.purchaseTop.map(r=>'<tr><td style="text-align:left">'+r.name+'</td><td>'+n(r.units)+'</td><td>'+n(r.buyers)+'</td><td>'+n(r.current_wearers)+'</td><td>'+rate(r.current_wearers,r.buyers)+'%</td></tr>').join('');
  sec('incentive','数据口径').querySelector('.note').innerHTML='<b>GA4 观测缺口:</b>在 2026-07-10~08-23 04:55 UTC 窗口内，<b>shop_purchase_result</b> 与 <b>skin_equip_result</b> 均为 0；当前仍不能计算商品点击→购买、首次穿戴率、换装频次和获得→穿戴时延。';
 }
 const diag=sec('payment','支付结果诊断');
 if(diag){const p=snap.payment,t=p.total,client=p.orderOutcomes.find(r=>r.key==='client_success');diag.querySelector('.note').innerHTML='<b>核心判断：</b>PENDING 的主体仍是购买意图创建后没有被写回终态。'+n(t.pending)+' 笔 PENDING 中，仅 '+n(client.pending)+' 笔出现客户端成功但后端未结算；其余集中在失败 / 取消、未拉起支付面板、无结果或结果字段缺失。';findCard(diag,'后端订单终态').querySelector('.card-s').textContent='payment_order 权威状态；统计截止 '+snap.cutoff;}
})();
${paymentWeekRuntime}
if(typeof applyDashboardWeekFilters==='function')applyDashboardWeekFilters();
if(typeof renderWeekFilter==='function')renderWeekFilter();\n`;
  html=html.replace('\n</script>\n</body>\n</html>',`${updater}${updaterExtras}\n</script>\n</body>\n</html>`);
  return normalizeForCurrentCutoff(html);
}

const launchPath=path.join(root,'dino-launch-dashboard.html');
const workbenchPath=path.join(root,'dino-analysis-workbench.html');
const launch=updateLaunch(fs.readFileSync(launchPath,'utf8'));
const workbench=updateWorkbench(fs.readFileSync(workbenchPath,'utf8'));
fs.writeFileSync(launchPath,launch);
fs.writeFileSync(workbenchPath,workbench);
fs.writeFileSync(path.join(root,'docs/dino-english/dino-launch-dashboard.html'),launch);
fs.writeFileSync(path.join(root,'docs/dino-english/dino-analysis-workbench.html'),workbench);
process.stdout.write(JSON.stringify({cutoff,launch:{firstOpen:allData.journey.first_open,orders:allData.payment.orders,productionSuccess:allData.payment.success},workbench:{abAssigned:abTotal.a.assigned+abTotal.b.assigned,registrationDays:registrationDaily.length,paymentOrders:paymentTotal.orders,milestoneTimeSamples:Object.fromEntries(Object.entries(milestoneTime.all).map(([key,value])=>[key,value.sample]))}},null,2));
