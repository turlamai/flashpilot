# FlashPilot DESIGN.md — 视觉与交互契约

原型（`design/prototype/`）与实现（`macos-host/`、`windows/`、`linux/` 三宿主）都遵循本文件的语义、决策与边界；**数值不在此复制**。

**真源分工**：颜色、字体栈、字号、圆角、间距、动效时长的具体值以 `design/prototype/shared.css` 为唯一真源（亮暗成对；中性色与 accent 推导自家族 kit `site/family.css`）。改值改 CSS，改语义改本文件。
桌面宿主现状是系统默认样式（SwiftUI Form / WinUI StackPanel / GTK4 盒子），无自定义 tokens——本契约为**从零设计**：中性色与 accent 推导自产品站品牌 kit（已含亮暗两态），状态语义色（ok/warn/danger）按 HIG 语义与暖纸底色新推导；无既有实现值可提取，落地时按 CSS 真源采用。

## Brief（2026-11-11 从零设计）

- **目标**：把三宿主共有的功能骨架（Bench / Plans / Flash / Evidence 分区，英文界面）升级为正式的刷写驾驶舱视觉。刷写是不可逆硬件操作，**安全性是视觉语言的一部分**：确认流与三态（进行中 / 成功 / 失败+证据）必须极其明确；硬件在环证据可回溯，界面上任何结论都必须能点回原始 `flashpilot.report/v1`。
- **原型范围**（6 屏 × 亮/暗）：① Bench 主视图（英雄屏：目标身份 + 传输/适配器组合选择 + readiness + DTC）② Plans 校验（计划清单 + 校验卡 + 指纹门 + 空态 + 失败恢复提示）③ 刷写确认流（不可逆操作确认对话框 + 武装待发态）④ 刷写运行（审计步骤时间线 + powerGuard 实时电流 + 进行态）⑤ Evidence 失败恢复（report 结构 + 恢复动作 + 成功/失败对照）⑥ 设置。
- **Exit 条件**：6 屏关键状态齐（空态/进行态/确认态/失败恢复态）+ 交互逻辑定稿 + HIG 清单全过 + 用户评审通过。
- **不在范围**：新功能与协议/契约变更（不动 `rivet-schema.json` 与 CLI JSON 形状）、商业/定价 UI、官网与文档站、CLI 终端输出样式。

## 设计原则（HIG 内核 + 产品特有）

- **诚实优先**：evidence level（`ci-simulated` / `implemented-unverified` / `hardware-in-loop verified` / `planned`）用支持矩阵全称展示、永不美化；仿真目标永远带徽标，仿真证据永不宣称生产刷写可靠性——这是产品核心叙事，视觉上不许稀释。
- **不可逆操作三道锁**：identity gate → fingerprint gate → 显式确认流，全部通过才允许 erase；确认对话框默认焦点永远在 Cancel，「Erase & flash」永远不用主色填充。
- **三态极明确**：进行中（accent + spinner）、成功（ok）、失败（danger + 恢复动作 + 证据入口）各有专属视觉；失败永不静默、永不只用灰色文字表达。
- **数据即证据**：所有 hex/地址/指纹/DID/JSON/UTC 时间戳一律等宽字体且可选中复制；字段名与 CLI/MCP JSON 输出保持同名，界面结论可点回原始 report。
- **内容至上与键盘可达**（HIG 内核）：chrome 退后，审计时间线与报告字段是主角；每个操作有键盘路径与可见提示，焦点环清晰可见。

## Tokens（语义与推导依据；值不在此复制）

值类 token 真源 = `design/prototype/shared.css`（中性色与 accent 来自 `site/family.css` 家族 kit；状态色为产品推导），本表只记语义、来源与推导依据。`--ok/--warn/--danger` 系按 HIG 语义与暖纸底色新推导（依据：与 terracotta accent 可区分 + 双态 WCAG AA）。

