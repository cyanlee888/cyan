import fs from 'node:fs';

const [corePath, levelPath, retentionPath, targetPath] = process.argv.slice(2);
if (!corePath || !levelPath || !retentionPath) {
  throw new Error('Usage: node build-dashboard-global-country-data.mjs <core.json> <level.json> <retention.json>');
}

const readRows = path => {
  const parsed = JSON.parse(fs.readFileSync(path, 'utf8'));
  return Array.isArray(parsed[0]) ? parsed[0] : parsed;
};

const coreRows = readRows(corePath);
const levelRows = readRows(levelPath);
const retentionRows = readRows(retentionPath);
const periods = ['all', 'w1', 'w2', 'w3', 'w4', 'w5', 'w6'];
const countries = ['vn', 'kr', 'sa', 'my', 'id', 'th'];

// Production MySQL users are assigned to country through each account's earliest
// mapped, non-test GA4 device country in the reporting window.
const moduleRows = {
  vn: {
    all:[346,336,88,600,472,452,385],w1:[120,115,31,276,205,194,158],w2:[111,108,18,164,126,124,109],w3:[90,89,23,125,105,106,93],w4:[34,32,10,63,55,43,42],w5:[45,42,15,82,65,67,60],w6:[12,10,4,17,15,13,13]
  },
  kr: {
    all:[78,78,7,134,87,107,86],w1:[14,14,2,33,19,25,19],w2:[12,12,1,21,15,16,12],w3:[15,15,0,20,11,14,12],w4:[11,11,0,21,16,16,13],w5:[28,27,4,43,28,35,29],w6:[4,4,0,8,6,7,6]
  },
  sa: {
    all:[144,138,14,420,258,278,253],w1:[37,37,1,158,97,103,88],w2:[21,19,3,50,30,26,30],w3:[16,16,2,41,24,27,20],w4:[24,23,2,61,39,39,39],w5:[47,44,5,121,66,83,80],w6:[3,3,1,13,9,10,8]
  },
  my: {
    all:[545,529,121,937,754,641,587],w1:[119,115,23,201,154,130,120],w2:[165,162,27,282,225,191,173],w3:[104,101,18,183,157,121,109],w4:[89,85,28,165,134,111,99],w5:[127,116,35,211,154,152,141],w6:[14,12,3,28,20,14,18]
  },
  id: {
    all:[354,350,36,666,444,451,362],w1:[160,157,16,330,216,211,176],w2:[89,89,6,132,92,86,72],w3:[82,81,7,135,88,99,79],w4:[25,24,5,60,38,49,31],w5:[18,18,3,52,32,35,23],w6:[3,3,2,7,6,5,5]
  },
  th: {
    all:[179,173,37,284,192,191,158],w1:[50,47,12,100,68,66,61],w2:[36,35,6,60,36,42,29],w3:[35,35,7,50,35,31,24],w4:[12,11,3,19,11,13,11],w5:[50,47,9,59,46,39,33],w6:[8,8,2,13,8,11,9]
  }
};

const moduleKeys = [
  'explore_users','explore_words_users','explore_listening_users','play_users',
  'play_blind_box_users','play_words_pk_users','play_speaking_pk_users'
];
const metricMap = new Map(
  coreRows.filter(row => row.row_type === 'metric')
    .map(row => [`${row.period_key}:${row.country_key}`, JSON.parse(row.payload)])
);
const segmentMap = new Map(
  retentionRows.filter(row => row.row_type === 'segment')
    .map(row => [`${row.period_key}:${row.country_key}:${row.row_key}`, [Number(row.devices), Number(row.v1)]])
);

const countryBusinessData = {};
for (const period of periods) {
  countryBusinessData[period] = {};
  for (const country of countries) {
    const metric = metricMap.get(`${period}:${country}`);
    if (!metric) throw new Error(`Missing metric ${period}:${country}`);
    const moduleValues = Object.fromEntries(moduleKeys.map((key, index) => [key, moduleRows[country][period][index]]));
    const segments = ['completed_trial', 'registered_no_trial', 'not_registered']
      .map(key => segmentMap.get(`${period}:${country}:${key}`) || [0, 0]);
    countryBusinessData[period][country] = {
      core: {
        logged_in_users: metric.logged_in_users,
        class_users: metric.class_users,
        dino_users: metric.dino_users,
        ...moduleValues
      },
      segments,
      payment: {
        orders: metric.orders,
        users: metric.users,
        pending: metric.pending,
        success: metric.production_success,
        sandbox: metric.sandbox_success,
        failed: metric.failed,
        apple: metric.apple_success,
        google: metric.google_success,
        week: metric.week_success,
        month: metric.month_success,
        year: metric.year_success
      }
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
const lessonIds = ['732', '1615', '734', '733', '1613', '1614'];
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

const countryRetentionRows = {};
for (const country of countries) {
  countryRetentionRows[country] = retentionRows
    .filter(row => row.row_type === 'cohort' && row.country_key === country)
    .sort((a, b) => a.row_key.localeCompare(b.row_key))
    .map(row => ({
      d: row.row_key.slice(5),
      n: Number(row.devices),
      r: [row.v1,row.v2,row.v3,row.v4,row.v5,row.v6,row.v7].map(value => value == null ? null : Number(value))
    }));
}

const compact = value => JSON.stringify(value);
let patch;
if (targetPath) {
  const target = fs.readFileSync(targetPath, 'utf8');
  const oldLine = target.match(/^const COUNTRY_LEVEL_VALUES=.*;$/m)?.[0];
  if (!oldLine) throw new Error(`COUNTRY_LEVEL_VALUES not found in ${targetPath}`);
  patch = `*** Begin Patch
*** Update File: ${targetPath}
@@
-${oldLine}
+const COUNTRY_LEVEL_VALUES=${compact(countryLevelValues)};
*** End Patch`;
} else {
  patch = `*** Begin Patch
*** Update File: dino-launch-dashboard.html
@@
-};
-let selectedPeriod='all';
+};
+const COUNTRY_BUSINESS_DATA=${compact(countryBusinessData)};
+const COUNTRY_LEVEL_VALUES=${compact(countryLevelValues)};
+const COUNTRY_RETENTION_ROWS=${compact(countryRetentionRows)};
+let selectedPeriod='all';
*** End Patch`;
}
process.stdout.write(patch);
