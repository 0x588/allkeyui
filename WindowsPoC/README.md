# Windows 核心桥接验证

这是 Avalonia/WPF 界面之前的独立验证工程，无 UI、无额外 NuGet 包，也不修改 macOS 的调用链。

验证路径：C# → source-generated P/Invoke → UTF-8 JSON/C ABI → Go 共享库 → C# JSON 解析。
所有示例均为公开测试向量，不输入真实私钥。Go 库按进程生命周期持有，核心调用统一串行调度。

## 在 Windows 上直接验证

按系统架构选择完整的发布文件夹：Intel/AMD Windows 使用 `.build/windows-poc/win-x64`，
ARM64 Windows 使用 `.build/windows-poc/win-arm64`。
这是包含 .NET 运行时的发布目录，接收机器无需安装 .NET SDK、Go 或 C 编译器。
在文件夹内打开 PowerShell：

```powershell
& .\Run-Validation.ps1
```

如果本机策略不允许运行脚本，也可以直接执行：

```powershell
.\AllKey.WindowsPoC.exe "$PWD\allkeycore.dll" 10000
```

脚本把报告写入同目录 `windows-verification.log`，任意断言失败会返回失败。
成功条件：16 组向量通过，10000 次重复调用通过，收到和释放的响应数量一致。
目录应放在可写位置。当前原生 x64 Windows（远程 Intel 主机）和 ARM64 Windows 均已实测通过；
x64 在本机旧版 ARM64 Windows 的仿真环境中失败。请在 ARM64 Windows 上使用 ARM64 包。
详细环境与结果见源码目录中的 [VALIDATION.md](VALIDATION.md)。

## 从 macOS / Linux 重建

需要 Go、.NET 10 SDK，以及 Windows x64 MinGW-w64 C 编译器：

```bash
bash scripts/verify_windows_poc.sh
# 构建原生 ARM64 Windows 包，需要 LLVM-MinGW：
WINDOWS_ARCH=arm64 WINDOWS_CC=/path/to/aarch64-w64-mingw32-clang bash scripts/verify_windows_poc.sh
```

脚本也会查找 `.build/toolchains/dotnet/dotnet`，或者通过 `DOTNET_BINARY` 指定 SDK。
可使用 `WINDOWS_CC` 指定 Windows 交叉编译器。输出全部放在 `.build/windows-poc`。
构建时会从 NuGet 下载 Windows .NET 运行时包；验证程序本身不访问网络。
在宿主机执行相同的 C# 测试有助于发现桥接问题，但不能替代 Windows DLL 加载和执行验证。

## 从 Windows 重建

需要 .NET 10 SDK、Go，以及可在 PATH 找到的 Windows x64 MinGW-w64 GCC：

```powershell
& .\scripts\verify_windows_poc.ps1
# 非默认 C 编译器：
& .\scripts\verify_windows_poc.ps1 -CCompiler 'C:\toolchain\bin\gcc.exe'
# 原生 ARM64 Windows，使用 LLVM-MinGW：
& .\scripts\verify_windows_poc.ps1 -Architecture arm64 -CCompiler 'C:\llvm-mingw\bin\aarch64-w64-mingw32-clang.exe'
```

## 覆盖与边界

- 六个业务入口，以及 `AllKeyFree`。
- ETH/BTC 固定地址、WIF 归一化、分页、BIP39、BIP84/BIP86、256 位索引字符串。
- 助记词目录、词表补全、Electrum Standard、SHA256。
- 实际中文 UTF-8 请求/响应、空白和换行保留、中文错误、畸形 JSON、空指针请求。
- 重复调用，每个非空返回指针在 `finally` 中交回 `AllKeyFree`。

释放计数只证明调用路径成对执行，不是完整的内存泄漏检测，也不证明密码学敏感内存已清零。
Electrum 当前用创建结果形状进行冒烟验证，其余部分包含固定输出断言。
尚不覆盖 Avalonia UI、余额网络服务、剪贴板、输入法、任务取消、安装签名或性能基准。

## 远程验证

`scripts/verify_windows_remote.ps1` 接收专用临时传输地址和预期包 SHA256，检查远程 CPU 为 x64，
下载并核对包后运行一次完整验证和默认 10 次独立启动；每个进程最多运行 60 秒。
脚本将原始输出、退出码、断言摘要和平台信息保存到用户目录，并回传至同一临时服务。
`BaseUri` 下需提供 `bundle.zip` 下载端点和 `report` POST 端点，不要将其指向未经确认的服务。
本次远程执行结果见 [验证记录](VALIDATION.md#远程-x64-验证证据)。

实现依据：[.NET 原生互操作指南](https://learn.microsoft.com/en-us/dotnet/standard/native-interop/best-practices)、
[Go 构建模式](https://pkg.go.dev/cmd/go#hdr-Build_modes)。
