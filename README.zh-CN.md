# FlashPilot

**Agent 原生的 ECU 烧录——CAN、DoIP 和 LIN 上的 UDS，由声明式烧录计划驱动，为编码 agent 而生。**
FlashPilot 提供可自动化的烧录流程：免费 AGPL 引擎（无按次/按席位费用，CI 与 agent 自动化包含在内），官方验证发行版作为规划中的付费层——一个无常驻进程的 CLI、确定性 JSON、永不撒谎的退出码，以及让 agent 自我诊断的失败证据。

[![CI](https://github.com/turlamai/flashpilot/actions/workflows/ci.yml/badge.svg)](https://github.com/turlamai/flashpilot/actions/workflows/ci.yml) ![platform](https://img.shields.io/badge/platform-Windows_%7C_Linux_%7C_macOS-lightgrey) [![built with](https://img.shields.io/badge/built%20with-Racket-9F1D35)](https://racket-lang.org/) [![License](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[English](README.md) · **中文** · [用户手册](https://flashpilot.jrtx.site/guide.html)

## 开始使用

AGPL 引擎、CLI 和 MCP 保持免费，包含现行许可证允许的 CI 使用。规划有经验证的官方工程资产；付费版尚未开售。 桌面源码和预览路径面向 macOS、Windows、Linux。发布压缩包不表示所有适配器、ECU 和总线均已合格。

[安装、首次使用、隐私与备份恢复](docs/USER-GUIDE.zh-CN.md) · [English](docs/USER-GUIDE.md)

## 为什么做 FlashPilot？

今天的汽车烧录意味着 vFlash：昂贵的按席位授权、Windows GUI，以及 agent 无法驱动的 COM API 自动化。烧录知识本身——seed-key 算法、内存布局、时序——曾经是长期积累出来的护城河。AI 时代这条创作的成本坍塌了：agent 可以根据 OEM 规格书起草一份烧录计划。真正剩下的价值是**闭环**：生成计划 → 校验指纹 → 带电源/时序保护地烧录 → 失败时收集证据 → 重新生成。

FlashPilot 就是围绕这个闭环构建的。

- **声明式烧录计划** —— 每个 ECU 一份 JSON 文档：段（inline、BIN、Intel HEX、S-record）、会话、带可插拔 key provider 的 security access、erase/download/verify 流程、时序、恢复策略、电源保护、ECU 身份门、期望指纹。
- **真实传输层** —— SocketCAN（Linux）、PEAK PCAN（Windows）、DoIP（以太网）。**DoIP 已过真机在环验证**：在分段下载架构的参考 ECU 上经普通以太网连续两次复现完整闭环（擦除到复位后身份门）——证据报告见 issue #4。
- **Agent 优先的 CLI** —— 确定性 JSON 输出、永不撒谎的退出码，以及失败证据（有界、带指纹、可审计），让 agent 无需人类打开厂商工具就能诊断并重试。
- **默认安全** —— 计划在任何驱动调用之前校验期望指纹；编程中的电源保护在电流越界时中止；破坏性操作会明说。

不是 CANoe 克隆：没有整车网络仿真、没有 CAPL、没有分析窗口合集。只把一个闭环诚实地做完。

## 状态

**v0.2.0 —— 刷写驾驶舱**：v0.1.x 的全部底座（带 P2/P2\* 时序和 NRC 处理的 UDS、每步留审计的烧录工作流、声明式计划、指纹门、DTC、Intel HEX + S-record + BIN 模型、可插拔安全 provider、模拟 CAN 与 DoIP 上的 ISO-TP、内置模拟 ECU）之上补齐 vFlash 级能力面：ECU 身份门、刷写报告、轮询式擦除、通用例程步骤、复位后确认门、onFail 恢复执行、带可插拔电表 provider 的 powerGuard、DoIP 有界重连，以及三个桌面宿主的原生 Flash 按钮。

DoIP 已真机验证（见支持矩阵）。下一道门：硬件 LIN 适配器与计划库。

**已发布**：v0.2.0 交付 agent 优先 CLI 与三桌面宿主，覆盖 Windows x64、Linux x64/arm64 与 macOS arm64/x64——每平台 zip + SHA-256，另有汇总 SHA256SUMS，见 [Releases](https://github.com/turlamai/flashpilot/releases/latest)。双语用户手册：<https://flashpilot.jrtx.site/guide.html>。
