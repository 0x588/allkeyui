using Avalonia.Controls;
using Avalonia.Media;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class ElectrumPage : FeaturePage
{
    internal readonly TextBox Index = Ui.Input("十进制索引", "0");
    internal readonly TextBox Phrase = Ui.Input("输入完整 Electrum 助记词");
    internal readonly ComboBox AddressType = Ui.Select(new[] { "all", "standard", "segwit" }, "all", 170);
    internal readonly ComboBox Count = Ui.Select(new[] { 1, 2, 5 }, 5, 100);
    private readonly MnemonicWordGrid _words = new();
    private readonly SelectableTextBlock _resultIndex = new() { FontFamily = Ui.Mono, Foreground = Ui.Muted, TextWrapping = TextWrapping.Wrap };
    private readonly Control _mnemonicCard;
    internal readonly AddressResults Results;
    private CancellationTokenSource? _optionsWork;
    private bool _active;
    internal Task PendingRefresh { get; private set; } = Task.CompletedTask;
    internal MnemonicResult? Result { get; private set; }
    internal ElectrumPage(AppServices services) : base(services)
    {
        Results = new(services);
        _mnemonicCard = Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Text("助记词", 18), Ui.AsyncButton("复制全部", () => Result == null ? Task.CompletedTask : services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), Result.Mnemonic))),
            _words, new Expander { Header = "查看索引", Content = _resultIndex }));
        _mnemonicCard.IsVisible = false;
        Layout("Electrum 助记词", "Standard / SegWit 种子 · 独立索引导航",
            Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Field("地址类型", AddressType), Ui.Field("接收地址数量", Count)),
                Ui.Text("选项修改后自动更新当前结果", 12, Ui.Muted), Ui.Field("十进制索引", Index), Ui.AsyncButton("生成地址", () => GenerateAsync(), true),
                Ui.Field("助记词定位", Phrase), Ui.AsyncButton("定位助记词", () => GenerateAsync("search")))),
            Ui.Wrap(Ui.AsyncButton("首组", () => GenerateAsync("first")), Ui.AsyncButton("上一组", () => GenerateAsync("previous")),
                Ui.AsyncButton("安全随机", () => GenerateAsync("random")), Ui.AsyncButton("下一组", () => GenerateAsync("next")),
                Ui.AsyncButton("末组", () => GenerateAsync("last")), Ui.Button("取消", Cancel), Ui.AsyncButton("清空", async () => { ClearSensitive(); await Services.Clipboard.ClearOwnedAsync(); })),
            _mnemonicCard, Results);
        Count.SelectionChanged += (_, _) => QueueRefresh(); AddressType.SelectionChanged += (_, _) => QueueRefresh();
        Phrase.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { e.Handled = true; await GenerateAsync("search"); } };
        Index.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { e.Handled = true; await GenerateAsync(); } };
    }
    internal override void Enter() { _active = true; if (Result == null) _ = GenerateAsync("first"); }
    internal override void Leave() { _active = false; ClearSensitive(); _ = ClearClipboardAsync(); }
    private async Task ClearClipboardAsync() { try { await Services.Clipboard.ClearOwnedAsync(); } catch { } }
    private void QueueRefresh()
    {
        if (!_active || Result == null) return;
        Cancel(); var work = _optionsWork = new(); PendingRefresh = RefreshLaterAsync(work.Token);
    }
    private async Task RefreshLaterAsync(CancellationToken token)
    {
        try { await Task.Delay(60, token); _optionsWork = null; await GenerateAsync("current", true); }
        catch (OperationCanceledException) { }
    }
    internal Task GenerateAsync(string operation = "current", bool preserveIndex = false) => RunAsync(async token =>
    {
        var input = operation == "search" ? Ui.Value(Phrase) : preserveIndex ? Result?.Index ?? "0" : Ui.Value(Index);
        var generated = await Services.Core.ElectrumAsync(input, (int)(Count.SelectedItem ?? 5), Ui.Selected(AddressType), operation, token);
        token.ThrowIfCancellationRequested();
        Result = generated; _mnemonicCard.IsVisible = true; Index.Text = generated.Index; _words.SetWords(generated.Mnemonic); _resultIndex.Text = generated.Index; Results.SetItems(generated.Items);
        Results.SetContext("派生地址", $"共 {Results.Items.Length} 条公开地址");
        if (operation == "search") Phrase.Text = "";
        Status.Text = $"索引 {generated.Index} / {generated.Max}";
        if (Services.Settings.Current.AutoRefresh) _ = Results.RefreshAsync(true);
    });
    internal void ClearSensitive()
    {
        Cancel(); Result = null; _mnemonicCard.IsVisible = false; Index.Text = "0"; Phrase.Text = ""; _words.SetWords(""); _resultIndex.Text = "";
        foreach (var input in new[] { Phrase, Index }) { input.IsUndoEnabled = false; input.IsUndoEnabled = true; }
        Results.SetItems([]); Error.Text = ""; Status.Text = "";
    }
    internal override void Cancel() { base.Cancel(); _optionsWork?.Cancel(); Results?.Cancel(); }
}
