# FlashPilot DESIGN.md — 视觉与交互契约（单一真源）

原型（`design/prototype/`）与实现（`macos-host/`、`windows/`、`linux/` 三宿主）都遵循本文件；改视觉先改这里，再同步实现。
桌面宿主现状是系统默认样式（SwiftUI Form / WinUI StackPanel / GTK4 盒子），无自定义 tokens——本契约为**从零设计**：中性色与 accent 推导自产品站品牌 kit `site/family.css`（已含亮暗两态），状态语义色（ok/warn/danger）按 HIG 语义与暖纸底色新推导；无既有实现值可提取，落地时按本表 1:1 采用。

## Brief（2026-11-11 从零设计）

- **目标**：把三宿主共有的功能骨架（Bench / Plans / Flash / Evidence 分区，英文界面）升级为正式的刷写驾驶舱视觉。刷写是不可逆硬件操作，**安全性是视觉语言的一部分**：确认流与三态（进行中 / 成功 / 失败+证据）必须极其明确；硬件在环证据可回溯是付费卖点，界面上任何结论都必须能点回原始 `flashpilot.report/v1`。
- **原型范围**（6 屏 × 亮/暗）：① Bench 主视图（英雄屏：目标身份 + 传输/适配器组合选择 + readiness + DTC）② Plans 校验（计划清单 + 校验卡 + 指纹门 + 空态 + 失败恢复提示）③ 刷写确认流（不可逆操作确认对话框 + 武装待发态）④ 刷写运行（审计步骤时间线 + powerGuard 实时电流 + 进行态）⑤ Evidence 失败恢复（report 结构 + 恢复动作 + 成功/失败对照）⑥ 设置。
- **Exit 条件**：6 屏关键状态齐（空态/进行态/确认态/失败恢复态）+ 交互逻辑定稿 + HIG 清单全过 + 用户评审通过。
- **不在范围**：新功能与协议/契约变更（不动 `rivet-schema.json` 与 CLI JSON 形状）、商业/定价 UI（免费/付费边界以 `PRICING.md` 为唯一权威）、官网与文档站、CLI 终端输出样式。

## 设计原则（HIG 内核 + 产品特有）

- **诚实优先**：evidence level（`ci-simulated` / `implemented-unverified` / `hardware-in-loop verified` / `planned`）用支持矩阵全称展示、永不美化；仿真目标永远带徽标，仿真证据永不宣称生产刷写可靠性——这是产品核心叙事，视觉上不许稀释。
- **不可逆操作三道锁**：identity gate → fingerprint gate → 显式确认流，全部通过才允许 erase；确认对话框默认焦点永远在 Cancel，「Erase & flash」永远不用主色填充。
- **三态极明确**：进行中（accent + spinner）、成功（ok）、失败（danger + 恢复动作 + 证据入口）各有专属视觉；失败永不静默、永不只用灰色文字表达。
- **数据即证据**：所有 hex/地址/指纹/DID/JSON/UTC 时间戳一律等宽字体且可选中复制；字段名与 CLI/MCP JSON 输出保持同名，界面结论可点回原始 report。
- **内容至上与键盘可达**（HIG 内核）：chrome 退后，审计时间线与报告字段是主角；每个操作有键盘路径与可见提示，焦点环清晰可见。

## Tokens（语义与推导依据；值不在此复制）

值类 token 真源 = `site/family.css`（家族 kit）+ 本产品状态色推导；原型 `design/prototype/shared.css` 与其一一对应，本表只记语义、来源与推导依据。中性色与 accent 取 kit 现行值（已含亮暗两态）；`--ok/--warn/--danger` 系按 HIG 语义与暖纸底色新推导（依据：与 terracotta accent 可区分 + 双态 WCAG AA）。

