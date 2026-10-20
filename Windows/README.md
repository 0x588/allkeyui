# AllKeyUI for Windows

基于 Avalonia 12.1.4 / .NET 10，使用仓库内相同的 Go 密码学核心，无 WebView。
[English](../README.md) | [简体中文](../README.zh-CN.md) · [下载 / Downloads](https://github.com/0x588/allkeyui/releases/latest)

构建说明与功能概览见项目 README，验收记录见 [Windows 验证](VALIDATION.md)。

## 使用

选择与系统架构匹配的完整发布目录：Intel/AMD Windows 使用 `win-x64`，ARM64 Windows 使用 `win-arm64`。
解压后运行 `AllKeyUI.exe`；无需安装 Go 或 .NET SDK。请保留应用目录中的 DLL、JSON 数据与其他运行文件。
当前交付为未签名便携版；正式安装器与代码签名在发布阶段处理。

私钥库、BIP39、Electrum、Puzzle 与计算器均在本机计算。余额查询需要在设置中配置服务，只有公开地址会发给服务商。 BTC Puzzle 页面加载后自动查询公开目录余额并逐步更新，复用 60 秒缓存，详情可手动强制刷新。
结果列表参考 macOS 版，逐行展示公开地址、私钥与扩展密钥，提供对应的复制操作；余额在宽窗口右侧、窄窗口下方显示。
BIP39 提供“单组派生 / 多组目录 / 查找助记词”三种模式；常用选项自动刷新，高级参数修改后显示待应用状态。
离开助记词页面会清除助记词、Passphrase、目标地址、派生结果和输入撤销历史。功能概览见项目 README。
设置位于 `%LOCALAPPDATA%\AllKeyUI\balance-settings.json`，API Key 保存在该用户配置中。
敏感内容复制后 60 秒，仅在剪贴板仍是该内容时清除；退出和手动清空同样检查所有权。

## 构建

macOS / Linux，需要 .NET 10 SDK、Go 与 MinGW-w64：

```bash
bash scripts/build_windows_app.sh
WINDOWS_ARCH=arm64 WINDOWS_CC=/path/to/aarch64-w64-mingw32-clang bash scripts/build_windows_app.sh
```

Windows，需要 .NET 10 SDK、Go 和对应架构 C 编译器：

```powershell
& .\scripts\build_windows_app.ps1
& .\scripts\build_windows_app.ps1 -Architecture arm64 -CCompiler 'C:\llvm-mingw\bin\aarch64-w64-mingw32-clang.exe'
```

输出位于仓库 `.build/windows-app/win-x64` 或 `win-arm64`。

## 验证入口

```powershell
# 核心、配置与余额协议测试；余额响应由本地测试桩提供，不访问服务商：
.\AllKeyUI.exe --verify-core --report "$PWD\core-verification.json"
# 可见窗口内的模块与剪贴板冒烟测试，使用独立测试配置目录和公开向量：
.\AllKeyUI.exe --ui-smoke --data-dir "$env:TEMP\allkey-ui-check" --report "$PWD\ui-verification.json"
```

UI 测试会切换页面并使用剪贴板，请在不进行其他桌面操作时运行。`--exit-after-smoke` 可在测试结束后关闭窗口。
测试程序只使用公开测试向量；余额网络测试不上传任何真实钱包数据。
