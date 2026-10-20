using Avalonia.Controls;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class PrivateKeysPage : FeaturePage
{
    internal readonly TextBox Index = Ui.Input("HEX 私钥或 Bitcoin 主网 WIF", "1");
    internal readonly ComboBox Count = Ui.Select(new[] { 1, 2, 5, 10, 20 }, 1, 100);
    internal readonly ComboBox BtcType = Ui.Select(new[] { "all", "legacy", "legacyUncompressed", "segwit", "nested", "taproot" }, "all", 180);
    internal readonly CoinPicker Coins = new("BTC", "ETH");
    internal readonly AddressResults Results;
    private readonly TextBlock _puzzleInfo = Ui.Text("", 12, Ui.Muted);
    private readonly Button _exitPuzzle;
    internal Puzzle? ActivePuzzle { get; private set; }
    internal KeyResult? Result { get; private set; }
    internal PrivateKeysPage(AppServices services) : base(services)
    {
        Results = new(services);
        _puzzleInfo.IsVisible = false;
        _exitPuzzle = Ui.Button("退出 Puzzle 范围", ExitPuzzle);
        _exitPuzzle.IsVisible = false;
        var navigation = Ui.Wrap(
            Ui.AsyncButton("首个", () => GenerateAsync("first")), Ui.AsyncButton("上一个", () => GenerateAsync("previous")),
            Ui.AsyncButton("安全随机", () => GenerateAsync("random")), Ui.AsyncButton("下一个", () => GenerateAsync("next")),
            Ui.AsyncButton("最后一个", () => GenerateAsync("last")), Ui.Button("取消", Cancel), Ui.AsyncButton("清空", ClearAsync));
        Layout("私钥库", "确定性密钥空间 · 七种主网 · 完全本地派生",
            Ui.Panel(Ui.Stack(Ui.Field("定位到 HEX / WIF", Index),
                Ui.Wrap(Ui.Field("每页私钥数量", Count), Ui.Field("BTC 地址类型", BtcType),
                    Ui.AsyncButton("生成地址", () => GenerateAsync(), true)), Coins.View, _puzzleInfo,
                _exitPuzzle)),
            navigation, Results);
        Index.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { e.Handled = true; await GenerateAsync(); } };
    }
    internal Task GenerateAsync(string operation = "current") => RunAsync(async token =>
    {
        Results.Cancel();
        var index = Ui.Value(Index);
        var coins = Coins.Selected;
        var count = (int)(Count.SelectedItem ?? 1);
        var puzzle = ActivePuzzle;
        var generated = await Services.Core.KeysAsync(index, coins, count, operation, puzzle == null ? Ui.Selected(BtcType) : "legacy", puzzle?.Id, token);
        token.ThrowIfCancellationRequested();
        Result = generated;
        Index.Text = generated.Index;
        Results.SetItems(generated.Items);
        Results.SetContext("派生结果", $"起始索引 0x{generated.Index} · {generated.Items.Length} 条地址" +
            (generated.WifCompressed is { } compressed ? $"\n已导入 WIF · {(compressed ? "压缩" : "未压缩")} · 按所选类型派生地址" : ""));
        Status.Text = $"索引 {generated.Index} · 输入 {generated.InputFormat ?? "HEX"}";
        if (puzzle != null) _puzzleInfo.Text = $"Puzzle #{puzzle.Id} · {puzzle.LowerBound} – {puzzle.UpperBound}" +
            (generated.Items.Any(i => i.Address == puzzle.Address) ? " · 与公开目标地址一致" : "");
        if (Services.Settings.Current.AutoRefresh) _ = Results.RefreshAsync(true);
    });
    internal async Task EnterPuzzleAsync(Puzzle puzzle, string operation)
    {
        ActivePuzzle = puzzle; Coins.Set("BTC"); Count.SelectedItem = 1; Index.Text = puzzle.LowerBound;
        _exitPuzzle.IsVisible = _puzzleInfo.IsVisible = true;
        BtcType.SelectedItem = "legacy";
        await GenerateAsync(operation);
    }
    internal void ExitPuzzle() { Cancel(); ActivePuzzle = null; _puzzleInfo.Text = ""; _puzzleInfo.IsVisible = _exitPuzzle.IsVisible = false; }
    internal async Task ClearAsync()
    {
        Cancel(); Results.SetItems([]); Result = null;
        Index.Text = ActivePuzzle?.LowerBound ?? "1"; Error.Text = ""; Status.Text = "已清空当前结果";
        await Services.Clipboard.ClearOwnedAsync();
    }
    internal override void Cancel() { base.Cancel(); Results?.Cancel(); }
}
