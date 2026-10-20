# Windows 移植核心验证记录

日期：2026-10-19。

结论：**现有 Go 核心可以通过 C ABI 在 C# 中复用，原生 x64 与 ARM64 Windows 调用链均已验证通过。**
x64 已在远程 Intel 主机的 Windows 10 企业版上完成实际运行验证；ARM64 已在本机 Windows 11 虚拟机验证。
本阶段只验证底层调用链，尚未验证 Avalonia 控件、窗口与输入法。

## 环境

| 项目 | 实际环境 |
|---|---|
| 宿主机 | macOS，Apple Silicon / ARM64 |
| Go | go1.27.1 darwin/arm64 |
| .NET SDK | 10.0.402，目标框架 net10.0 |
| x64 C 编译器 | MinGW-w64 GCC 16.2.0 |
| ARM64 C 编译器 | LLVM-MinGW 20261006 / Clang 23.1.3 |
| Windows | Parallels 中的 Windows 11 ARM64，版本 10.0.22000.2538 |
| 硬件架构核对 | Win32_Processor.Architecture = 12（ARM64） |
| 远程 x64 Windows | Windows 10 企业版，版本 10.0.19045 |
| 远程 x64 CPU | Intel Xeon E5-2680 v4 @ 2.40GHz，Architecture = 9，验证进程 X64 |

注意：Windows 11 的系统版本 API 仍可返回 `10.0.22000`；x64 仿真中的部分架构 API 返回 X64，
因此不能仅用验证程序的进程架构判断虚拟机的硬件架构。

## 验证范围与结果

| 检查 | 结果 |
|---|---|
| 原有 Go 单元测试，`go test -count=1 ./...` | 通过，未使用结果缓存 |
| Windows x64 Go DLL 交叉编译 | 通过，PE32+ x86-64 |
| Windows ARM64 Go DLL 交叉编译 | 通过，PE32+ AArch64 |
| Windows DLL 六个业务入口与 AllKeyFree | 两种架构调用均覆盖全部入口 |
| C# Release 编译 | 通过，0 警告、0 错误 |
| macOS ARM64：相同 C# 桥接与宿主共享库 | 16 组向量 + 10000 次重复调用通过 |
| Windows ARM64：C# → Go DLL | 16 组向量 + 10000 次重复调用通过 |
| Windows ARM64：响应接收/释放调用 | 10016 / 10016，计数一致 |
| Windows ARM64：独立启动稳定性 | 另测 10 次独立启动，每次 16 组向量 + 10000 次重复调用 |
| Intel Windows：原生 x64 运行 | 11 次独立进程全部通过，每次 16 组向量 + 10000 次重复调用 |
| Intel Windows：原生 x64 接收/释放 | 每次 10016 / 10016；11 次合计 110176 / 110176 |
| ARM64 Windows：x64 仿真运行 | 首次核心调用时退出，退出码 -1073740791 / 0xC0000409 |

固定向量包括 ETH/BTC 地址、WIF、BIP39、BIP84/BIP86、256 位索引；另覆盖助记词目录、词表补全、
Electrum 创建、SHA256、中文 UTF-8、换行、结构化错误、畸形 JSON 与空请求指针。
Electrum 为结果形状验证。测试过程中未使用真实用户私钥，也不查询余额或外部网络。

重复调用与释放计数不构成完整泄漏检测，不证明私钥内存已清零，运行时长也不作为性能基准。
原有 Go 测试/共享库构建存在 macOS 最低链接版本提示，未影响本次通过结果。

## 远程 x64 验证证据

远程测试使用包含 .NET 运行时的原始 x64 发布包，传输后验证 SHA256：

```text
360688f509d4196aed083158edd5efbcc847957b5db15b7823ffaa1f92e89193
```

执行一次完整验证，再执行 10 次独立进程启动。每次进程有 60 秒超时限制；实际 11 次退出码均为 0，
每次结果均为 `passed`，16 组向量、10000 次重复调用和 10016 次释放断言全部通过。
报告由远程主机生成并传回本机，已核对全部 11 份结果，而非仅根据终端成功提示判断。
原始结果见 [evidence/remote-x64-2026-10-19.json](evidence/remote-x64-2026-10-19.json)。

测试文件保存在远程用户目录的 `AppData\Local\AllKeyUI\Validation` 下。
远程 360 对启动 PowerShell 的命令弹出拦截提示，用户允许本次运行后完成验证；未修改全局防护配置。
验证所用临时传输服务已关闭。该测试没有安装 SDK，也没有修改应用业务源码。

## x64 仿真失败的判断

相同 x64 包在共享目录和 Windows 本地临时目录执行均失败，因此并非仅由共享目录加载引起。
另用 LLVM-MinGW 重建 x64 DLL 后，在该仿真环境中仍出现相同退出码。
Go 官方存在 [#60996](https://github.com/golang/go/issues/60996)，记录 ARM64 Windows 下加载 amd64 Go 共享库，
与 Control Flow Guard 交互时的启动崩溃或挂起。当前现象与其相似，**尚未证明是同一个根因**。
本次没有关闭系统安全机制，也没有把关闭 CFG 作为交付方案。

据此，发布应提供与系统匹配的 x64 / ARM64 包。本次 Intel x64 成功结果说明 x64 调用链可用，
但不代表旧版 ARM64 Windows 上的 x64 仿真问题已经解决；原生 x64 Windows 11 和其他硬件组合尚未覆盖。

## 交付与下一步

- `CoreClient.cs`：source-generated P/Invoke，UTF-8 请求与响应，`finally` 释放，核心串行调度。
- `vectors.json`、`Program.cs`：可重复执行的跨平台验证程序，失败返回非零退出码。
- `../scripts/verify_windows_poc.sh`、`../scripts/verify_windows_poc.ps1`：构建与打包。
- `../scripts/verify_windows_remote.ps1`：传输校验、核对 x64 CPU、受控进程执行与远程报告回传。
- `.build/windows-poc/win-arm64`：包含 .NET 运行时的 ARM64 Windows 包。
- `.build/windows-poc/win-x64`：包含 .NET 运行时的 x64 Windows 验证包。
- `.build/windows-poc/host-verification.log`、各包中的 `windows-verification.log`：本次执行日志。

本次未修改 SwiftUI、Go 业务源码或 Xcode 工程。可沿用该桥接方式开始 Avalonia 私钥页的纵向验证。
余额服务、输入补全 UI、任务取消和剪贴板仍属于后续迁移工作。
