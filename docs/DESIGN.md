---
version: alpha
name: UXCam Internal Tutorial
description: 内部 UXCam 教程静态页 — 企业文档风、清晰层次、弱装饰
colors:
  background: "#f4f5f8"
  surface: "#ffffff"
  text-primary: "#111827"
  text-secondary: "#6b7280"
  text-body: "#374151"
  accent: "#1d4ed8"
  accent-container: "#eff6ff"
  border: "#e5e7eb"
  success: "#065f46"
  success-container: "#f0fdf4"
  success-border: "#bbf7d0"
  ops-heading: "#1e40af"
  ops-border: "#bfdbfe"
  warn-bg: "#fffbeb"
  warn-border: "#fcd34d"
  warn-text: "#92400e"
  warn-text-strong: "#78350f"
  video-bg: "#faf5ff"
  video-border: "#e9d5ff"
  video-accent: "#6b21a8"
  neutral-subtle: "#f9fafb"
  code-bg: "#f3f4f6"
  tag-bg: "#e5e7eb"
  tag-text: "#4b5563"
  tag-web-bg: "#dbeafe"
  tag-web-text: "#1e40af"
  tag-mob-bg: "#fef3c7"
  tag-mob-text: "#92400e"
  platform-on-bg: "#ecfdf5"
  platform-on-border: "#6ee7b7"
  platform-on-text: "#047857"
  table-header-bg: "#f9fafb"
  table-stripe: "#fafafa"
  hover-scrim: "rgba(0,0,0,0.03)"
typography:
  ui-sans:
    fontFamily: "'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif"
    fontSize: 1rem
    lineHeight: 1.65
  h1:
    fontSize: 1.65rem
    fontWeight: 700
    letterSpacing: "-0.02em"
  h2-module:
    fontSize: 1.2rem
    fontWeight: 700
  h2-mapping:
    fontSize: 1.05rem
    fontWeight: 700
  h3:
    fontSize: 0.95rem
    fontWeight: 700
  body:
    fontSize: 1rem
    lineHeight: 1.65
  lead:
    fontSize: 0.95rem
  small:
    fontSize: 0.9rem
  caption:
    fontSize: 0.8rem
  table:
    fontSize: 0.88rem
  code-inline:
    fontSize: 0.85em
rounded:
  xs: 4px
  sm: 8px
  md: 10px
  lg: 12px
  xl: 14px
  pill: 999px
spacing:
  xs: 4px
  sm: 8px
  md: 16px
  lg: 24px
  xl: 32px
  xxl: 40px
layout:
  content-max-width: 920px
  section-gap: 24px
components:
  card-module:
    backgroundColor: "{colors.surface}"
    borderColor: "{colors.border}"
    rounded: "{rounded.xl}"
  callout-warn:
    backgroundColor: "{colors.warn-bg}"
    borderColor: "{colors.warn-border}"
    textColor: "{colors.warn-text}"
  tab-active:
    textColor: "{colors.accent}"
    borderColor: "{colors.accent}"
---

## Overview

教程页面向内部管理 / 业务同学：信息密度适中，以**可读、可扫**为先。视觉上是轻量「文档产品」而非营销落地页：白底卡片浮在浅灰画布上，主色仅用于链接与当前 Tab，成功/提示用绿色与琥珀分区，避免彩虹色块。

## Colors

- **background**：整页画布，略冷灰，减轻长文阅读疲劳。
- **surface**：卡片与目录底色，与背景形成清晰层级。
- **accent**：唯一强交互色，用于外链、目录链接、选中 Tab；勿用于大面积极色块。
- **warn-***：全局提示（如外链图片过期说明），固定琥珀系以保证辨识度。
- **success-***：「您能得到的结论」区块，与操作步骤（蓝色倾向）形成语义对比。

## Typography

中文优先使用系统栈：苹方 / 微软雅黑 + `system-ui`。标题字重 700，正文 400（浏览器默认），行高略松（1.65）利于段落阅读。表格与注释略缩小字号以区分层级。

## Layout

主列最大宽度 920px，居中；双栏栅格在窄屏（约 720px 以下）折为单列。区块之间保持统一垂直节奏（spacing.section-gap）。

## Elevation & Depth

不使用重阴影；层次依赖 **1px 边框** + **surface 与 background 对比**。媒体区块底栏用细顶边线与正文区分。

## Shapes

卡片与目录使用较大圆角（12–14px），与内嵌小标签、行内 code 的小圆角（4px）形成尺度对比。平台切换使用 pill（999px）。

## Components

- **card-module**：教程每一小节模块；白底、灰边、充足内边距。
- **callout-warn**：页顶与关键提醒；琥珀底+边框，正文中 strong 用 warn-text-strong。
- **tab-active**：底部 2px 边线与 accent 同色，hover 仅用浅 scrim，不新增彩色。

## Do's and Don'ts

- **Do**：改色或间距时优先修改 `DESIGN.md` 中 YAML，再同步 HTML 内 `:root` 映射（或后续用脚本从 DESIGN.md 生成 CSS）。
- **Do**：新增组件样式时，在 `components` 中补充条目并在正文说明用途。
- **Don't**：在 HTML 中散落新的十六进制色值而不回填 token。
- **Don't**：用 accent 色铺满大块背景，以免抢过正文与配图注意力。
