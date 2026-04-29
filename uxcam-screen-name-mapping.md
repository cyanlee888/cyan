# UXCam 屏幕名映射表

> 更新日期：2026-04-24
>
> UXCam 当前使用自动屏幕检测，Dashboard 中显示的是 Activity / Fragment 类名。
> 本文档提供类名 → 中文业务名的映射，供产品 / 运营在 Dashboard 中对照使用。

---

## 启动 & 主框架


| Dashboard 屏幕名                | 中文业务名        | 所属模块         | 说明             |
| ---------------------------- | ------------ | ------------ | -------------- |
| `SplashActivity`             | 启动页          | app          | 冷启动闪屏          |
| `DeepLinkDispatcherActivity` | DeepLink 分发页 | app          | 外部链接跳转中转，用户无感知 |
| `MainActivity`               | 主页面          | feature/main | 底部 Tab 容器      |


## 首页


| Dashboard 屏幕名  | 中文业务名 | 所属模块         | 说明      |
| -------------- | ----- | ------------ | ------- |
| `HomeFragment` | 首页    | feature/home | AI 对话入口 |


## 账号 & 登录


| Dashboard 屏幕名                   | 中文业务名       | 所属模块            | 说明                                 |
| ------------------------------- | ----------- | --------------- | ---------------------------------- |
| `LoginAccountActivity`          | 登录页         | feature/account | 含 Google / Kakao / Facebook 三方登录入口 |
| `PhoneVerifyLoginActivity`      | 手机号验证登录     | feature/account | 输入手机号 + 验证码登录                      |
| `KakaoAccountBindPhoneActivity` | Kakao 绑定手机号 | feature/account | Kakao 账号绑定手机号                      |
| `ProfileSettingActivity`        | 个人资料设置      | feature/account | 注册后引导填写资料                          |
| `PickCountryActivity`           | 选择国家        | feature/account | 国家/地区选择器                           |
| `PickLanguageActivity`          | 选择语言        | feature/account | App 语言切换                           |
| `PhoneRegionSelectFragment`     | 手机区号选择      | feature/account | 弹窗：选择手机号国际区号                       |
| `ProfileConfigGuideFragment`    | 资料填写引导      | feature/account | 引导用户完善个人资料                         |


## 个人中心


| Dashboard 屏幕名         | 中文业务名  | 所属模块       | 说明             |
| --------------------- | ------ | ---------- | -------------- |
| `MeSidebarFragment`   | 侧边栏    | feature/me | 个人中心入口（头像、设置等） |
| `ProfileEditActivity` | 编辑个人资料 | feature/me | 修改头像、昵称等       |
| `InviteActivity`      | 邀请好友   | feature/me | 邀请好友页面         |


## AI 教室


| Dashboard 屏幕名         | 中文业务名 | 所属模块            | 说明                     |
| --------------------- | ----- | --------------- | ---------------------- |
| `AiClassRoomActivity` | AI 教室 | feature/aiclass | 核心教学页面（H5 + Native 混合） |


## 365 每日课


| Dashboard 屏幕名                 | 中文业务名  | 所属模块           | 说明       |
| ----------------------------- | ------ | -------------- | -------- |
| `DailyLessonHomeFragment`     | 每日课首页  | feature/lesson | 每日课程列表入口 |
| `DailyLessonOverviewActivity` | 每日课总览  | feature/lesson | 课程内容概览   |
| `LessonCardListActivity`      | 课程卡片列表 | feature/lesson | 课程卡片浏览   |


## 智学


| Dashboard 屏幕名                       | 中文业务名       | 所属模块           | 说明       |
| ----------------------------------- | ----------- | -------------- | -------- |
| `SmartLevelSelectActivity`          | 智学 - 级别选择   | feature/zhixue | 选择学习级别   |
| `SmartCourseDetailActivity`         | 智学 - 课程详情   | feature/zhixue | 课程详情页    |
| `ZhiXueLockedLessonPreviewActivity` | 智学 - 锁定课程预览 | feature/zhixue | 未解锁课程的预览 |
| `SmartCourseListFragment`           | 智学 - 课程列表   | feature/zhixue | 课程列表     |
| `SmartLevelSelectFragment`          | 智学 - 级别选择子页 | feature/zhixue | 级别选择内嵌页  |
| `MajorFragment`                     | 智学 - 已完成课程  | feature/zhixue | 已完成的课程列表 |


## 支付


| Dashboard 屏幕名            | 中文业务名  | 所属模块        | 说明            |
| ------------------------ | ------ | ----------- | ------------- |
| `PayHomeActivity`        | 支付首页   | feature/pay | 订阅方案选择        |
| `PayHomeFragment`        | 支付首页内容 | feature/pay | 支付首页内嵌内容      |
| `PayIntercepterActivity` | 支付拦截页  | feature/pay | 非会员操作时弹出的付费引导 |
| `FreeTrialActivity`      | 免费试用   | feature/pay | 免费试用引导页       |
| `PayRetentionDialog`     | 支付挽留弹窗 | feature/pay | 用户关闭支付页时的挽留弹窗 |


## 电台


| Dashboard 屏幕名       | 中文业务名  | 所属模块          | 说明       |
| ------------------- | ------ | ------------- | -------- |
| `RadioHomeActivity` | 电台首页   | feature/radio | 电台主页     |
| `RadioHomeFragment` | 电台首页内容 | feature/radio | 电台主页内嵌内容 |


## 复习课


| Dashboard 屏幕名              | 中文业务名     | 所属模块                | 说明         |
| -------------------------- | --------- | ------------------- | ---------- |
| `ExercisesActivity`        | 练习页       | feature/reviewclass | 复习课练习主页面   |
| `WordLearningActivity`     | 单词学习      | feature/reviewclass | 单词学习页      |
| `SentenceLearningActivity` | 句子学习      | feature/reviewclass | 句子学习页      |
| `WordToImgFragment`        | 练习 - 单词选图 | feature/reviewclass | 根据单词选择对应图片 |
| `ImgToWordFragment`        | 练习 - 看图选词 | feature/reviewclass | 根据图片选择对应单词 |
| `AudioToImgFragment`       | 练习 - 听音选图 | feature/reviewclass | 根据音频选择对应图片 |
| `SentenceToImgFragment`    | 练习 - 句子选图 | feature/reviewclass | 根据句子选择对应图片 |
| `SentenceDragFragment`     | 练习 - 句子拖拽 | feature/reviewclass | 拖拽单词组成正确句子 |


## 通用容器


| Dashboard 屏幕名          | 中文业务名  | 所属模块              | 说明                           |
| ---------------------- | ------ | ----------------- | ---------------------------- |
| `H5ContainerActivity`  | H5 页面  | core/webview      | WebView 通用容器，所有 H5 页面均显示为此名称 |
| `UpdateDialogFragment` | 版本更新弹窗 | core/designsystem | App 版本更新提示弹窗                 |