| Token | 语义 | 来源 |
|---|---|---|
| `--bg --surface --raised --line` | 画布/卡片/悬浮/分隔 中性系 | kit 原值（`--line` 为 kit border 12% 实体化） |
| `--ink --mute` | 主/次级文字 | kit 原值 |
| `--accent --accent-soft` | 当前选中/交互入口/进行态 | kit 原值（soft 实体化） |
| `--ok --ok-soft` | 成功/检查通过/`hardware-in-loop verified` | 新推导（AA 双态） |
| `--warn --warn-soft` | 警告/`implemented-unverified`/lint finding | 新推导（AA 双态） |
| `--danger --danger-soft` | 失败/破坏性动作/safety abort | 新推导（AA 双态） |

- **字体角色**：界面用系统 sans 栈；数据/日志一律 mono（三宿主现状已用 Consolas/`.monospaced`，提升为契约）。工具密度的字号层级（正文 / 面板标题 / 次级 / 辅助）由 `shared.css` 的 `--mono` 与字号规则定义。
- **几何与动效**：窗口/卡片/控件圆角、间距节奏与动效时长均以 `shared.css` 为准。
- **语言**：界面文案跟随三宿主现状（英文）；本契约与内部评审文档用中文。

## 组件词汇

`TargetCard`（目标身份 + evidence level 徽标）· `TransportRow`（适配器/传输组合行 + level 徽标）· `ReadinessCheck`（通过/警告/失败 + check code）· `PlanRow`（清单行 + 校验状态 chip）· `VerificationCard`（findings + segment layout + fingerprint gate）· `GateStrip`（三道门事实条：identity / fingerprint / powerGuard）· `ConfirmDialog`（不可逆确认，Cancel 默认焦点）· `StepTimeline`（审计步骤时间线：done/in-progress/pending + 耗时）· `PowerMeter`（实时电流 + 上限条）· `EvidenceReport`（report 字段表 + bounded error + 恢复面板）· `LevelBadge`（证据级全称 chip；色彩映射固定：`hardware-in-loop verified`=ok · `ci-simulated`=中性描边（虚线边 + ink 文字，专用 `.badge.ci`，不占用 accent）· `implemented-unverified`=warn · `planned`=mute）· `SimTag`（来源标记 `.simtag`：`sim meter` 等仿真组件在出现处就地标注，虚线边 + ink 文字，与 LevelBadge 同一视觉族）· `Toggle` / `Segmented` · `Toast`。

## 不变式

1. `accent` 只用于：当前选中、交互入口、进行态；成功/失败/警告一律用 `ok`/`danger`/`warn` 表达，禁止用 accent 表达结果，禁止大面积色块。
2. 仿真与真机永不混排：simulated 目标永远带 `ci-simulated` 徽标；evidence level 只用支持矩阵的四个全称，不自造缩写。仿真来源在同一次运行的 Bench、门禁条、确认框、运行页四处必须同源标注（例：功率计未配置时，四处一律写 `sim meter`，不得只写「armed 5–1500 mA」）。
3. 不可逆操作必过三道门 + 显式确认；确认键不用主色填充、不是默认焦点；刷写开始后没有「取消」，abort 只能作为安全事件被记录；运行期间导航锁定（`.item.disabled`），跑到完成或失败才解锁。
4. 数据（hex/指纹/JSON/时间戳）一律 mono 且可选中复制；字段名与 CLI/MCP JSON 同名；失败态必须同时给出证据入口与恢复动作。
5. 亮暗成对设计，不存在只有暗态的界面；层级 ≤3 层表面（`bg`/`surface`/`raised`），分隔靠 `line`，不用阴影堆叠表达层级。

## 平台映射与差异声明（预钉 · 宿主实现时升级为落点表）

统一层（三平台必须一致，`design/prototype/` 原型已锁定）：信息架构、核心流程、快捷键语义、
语义色与层级词汇。因地制宜层（按平台惯例落地，不预画像素）：

| 维度 | macOS | Windows | Linux |
|---|---|---|---|
| 修饰键 | ⌘ | Ctrl | Ctrl |
| 命令入口 | 原生菜单栏 | 菜单栏/命令行内 | 菜单栏 |
| 原生控件 | SwiftUI 控件 | WinUI 3 控件 | GTK4 控件 |

差异声明纪律：宿主特例必须先写进本节才能实现；未声明的宿主差异按违约处理
（案例：taskly 漂移台账 D8）。

## 2026-11-15 · 原型交互补齐

