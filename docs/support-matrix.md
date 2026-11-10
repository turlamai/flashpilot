# Support matrix & recovery semantics

**English** · 简体中文（同文下半）

The authoritative matrix lives in code: `racket/flashpilot/diagnostics/support-matrix.rkt`,
surfaced by `flashpilot transports --json`. This document explains the
labels and the recovery contract; it cannot drift from the CLI output
without a failing test.

支持矩阵的权威载体是代码：`racket/flashpilot/diagnostics/support-matrix.rkt`，
经 `flashpilot transports --json` 输出。本文解释标签含义与恢复合约；若与
CLI 输出漂移，测试会失败。

## Evidence levels / 证据级别

| Level / 级别 | Meaning / 含义 |
| --- | --- |
| `ci-simulated` | The complete loop (session → security → erase → download → verify → reset) runs against the simulated ECU in CI on every push. 完整闭环在每次推送的 CI 中对仿真 ECU 运行。 |
| `implemented-unverified` | Code ships and is unit-tested where possible, but no physical adapter + reference ECU has reproduced it. 代码随源发布并尽可能单测，但尚无实体适配器 + 参考 ECU 的复现报告。 |
| `hardware-in-loop verified` | A versioned adapter + reference-ECU reproduction report exists (the issue #4 gate). The claim is scoped to that adapter/ECU class, never to arbitrary ECUs. 已有版本化适配器 + 参考 ECU 复现报告（issue #4 门禁）；宣称仅限该适配器/ECU 类别，绝不外推到任意 ECU。 |
| `planned` | Named so nobody guesses: not implemented. 明示未实现，避免猜测。 |

Simulated evidence never claims production flashing reliability. The
`hardware-in-loop verified` level is added only with a versioned
adapter + reference-ECU reproduction report; vendor identity stays
redacted in public reports.
仿真证据永不宣称生产刷写可靠性。`hardware-in-loop verified` 仅随版本化
适配器 + 参考 ECU 复现报告新增；公开报告中厂商身份一律脱敏。

## Matrix / 矩阵（generated shape, see `flashpilot transports --json`）

| Transport | Platform | Evidence |
| --- | --- | --- |
| socketcan | Linux | implemented-unverified |
| socketcan-fd | Linux | ci-simulated |
| pcan | Windows | implemented-unverified |
| pcan-fd | Windows | planned |
| doip | cross-platform | hardware-in-loop verified |
| lin-simulated | cross-platform | ci-simulated |
| lin-hardware | adapter-dependent | planned |

**DoIP hardware-in-loop evidence / DoIP 真机证据** — engine `f14d1af`
(2026-11): the complete cycle — diagnostic session, security access,
precheck routine, sliced erase (110+ in-progress rounds), 538-block
download, verify routine, activate routine, EcuReset, post-reset
identity gate — reproduced twice consecutively on a vendor-confidential
reference ECU over plain Ethernet (DoIP TCP), Windows host. Three
engine gaps found on hardware were fixed in the same change: guarded
RequestDownload block-length adoption, 1..255 sequence wrap, and
section-bounded chunking (`chunkSplitOffsets` — the ECU rejects blocks
that straddle a section boundary with a positive-but-empty ACK and the
session wedges). Full report: issue #4.
引擎 `f14d1af`（2026-11）：完整闭环——诊断会话、安全访问、预检例程、
切片擦除（110+ 轮进行中）、538 块下载、校验例程、激活例程、EcuReset、
复位后身份门——在厂商保密的参考 ECU 上经普通以太网（DoIP TCP）、
Windows 宿主连续复现两次。同一变更内修复三个真机暴露的引擎缺口：有
守卫的 RequestDownload 块长采纳、1..255 序号回绕、段边界封顶切块
（`chunkSplitOffsets`——该 ECU 以 positive 空回显拒绝跨段块并楔死会
话）。完整报告见 issue #4。

## Recovery semantics / 恢复语义

**Block retry（块重试）** — A failed `0x36 TransferData` is retried in
place at most `blockRetries` times, at the same offset with the same
block counter. It never re-erases and never restarts the download from
zero. 对失败的 `0x36` 在原偏移、原块计数器上重试，至多 `blockRetries`
次；不会重新擦除，也不会从头重下。

**Power loss / 断电** — Power loss mid-flash is an ECU boot-loader
situation. The tool's contract on re-run: the plan's
`expectedFingerprint` gate re-validates the image before any driver
call, and a fresh run starts from erase. No state is carried across
runs; nothing resumes blindly. 刷写中断电属于 ECU 引导程序场景。重跑
合约：计划的 `expectedFingerprint` 在任何驱动调用前重新校验镜像，新
一轮从擦除开始；跨运行不携带状态，也不盲目续传。

**DoIP reconnect / DoIP 重连** — With `--reconnect N`, connection-class
errors (link dropped, peer refused) re-establish the TCP link and routing
activation within N bounded rounds before surfacing; UDS-level failures
are never retried here. This is what lets the post-reset confirmation
gate poll across an ECU's reboot window. With reconnect disabled the
error surfaces untouched.
**DoIP 重连** — 使用 `--reconnect N` 时，连接类错误（链路断开、对端拒
绝）会在 N 轮有界重试内重建 TCP 链路与路由激活；UDS 层失败绝不在此层
重试。这正是复位后确认门能跨过 ECU 重启窗口持续轮询的原因。禁用重连时
错误原样上抛。
**Session loss / 会话失效** — An expired programming session surfaces as
a negative response (typically `0x7F`/`conditionsNotCorrect`) with the
failing step named in the evidence; the run stops instead of guessing.
会话过期以负响应呈现（通常 `0x7F`/`conditionsNotCorrect`），失败证据
指明卡在哪个步骤；运行停止而不是猜。

**Dangerous steps / 危险步骤** — Erase and download are never retried
automatically. The only automatic retry is the bounded block retry
above; everything else stops with structured evidence (step name, NRC
name, bounded and fingerprinted failure output). 擦除与下载永不自动重
试；唯一的自动重试是上述有界块重试，其余一律以结构化证据（步骤名、
NRC 名、有界且带指纹的失败输出）停止。

**Reserved plan fields / 计划中的保留字段** — both are enforced now.
`onFail`: `retry` replays the whole transaction once on a non-permanent
failure, `resetAndRetry` adds a best-effort hard EcuReset first; the
identity gate never replays (a wrong target is not touched twice).
`powerGuard`: the engine polls the configured meter provider
(`sim` constant or an external `command:` script reporting live mA)
through erase and download; out-of-band current aborts permanently — a
physical safety event is never blindly retried, and a plan without a
provider does not enforce (no silent fake meters).
**已执行字段**：两个都已生效。`onFail`——`retry` 在非永久性失败后整事
务重放一次，`resetAndRetry` 先尽力硬复位；身份门失败永不重放（错误目
标不被触碰第二次）。`powerGuard`——引擎在擦除与下载期间轮询所配
provider（`sim` 常量或外接 `command:` 脚本回读实时 mA）；电流越界永久
中止——物理安全事件绝不盲目重试；未配 provider 的计划不执行（杜绝静
默假表）。

## ODX import honesty / ODX 导入的如实边界

`flashpilot odx-import` converts the flash subset (MEMORY-SEGMENT
ranges, inline base64 DATA, DATAFILE references). Everything outside
the subset is returned in `issues` — unconverted, never dropped. CDD
and VFD are out of scope by design.
`flashpilot odx-import` 只转换烧录子集（MEMORY-SEGMENT 区间、内联
base64 DATA、DATAFILE 引用）；子集之外一律进入 `issues`——未转换但
绝不丢弃。CDD 与 VFD 设计上不支持。
