using Avalonia.Controls;
using Avalonia.Media;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class MnemonicDirectoryPage : FeaturePage
{
    internal readonly ComboBox Words = Ui.Select(new[] { 12, 15, 18, 21, 24 }, 12, 110);
    internal readonly ComboBox PageSize = Ui.Select(new[] { 10, 20 }, 10, 110);
    internal readonly ComboBox BtcType = Ui.Select(new[] { "all", "legacy", "segwit", "nested", "taproot" }, "all", 170);
    internal readonly CoinPicker Coins = new("BTC", "ETH");
    internal readonly TextBox Index = Ui.Input("目录起始熵索引", "0");
    internal readonly AddressResults Results;
    private readonly StackPanel _groups = new() { Spacing = 8 };
    private readonly TextBlock _summary = Ui.Text("尚未生成目录", 12, Ui.Muted);
    private readonly Dictionary<string, bool> _expanded = [];
    private readonly Func<MnemonicResult, int, string[], string, Task> _open;
    private readonly Button _previous, _next;
    private int _appliedWords;
    private string[] _appliedCoins = [];
    private string _appliedBtc = "all";
    private CancellationTokenSource? _optionsWork;
    internal Task PendingRefresh { get; private set; } = Task.CompletedTask;
    internal MnemonicPageResult? Result { get; private set; }
    internal int VisibleGroups { get; private set; }
    internal MnemonicDirectoryPage(AppServices services, Func<MnemonicResult, int, string[], string, Task> open) : base(services)
    {
        _open = open; Results = new(services) { ShowRows = false };
        _previous = Ui.AsyncButton("上一页", () => GenerateAsync("previous"));
        _next = Ui.AsyncButton("下一页", () => GenerateAsync("next"));
        Layout("助记词多组目录", "独立目录分页 · 账户 0 · 标准收款路径 · 空 Passphrase",
            Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Field("词数", Words), Ui.Field("每页组数", PageSize), Ui.Field("BTC 类型", BtcType)), Coins.View,
                Ui.Text("选项修改后自动更新；进入单组时沿用本目录已生成的参数", 12, Ui.Muted),
                Ui.Field("起始熵索引（十进制）", Index), Ui.Wrap(Ui.AsyncButton("跳转目录", () => GenerateAsync("jump"), true),
                    Ui.AsyncButton("刷新目录", () => GenerateAsync("current")), Ui.AsyncButton("首页", () => GenerateAsync("first")), _previous,
                    Ui.AsyncButton("安全随机", () => GenerateAsync("random")), _next, Ui.AsyncButton("末页", () => GenerateAsync("last")),
                    Ui.Button("取消", Cancel), Ui.AsyncButton("清空目录", async () => { ClearSensitive(); await Services.Clipboard.ClearOwnedAsync(); })))),
            Results, _summary, _groups);
        Words.SelectionChanged += (_, _) => QueueRefresh("first");
        PageSize.SelectionChanged += (_, _) => QueueRefresh("first");
        BtcType.SelectionChanged += (_, _) => QueueRefresh("current");
        Coins.Changed += () => QueueRefresh("current");
        Index.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { e.Handled = true; await GenerateAsync("jump"); } };
        Results.Changed += RenderGroups;
    }
    internal override void Enter() { if (Result == null) _ = GenerateAsync("first"); }
    private void QueueRefresh(string operation)
    {
        Cancel(); var work = _optionsWork = new(); PendingRefresh = RefreshLaterAsync(operation, work.Token);
    }
    private async Task RefreshLaterAsync(string operation, CancellationToken token)
    {
        try { await Task.Delay(60, token); _optionsWork = null; await GenerateAsync(operation); }
        catch (OperationCanceledException) { }
    }
    internal Task GenerateAsync(string operation) => RunAsync(async token =>
    {
        if (Coins.Selected.Length == 0) throw new InvalidDataException("请至少选择一个币种");
        var words = (int)(Words.SelectedItem ?? 12); var coins = Coins.Selected; var btc = Ui.Selected(BtcType);
        var index = operation == "jump" ? Ui.Value(Index) : operation == "first" ? "0" : Result?.Start ?? "0";
        var result = await Services.Core.DirectoryAsync(words / 3 * 32, (int)(PageSize.SelectedItem ?? 10), coins, index, operation, btc, token);
        token.ThrowIfCancellationRequested();
        Result = result; _appliedWords = words; _appliedCoins = coins; _appliedBtc = btc;
        Index.Text = result.Start; _expanded.Clear();
        Results.SetItems(result.Items.SelectMany(i => i.Items));
        _previous.IsEnabled = result.HasPrevious; _next.IsEnabled = result.HasNext;
        Status.Text = $"{result.Start} – {result.End} / {result.Max}";
        if (Services.Settings.Current.AutoRefresh) _ = Results.RefreshAsync(true);
    });
    private void RenderGroups()
    {
        _groups.Children.Clear(); VisibleGroups = 0;
        if (Result == null) return;
        foreach (var entry in Result.Items)
        {
            var items = Services.Settings.Project(entry.Items);
            var visible = items.Where(Results.Includes).ToArray();
            if (Results.Filter != "全部" && visible.Length == 0) continue;
            VisibleGroups++;
            var details = Ui.Stack(visible.Select(Results.CreateRow).ToArray());
            var expand = new Expander
            {
                Header = $"派生地址 · {visible.Length} 条",
                Content = details,
                IsExpanded = _expanded.GetValueOrDefault(entry.Index),
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch
            };
            expand.PropertyChanged += (_, e) => { if (e.Property == Expander.IsExpandedProperty) _expanded[entry.Index] = expand.IsExpanded; };
            var card = Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Text("熵索引 " + entry.Index, 12, Ui.Muted),
                Ui.AsyncButton("复制助记词", () => Services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), entry.Mnemonic)),
                Ui.AsyncButton("单组详情", () => OpenEntryAsync(entry))),
                new SelectableTextBlock { Text = entry.Mnemonic, FontFamily = Ui.Mono, FontSize = 14, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Ink }, expand));
            if (items.Any(i => Results.Record(i) is { } record && (record.Funded || record.Activity))) card.BorderBrush = Brush.Parse("#34705C");
            _groups.Children.Add(card);
        }
        _summary.Text = $"匹配助记词 {VisibleGroups} / {Result.Items.Length} 组 · 熵索引 {Result.Start}–{Result.End}";
        if (VisibleGroups == 0) _groups.Children.Add(Ui.Text("当前筛选没有结果；未查询与失败不会作为零余额", 13, Ui.Muted));
    }
    internal Task OpenEntryAsync(MnemonicResult entry) => _open(entry, _appliedWords, _appliedCoins, _appliedBtc);
    internal void ClearSensitive()
    {
        Cancel(); Result = null; _appliedCoins = []; _appliedWords = 0; Index.Text = "0";
        _expanded.Clear(); _groups.Children.Clear(); Results.SetItems([]); _summary.Text = "尚未生成目录"; Error.Text = ""; Status.Text = "";
    }
    internal override void Cancel() { base.Cancel(); _optionsWork?.Cancel(); Results?.Cancel(); }
}