入口为 prototype/bench.html。流程为 Bench → Plans → 显式确认 → 模拟运行 → 本地证据。校验失败的计划不能进入执行；取消回到 Plans；导出是原型报告，不能作为真实 ECU 证据。

根级 index.html 只负责首次进入主界面；页面切换直接到目标界面，不再保留页面目录。原型运行脚本 prototype-runtime.js / prototype-flow.js 只表达浏览器内的交互合同；正式产品业务仍由既定引擎实现。真实设备、模型和发布服务均未连接。凭据演示不保存密钥，破坏性示例与派发保留确认和取消。

这些是可评审的增量改动，未替用户勾选满意度、HIG 最终验收或设计冻结条件。

## Prototype source checkpoint — 2026-11-15

`index.html` opens the primary prototype directly. Screen-directory launchers have been removed. All local scripts, styles and referenced assets needed by this checkpoint are versioned under this directory; OpenDesign metadata is excluded. This is an editable prototype checkpoint, not a claim that the native product or external services implement these interactions.

## 2026-11-26 · 家族基线对齐（`2026-11-20-minimal-family`）

起始 SHA `5ca6ff2`，范围仅 `design/prototype/`；信息架构、强调色、示例数据、主题存储与切换机制、产品行为均未改动。

| 项 | 结果 | 证据 / 限度 |
|---|---|---|
| R1 主题切换 | 通过 | 六页标题栏的 `◐` 字形改为 16px 线性 SVG（深色显月亮、浅色显太阳），静默图标按钮 28px、无静置边框与底色；`aria-label` 与 `title` 随主题同步，状态栏图例同步换图标 |
| R2 12px 下限 | 通过 | 源码 10–11px 声明 23 → 0；渲染 small 218 → 0；层级保持 辅助 12 / 标签 13 / 正文 14；`kbd`、徽标、键位提示外框随字号微调，多行文本行高 ≥ 1.4 |
| R3 减弱动效与焦点 | 通过 | `shared.css` 补 `prefers-reduced-motion`；焦点环沿用既有 `button:focus-visible`，图标按钮 offset 2px |
| R4 原型完整性 | 部分通过 | 无远程依赖、本地引用全通；深色补齐舞台底色与 `color-scheme`（原先只有窗口变暗）；`design/index.html` 保持直达主界面，见下方未决 |
| R5 可访问名称 | 通过 | 设置页四个开关补 `role="switch"`、行标签名称与状态；nameless 4 → 0 |
| R6 版式缺陷 | 通过 | plan：文件名不再断行（列表 330 → 348px）、WARNING 与正文不再粘连、详情标题保持单行；flash：直接进入时头部换行，run ID 与状态徽标不再折断；默认尺寸下页面不再多出 20px 空滚动 |
| R7 契约同步 | 通过 | token 值未改，本节即记录 |
| R8 仓库门禁 | 通过 | 仓内没有读取 `design/` 的 CI 或脚本；两个脚本 `node --check` 与静态扫描通过 |

同批修正：`prototype-runtime.js` / `prototype-flow.js` 注入的对话框、提示与 title 文案由中文改为英文（语义不变，界面语言以本契约为准）；设置页 Light / Dark 分段随当前主题显示（原先恒为 Light）。

未决（需所有者决定，未改）：~~浅色主题对比度低于契约所称双态 AA——accent 文字对 accent-soft 2.77:1（主按钮、accent 徽标），`--ok` 4.38:1，`--warn` 3.67:1，涉及色值 token~~（已落地，见下节）；`design/index.html` 是否恢复为页面总览——#55 记录所有者已确认移除页面目录，与家族 R4 冲突；原型未声明最小窗口宽度，窗口固定 1180px，视口窄于 1228px 时整页横向滚动。

## 2026-11-26 · 对比度落地（`2026-11-20-minimal-family`）

起始 SHA `382f144`，范围仅 `design/prototype/`。所有者授权按「保色相、普通文字不低于 4.5:1」处理上节未决的 token；信息架构、示例数据与产品行为不变。

