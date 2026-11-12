# AGENTS.md

## 实现路由（agent 按任务读真源）

- 实现界面以 `design/prototype/` 为准：对照 HTML/CSS/JS 与实物截图验收，不依赖散文复述。
- Token/几何值真源 = `design/prototype/shared.css`（亮暗成对；无 shared.css 的仓 = design/prototype/ 各页样式）；`design/DESIGN.md` 只记语义名、用途与决策。
- 行为边界与跨平台一致性以 `design/DESIGN.md` 的不变式与平台差异节为准。
- 改界面先改原型再改实现（tlai-prototype-flow）；动共享层（design/、shared/）先 issue 声明，同 commit 落契约。

## Authorization decision before implementation

Decision `2026-10-auth-1`: Offline perpetual entitlement plus a bounded update/feature window; no activation lease or device cap. Read the complete [local authorization decision](PRICING.md#authorization-decision-for-implementation) and its Chinese counterpart before commercial, trial, update-eligibility or credential work. Record this decision revision and the source/policy SHAs actually read in the PR/handoff. Refresh at each bounded slice; existing agent conversations do not receive this change automatically. Follow the existing product contract and implementation issue; do not activate a payment gate merely because a plan exists.

FlashPilot——agent 原生的 ECU 烧录工具（UDS over CAN/DoIP/LIN，声明式 flash plan，确定性 JSON 与退出码），Racket 引擎 + Rivet 线原生壳。

## 结构

- `racket/` — Racket 引擎（`racket/flashpilot` collection，flash 核心/plan 模型）
- `app/` — 宿主入口（`backend.rkt` 引擎 RPC、`cli.rkt` 命令行）
- `macos-host/`、`windows/`、`linux/` — Rivet 三宿主腿（对应平台机器独占开发，验证跨腿走 CI）
- `site/` + `docs/` — 产品站（GitHub Pages）与用户手册
- `examples/` — flash plan 示例；`assets/`、`dist/`、`packaging` 产物相关

## 常用命令

```bash
# 引擎与入口（CI 同款）
raco pkg install --auto --name flashpilot --link racket
raco pkg install --auto --no-docs 'https://github.com/turlamai/rivet.git#b9811930fcda0893cf5de40a41f4a25d539b958e'
raco make app/backend.rkt
raco make app/cli.rkt
raco test racket/flashpilot
raco rivet acceptance
```

## 验证与发版

- CI（`ci.yml`）：多平台 matrix 装 rivet pin → raco make 入口 → raco test 引擎。
- 产品验收（`acceptance.yml`）：三平台构建并打包原生 GUI，以系统无障碍接口点击“Validate bench”，验证 RVT1、模拟 ECU 与原生结果展示的完整链路。
- 站点（`pages.yml`）：`docs/guide.html` 拷入 `site/` 后部署 GitHub Pages。
- 发版（`release.yml`）：tag `v*` 触发多平台产物构建；CHANGELOG 按 Keep a Changelog 格式随发版更新。发版前产物必须本机实测（家族教训）。

## 仓库特定规矩

- rivet 以固定提交消费，禁止漂移到 tag/main；升级 pin 须同时更新 CI、验收和本文件，并通过三平台打包交互。
- 不得以 Racket/CLI 测试替代 GUI 交付证明；Windows、macOS、Linux 宿主都必须由 `raco rivet acceptance` 实际构建、打包并操作。
- BenchPilot（ECU 试验台运行时）已于 2026-10-17 删除，其历史 issue/PR 与本产品无关，勿混淆。
- 站点 `site/` 为生成+手维护混合，改 guide 先改 `docs/` 再按 pages.yml 流程同步。

## 组合定位（Portfolio placement）

- 当前决策（2026-10-v2）：免费引擎 + 已验证工程发行版买断。具体价格、免费/付费边界和开卖门禁以本仓 [PRICING.md](PRICING.md) 为唯一权威；旧版收费候选与早鸟方案已被替代。
- 组合归属：[PORTFOLIO](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)。当前全部产品开发中、没有实际用户；目标定价不表示已经开卖，不因此立即给开发版加收费墙。
- 免费产品不接商业激活；付费层先实现可验证价值，再接 Commerce/Permit。优先完成本仓既有产品审查 issue；不修改现行源码 LICENSE。

## 产品交付与下一步（2026-10-23）

- 家族[交付标准](https://github.com/turlamai/turlamai.github.io/blob/master/docs/PRODUCT-STANDARD.md)与[组合策略](https://github.com/turlamai/turlamai.github.io/blob/master/PORTFOLIO.md)是共用政策；本仓具体行为以 `README.md` 为准，不复制五库依赖图。
- 当前执行入口：[产品审查 issue](https://github.com/turlamai/flashpilot/issues/4)。先完成模拟/真实硬件的支持与证据矩阵，再补官方安装更新路径。模拟 ECU 验收不能替代硬件在环资格。
- 开工先检查干净工作树与远端，以 fast-forward-only 更新并记录 SHA；共享文件一次一个写入者，保留其他 checkout 的未提交工作。
- 每次只完成一个可验收切片，记录 owned files、依赖 pin、命令/平台/产物证据和回滚。已实现、已发布、实机验收分别陈述；不修改 requirements 或复用旧证据来制造通过。

## Documentation languages

Public default documentation is English; maintain complete Chinese user paths in `*.zh-CN.md`, with reciprocal links. Update both languages when prices, quotas, installation, recovery, privacy or supported platforms change. API/protocol identifiers and commands remain unchanged; do not maintain a second normative protocol or implementation. Follow the [family language policy](https://github.com/turlamai/turlamai.github.io/blob/master/docs/DOCUMENTATION-LANGUAGES.md). Existing internal notes are not a claim that every document is bilingual.

## Public product documentation

The paired `docs/USER-GUIDE.md` / `docs/USER-GUIDE.zh-CN.md` own the public installation, first-use, data/recovery, privacy and availability path. Keep the homepage and both README entry points aligned with them when behavior changes. Detailed technical contracts and the current implementation queue retain their existing owners. Do not publish target prices, a purchase link or a ready/secure/platform claim before its release evidence exists.

## 设计流程（原型先行）

所有 UI 开发与界面改造一律先原型后代码：brief → `design/DESIGN.md`
视觉契约 → HTML 原型 → 按 HIG 基准评审通过才开工；改界面先改原型再改
代码。契约与原型放本仓 `design/`（尚未建立时随首个 UI 切片建立），
实物截图验收后才能作为对外宣传素材。