| Token | 语义 | 来源 |
|---|---|---|
| `--bg --surface --raised --line` | 画布/卡片/悬浮/分隔 中性系 | kit 原值（`--line` 为 kit border 12% 实体化） |
| `--ink --mute` | 主/次级文字 | kit 原值 |
| `--accent --accent-soft` | 当前选中/交互入口/进行态 | kit 原值（soft 实体化） |
| `--ok --ok-soft` | 成功/检查通过/`hardware-in-loop verified` | 新推导（AA 双态） |
| `--warn --warn-soft` | 警告/`implemented-unverified`/lint finding | 新推导（AA 双态） |
| `--danger --danger-soft` | 失败/破坏性动作/safety abort | 新推导（AA 双态） |

- **字体**：界面 `system-ui, -apple-system, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei"`；数据/日志 `ui-monospace, "SF Mono", "Cascadia Code", Consolas, monospace`（三宿主现状已用 Consolas/`.monospaced`，提升为契约）。正文 13.5px/1.55（工具密度），面板标题 600，次级 12.5px，辅助 11px，数据一律 mono。
- **圆角**：窗口 12px · 卡片 10px · 控件 6px。**间距节奏**：4/8/12/16/24。**动效**：120ms ease；spinner 1s linear。
- **语言**：界面文案跟随三宿主现状（英文）；本契约与内部评审文档用中文。

## 组件词汇

`TargetCard`（目标身份 + evidence level 徽标）· `TransportRow`（适配器/传输组合行 + level 徽标）· `ReadinessCheck`（通过/警告/失败 + check code）· `PlanRow`（清单行 + 校验状态 chip）· `VerificationCard`（findings + segment layout + fingerprint gate）· `GateStrip`（三道门事实条：identity / fingerprint / powerGuard）· `ConfirmDialog`（不可逆确认，Cancel 默认焦点）· `StepTimeline`（审计步骤时间线：done/in-progress/pending + 耗时）· `PowerMeter`（实时电流 + 上限条）· `EvidenceReport`（report 字段表 + bounded error + 恢复面板）· `LevelBadge`（证据级全称 chip；色彩映射固定：`hardware-in-loop verified`=ok · `ci-simulated`=accent（仿真态是产品基线状态，兼作当前选中语义）· `implemented-unverified`=warn · `planned`=mute）· `Toggle` / `Segmented` · `Toast`。

## 不变式

1. `accent` 只用于：当前选中、交互入口、进行态；成功/失败/警告一律用 `ok`/`danger`/`warn` 表达，禁止用 accent 表达结果，禁止大面积色块。
2. 仿真与真机永不混排：simulated 目标永远带 `ci-simulated` 徽标；evidence level 只用支持矩阵的四个全称，不自造缩写。
3. 不可逆操作必过三道门 + 显式确认；确认键不用主色填充、不是默认焦点；刷写开始后没有「取消」，abort 只能作为安全事件被记录。
4. 数据（hex/指纹/JSON/时间戳）一律 mono 且可选中复制；字段名与 CLI/MCP JSON 同名；失败态必须同时给出证据入口与恢复动作。
5. 亮暗成对设计，不存在只有暗态的界面；层级 ≤3 层表面（`bg`/`surface`/`raised`），分隔靠 `line`，不用阴影堆叠表达层级。


## 平台映射与差异声明（预钉 · 宿主实现时升级为落点表）

统一层（三平台必须一致，`design/prototype/` 原型已锁定）：信息架构、核心流程、快捷键语义、
语义色与层级词汇。因地制宜层（按平台惯例落地，不预画像素）：

| 维度 | macOS | Windows | Linux |
|---|---|---|---|
| 修饰键 | ⌘ | Ctrl | Ctrl |
| 命令入口 | 原生菜单栏 | 菜单栏/命令行内 | 菜单栏 |
| 字体 | 系统栈 + PingFang SC | 系统栈 + Microsoft YaHei | 系统栈 + Noto Sans CJK |
| 原生控件 | SwiftUI 控件 | WinUI 3 控件 | GTK4 控件 |

差异声明纪律：宿主特例必须先写进本节才能实现；未声明的宿主差异按违约处理
（案例：taskly 漂移台账 D8）。