| token | 亮色 | 暗色 | 取值依据 |
|---|---|---|---|
| `--accent` | `#D97757` → `#B34B29` | `#E08A6B`（不变） | 主按钮与 accent 徽标是「accent 字压 accent-soft」的软样式，落点取 `--accent-soft`（原 2.77） |
| `--accent-contrast`（新增） | `#FFFFFF` | `#1D120C` | accent 之上的文字。原先品牌标在亮色写死 `#fff`、暗色另有一条 `.dark` 覆盖，现收为一个 token |
| `--ok` | `#2F7D46` → `#2E7944` | `#63C58B`（不变） | `--ok-soft` 上的 passed / verified 徽标（原 4.38） |
| `--warn` | `#B26B1B` → `#9C5E18` | `#E5A54B`（不变） | `--warn-soft` 上的 warning / unverified 徽标（原 3.67） |

**未激活态不再用 opacity 表达**。原先四处用整块透明度压暗「尚未运行」的内容：`confirm.html` 的 `.steps`（.45）、`evidence.html` 的 `.srow.na`（.5）、`flash.html` 的 `.step.pending`（.5）、`bench.html` 的 `.row.dim`（.55）。这些文字是状态本身（`not run` / `pending` / `planned`），压暗后读数只有 1.9–3.9。改为去掉透明度，步骤名与图标用 `--mute`、字重降一档；状态仍由文字与 `○` / `—` 标记给出，不只靠颜色。真正禁用的控件（`.btn:disabled` .45、`.item.disabled` .38）保持不变。

验证：无头 Edge 1280×800，6 页 × 亮/暗，脚本测量：低于 4.5:1 的文字对 68 / 24 → 0 / 0；sub-12px 0；横向溢出 0；无可访问名称的控件 0；脚本错误 0。截图核对 evidence 亮色与 bench 暗色：未运行行与已完成行仍可区分。未覆盖：模态框遮罩后的内容按未加遮罩计算、非文字对比（图标、控件边界 3:1）。

产品侧同步（漂移，未改）：本原型的 token 是产品样式的先行稿，宿主落地时取 `shared.css` 现值并补 `--accent-contrast`。

仍记为待办、未改：`design/index.html` 直达主界面（见 #55，与家族 R4 的冲突待所有者裁定）；原型固定 1180px 窗口、未声明最小宽度；`.brand .name` 与 `dialog h2` 等处字重 700（家族 400 / 500 / 600）。


## 气质档位声明与对齐 — 2026-11-26（家族规范 `2026-11-26-temperament-profiles`）

本轮按 owner 指令对全部产品原型过一遍新规范。做法是「声明档位 + 对齐受影响的差量 + 记录遗留」：没有重绘任何屏幕，没有改动信息架构，也没有新增 token 值表。**档位由 agent 代为判定，待 owner 确认或更正。**

### 档位

- **主档位**：监控。刷写驾驶舱：bench 就绪状态、进行中的电流与步骤时间线、证据回看，要立刻看出异常。
- **主任务**：沿用上文 Brief，本节不复述。
- **与静读默认的差量**：数值列等宽并对齐；十六进制与报告 ID 用等宽角色；紧凑预设；只为状态变化而动。不可逆操作的确认流仍按上文契约，不因档位放松。
- **借用档位**：设置页沿用静读默认。

### 本轮改动

- 字体栈：UI 栈与等宽栈在通用回退前补 CJK 回退（§9「等宽与中文」）；值仍只维护在 `shared.css`。
- 排版基线块：`body { text-autospace: normal; line-break: strict }`、亮暗成对的 `::selection`、中性 `scrollbar-color`（§10 中文排版、状态齐全）。

### 测量

无头 Edge 1280×800（移动页 390×844），亮暗各渲染一次，逐页统计；对比度为脚本近似计算（半透明高亮底、彩色 emoji、content 里的符号会被误计）。

低对比文字 0→0；正文超版心 0→0。

### 遗留（本轮未处理）

- 行内文字链接的命中区不足 24px（上轮基线遗留，面广）：本轮未动，需逐页裁决是加内边距还是改成按钮。
- 监控/极客档要求数值列逐列核对等宽数字；本轮只有脚本统计命中数，没有逐列看过。
- 上文已记的尺度待办（圆角、字号、字重）不变，继续渐进对齐。
- §10 核心屏打磨轮：每轮须 owner 裁决；本轮只有 agent 的测量与自评，不计入打磨轮次。
