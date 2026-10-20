using System.Diagnostics;
using Avalonia.Controls;
using AllKey.Core;

namespace AllKey.Desktop;

public sealed class AppServices(SettingsStore settings) : IDisposable
{
    public SettingsStore Settings { get; } = settings;
    public CoreClient Core { get; } = new();
    public BalanceClient Balances { get; } = new(settings);
    public ClipboardService Clipboard { get; } = new();
    public Action<Puzzle, string>? OpenPuzzle { get; set; }
    public Action<string>? OpenMnemonic { get; set; }
    public void Dispose() { Balances.Dispose(); Clipboard.Dispose(); }
    public static void OpenUrl(string url)
    {
        if (!Providers.IsHttps(url)) throw new InvalidDataException("浏览器地址必须使用 HTTPS");
        Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    }
}

public sealed class ClipboardService : IDisposable
{
    private CancellationTokenSource? _timer;
    private string? _owned;
    private TopLevel? _owner;
    public async Task CopyAsync(TopLevel? owner, string value, bool sensitive = true)
    {
        var clipboard = owner?.Clipboard ?? throw new InvalidOperationException("剪贴板不可用");
        _timer?.Cancel();
        await clipboard.SetTextAsync(value);
        _owned = sensitive ? value : null;
        _owner = owner;
        if (!sensitive) return;
        var timer = new CancellationTokenSource();
        _timer = timer;
        _ = ClearLaterAsync(timer.Token);
    }
    private async Task ClearLaterAsync(CancellationToken token)
    {
        try { await Task.Delay(TimeSpan.FromSeconds(60), token); await ClearOwnedAsync(); }
        catch (OperationCanceledException) { }
        catch { /* Clipboard ownership may move to another application or session. */ }
    }
    public async Task ClearOwnedAsync()
    {
        _timer?.Cancel();
        var value = _owned;
        var clipboard = _owner?.Clipboard;
        _owned = null;
        if (value != null && clipboard != null && await clipboard.TryGetTextAsync() == value) await clipboard.ClearAsync();
    }
    public void Dispose() { _timer?.Cancel(); _timer?.Dispose(); _owned = null; }
}
