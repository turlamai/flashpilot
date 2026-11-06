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
| `planned` | Named so nobody guesses: not implemented. 明示未实现，避免猜测。 |

A `hardware-in-loop verified` level will be added only with a versioned
adapter + reference-ECU reproduction report (the issue #4 gate). Simulated
evidence never claims production flashing reliability.
只有附上版本化适配器 + 参考 ECU 复现报告（issue #4 门禁）才会新增
`hardware-in-loop verified` 级别。仿真证据永不宣称生产刷写可靠性。

## Matrix / 矩阵（generated shape, see `flashpilot transports --json`）

| Transport | Platform | Evidence |
| --- | --- | --- |
| socketcan | Linux | implemented-unverified |
| socketcan-fd | Linux | ci-simulated |
| pcan | Windows | implemented-unverified |
| pcan-fd | Windows | planned |
| doip | cross-platform | implemented-unverified |
| lin-simulated | cross-platform | ci-simulated |
| lin-hardware | adapter-dependent | planned |

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

**Reserved plan fields / 计划中的保留字段** — `onFail` is now enforced:
`retry` replays the whole transaction once on a non-permanent failure,
and `resetAndRetry` adds a best-effort hard EcuReset before the replay;
the identity gate never replays (a wrong target is not touched twice).
`powerGuard` remains parsed-but-not-yet-enforced — it needs a real
bench-supply provider interface and ships as its own slice.
**已执行字段**：`onFail` 现已生效——`retry` 在非永久性失败后整事务重放
一次，`resetAndRetry` 在重放前追加尽力硬复位；身份门失败永不重放（错
误目标不被触碰第二次）。`powerGuard` 仍是解析未执行——它需要真实的
台架电源 provider 接口，作为独立切片交付。

## ODX import honesty / ODX 导入的如实边界

`flashpilot odx-import` converts the flash subset (MEMORY-SEGMENT
ranges, inline base64 DATA, DATAFILE references). Everything outside
the subset is returned in `issues` — unconverted, never dropped. CDD
and VFD are out of scope by design.
`flashpilot odx-import` 只转换烧录子集（MEMORY-SEGMENT 区间、内联
base64 DATA、DATAFILE 引用）；子集之外一律进入 `issues`——未转换但
绝不丢弃。CDD 与 VFD 设计上不支持。
