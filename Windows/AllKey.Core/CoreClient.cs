using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace AllKey.Core;

internal static partial class NativeMethods
{
    private const string Library = "allkeycore";
    private static readonly object LoadGate = new();
    private static bool _loaded;
    internal static void EnsureLoaded()
    {
        lock (LoadGate)
        {
            if (_loaded) return;
            var filename = OperatingSystem.IsWindows() ? "allkeycore.dll" : OperatingSystem.IsMacOS() ? "liballkeycore.dylib" : "liballkeycore.so";
            var handle = NativeLibrary.Load(System.IO.Path.Combine(AppContext.BaseDirectory, filename));
            NativeLibrary.SetDllImportResolver(typeof(NativeMethods).Assembly, (name, _, _) => name == Library ? handle : nint.Zero);
            _loaded = true;
        }
    }
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateKeys(string request);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateMnemonic(string request);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateMnemonicPage(string request);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyInspectMnemonic(string request);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateElectrum(string request);
    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCalculate(string request);
    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void AllKeyFree(nint pointer);
}

public sealed class CoreClient
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    public async Task<T> CallAsync<T>(string operation, object request, CancellationToken cancellationToken = default)
    {
        var raw = JsonSerializer.Serialize(request, CoreJson.Options);
        await Gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                NativeMethods.EnsureLoaded();
                var pointer = operation switch
                {
                    "keys" => NativeMethods.AllKeyCreateKeys(raw),
                    "mnemonic" => NativeMethods.AllKeyCreateMnemonic(raw),
                    "directory" => NativeMethods.AllKeyCreateMnemonicPage(raw),
                    "inspect" => NativeMethods.AllKeyInspectMnemonic(raw),
                    "electrum" => NativeMethods.AllKeyCreateElectrum(raw),
                    "calculate" => NativeMethods.AllKeyCalculate(raw),
                    _ => throw new ArgumentException("未知核心操作")
                };
                if (pointer == nint.Zero) throw new CoreException("bridge_error", "本机计算核心未返回结果");
                try
                {
                    var json = Marshal.PtrToStringUTF8(pointer) ?? throw new CoreException("bridge_error", "计算结果编码无效");
                    using var response = JsonDocument.Parse(json);
                    var root = response.RootElement;
                    if (!root.GetProperty("ok").GetBoolean())
                    {
                        var error = root.GetProperty("error");
                        throw new CoreException(error.GetProperty("code").GetString() ?? "core_error", error.GetProperty("message").GetString() ?? "计算失败");
                    }
                    cancellationToken.ThrowIfCancellationRequested();
                    return root.GetProperty("data").Deserialize<T>(CoreJson.Options)
                        ?? throw new CoreException("bridge_error", "计算结果为空");
                }
                finally { NativeMethods.AllKeyFree(pointer); }
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { Gate.Release(); }
    }

    public Task<KeyResult> KeysAsync(string index, string[] coins, int count = 1, string op = "current", string btcType = "all", int? puzzleNumber = null, CancellationToken cancellationToken = default)
        => CallAsync<KeyResult>("keys", new { index, coins, count, op, btcType, puzzleNumber }, cancellationToken);
    public Task<MnemonicResult> ElectrumAsync(string index, int count, string addressType, string op, CancellationToken cancellationToken = default)
        => CallAsync<MnemonicResult>("electrum", new { index, count, addressType, op }, cancellationToken);
    public Task<MnemonicInspection> InspectAsync(string text, int bitSize, int? completionPosition = null, CancellationToken cancellationToken = default)
        => CallAsync<MnemonicInspection>("inspect", new { text, bitSize, completionPosition }, cancellationToken);
    public async Task<MnemonicResult> MnemonicAsync(MnemonicRequest request, Action<int>? progress = null, CancellationToken cancellationToken = default)
    {
        var scanned = 0;
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var result = await CallAsync<MnemonicResult>("mnemonic", request, cancellationToken).ConfigureAwait(false);
            if (string.IsNullOrEmpty(result.SearchCursor)) return result;
            scanned += 4096;
            progress?.Invoke(scanned);
            request = request with { Cursor = result.SearchCursor };
        }
    }
    public Task<MnemonicPageResult> DirectoryAsync(int bitSize, int pageSize, string[] coins, string index, string op, string btcType, CancellationToken cancellationToken = default)
        => CallAsync<MnemonicPageResult>("directory", new { bitSize, pageSize, coins, index, op, btcType }, cancellationToken);
    public async Task<string> CalculateAsync(string operation, string input, string passphrase = "", bool compressed = true, CancellationToken cancellationToken = default)
        => (await CallAsync<CalculatorOutput>("calculate", new { operation, input, passphrase, compressed }, cancellationToken).ConfigureAwait(false)).Output;
}
