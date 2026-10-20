using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace AllKey.WindowsPoC;

// This process deliberately keeps one Go runtime loaded until exit.
internal static partial class NativeMethods
{
    private const string Library = "allkeycore";

    internal static void Load(string path)
    {
        var handle = NativeLibrary.Load(Path.GetFullPath(path));
        NativeLibrary.SetDllImportResolver(typeof(NativeMethods).Assembly,
            (string name, Assembly assembly, DllImportSearchPath? searchPath) =>
                name == Library ? handle : nint.Zero);
    }

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateKeys(string? request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateMnemonic(string? request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateMnemonicPage(string? request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyInspectMnemonic(string? request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCreateElectrum(string? request);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial nint AllKeyCalculate(string? request);

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = [typeof(CallConvCdecl)])]
    internal static partial void AllKeyFree(nint pointer);
}

internal sealed class CoreClient
{
    // Shared Go defaults are not assumed to be safe for parallel callers.
    private static readonly object Gate = new();
    internal long Allocations { get; private set; }
    internal long Releases { get; private set; }

    internal JsonElement Call(string operation, string? request)
    {
        if (request?.Contains('\0') == true)
            throw new ArgumentException("C ABI requests cannot contain literal NUL characters.");

        lock (Gate)
        {
            var pointer = operation switch
            {
                "keys" => NativeMethods.AllKeyCreateKeys(request),
                "mnemonic" => NativeMethods.AllKeyCreateMnemonic(request),
                "directory" => NativeMethods.AllKeyCreateMnemonicPage(request),
                "inspect" => NativeMethods.AllKeyInspectMnemonic(request),
                "electrum" => NativeMethods.AllKeyCreateElectrum(request),
                "calculate" => NativeMethods.AllKeyCalculate(request),
                _ => throw new ArgumentException("Unknown core operation.")
            };
            if (pointer == nint.Zero)
                throw new InvalidOperationException("Core returned a null response.");

            Allocations++;
            try
            {
                var json = Marshal.PtrToStringUTF8(pointer)
                    ?? throw new InvalidOperationException("Core returned no UTF-8 response.");
                using var document = JsonDocument.Parse(json);
                return document.RootElement.Clone();
            }
            finally
            {
                // Memory belongs to Go/C. Never use FreeHGlobal/FreeCoTaskMem here.
                NativeMethods.AllKeyFree(pointer);
                Releases++;
            }
        }
    }
}
