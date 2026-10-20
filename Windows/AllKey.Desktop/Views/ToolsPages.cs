using System.Text;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.VisualTree;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal record CalculatorOperation(string Id, string Category, string Title, string Detail)
{
    public override string ToString() => Title;
}

internal sealed class CalculatorPage : FeaturePage
{
    private static readonly Dictionary<string, string> Categories = new()
    {
        ["basic"] = "基础转换", ["privateKey"] = "私钥", ["publicKey"] = "公钥", ["wif"] = "WIF", ["bip38"] = "BIP38",
        ["address"] = "地址", ["hash"] = "哈希", ["base58"] = "Base58", ["bech32"] = "Bech32", ["utility"] = "辅助工具"
    };
    internal readonly CalculatorOperation[] Operations;
    private readonly ComboBox _category;
    internal readonly ComboBox Operation;
    internal readonly TextBox Input = Ui.Input("输入内容");
    internal readonly TextBox Output = Ui.Input("计算结果");
    private readonly TextBox _passphrase = Ui.Input("BIP38 口令");
    private readonly StackPanel _passphraseField;
    private readonly CheckBox _compressed = new() { Content = "压缩公钥格式", IsChecked = true };
    internal readonly CheckBox Batch = new() { Content = "逐行批量处理" };
    private readonly TextBlock _detail = Ui.Text("", 12, Ui.Muted);
    internal CalculatorPage(AppServices services) : base(services)
    {
        Operations = JsonSerializer.Deserialize<CalculatorOperation[]>(File.ReadAllText(System.IO.Path.Combine(AppContext.BaseDirectory, "calculator-operations.json")), CoreJson.Options)
            ?? throw new InvalidDataException("计算器操作目录不存在");
        _category = Ui.Select(Categories.Values, "基础转换", 160);
        Operation = new ComboBox { ItemsSource = Operations.Where(o => o.Category == "basic").ToArray(), SelectedIndex = 0, MinWidth = 250 };
        Input.AcceptsReturn = Output.AcceptsReturn = true;
        Input.VerticalContentAlignment = Output.VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Top;
        Input.TextWrapping = Output.TextWrapping = TextWrapping.Wrap;
        Input.MinHeight = 140; Output.MinHeight = 180; Output.IsReadOnly = true;
        Input.FontFamily = Output.FontFamily = Ui.Mono;
        _passphrase.PasswordChar = '●';
        _passphraseField = Ui.Field("BIP38 口令", _passphrase);
        Layout("Crypto Calculator", "10 类 · 46 个操作 · 密钥、地址、编码与哈希",
            Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Field("类别", _category), Ui.Field("操作", Operation)), _detail,
                Ui.Field("输入", Input), Ui.Wrap(Batch, _compressed), _passphraseField,
                Ui.Wrap(Ui.AsyncButton("计算", CalculateAsync, true), Ui.Button("取消", Cancel),
                    Ui.AsyncButton("粘贴", async () => { Input.Text = await TopLevel.GetTopLevel(this)!.Clipboard!.TryGetTextAsync() ?? ""; }),
                    Ui.AsyncButton("清空", async () => { Cancel(); Input.Text = Output.Text = _passphrase.Text = ""; await services.Clipboard.ClearOwnedAsync(); })))),
            Ui.Panel(Ui.Stack(Ui.Field("计算结果", Output), Ui.AsyncButton("复制结果", () => services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), Output.Text ?? "")))));
        _category.SelectionChanged += (_, _) =>
        {
            var category = Categories.First(p => p.Value == Ui.Selected(_category)).Key;
            Operation.ItemsSource = Operations.Where(o => o.Category == category).ToArray(); Operation.SelectedIndex = 0;
        };
        Operation.SelectionChanged += (_, _) => UpdateOperation();
        UpdateOperation();
    }
    private void UpdateOperation()
    {
        if (Operation.SelectedItem is not CalculatorOperation selected) return;
        _detail.Text = selected.Detail;
        _passphraseField.IsVisible = selected.Category == "bip38";
        _compressed.IsVisible = selected.Id == "bip38-encrypt";
    }
    internal void SelectOperation(string id)
    {
        var operation = Operations.First(o => o.Id == id);
        _category.SelectedItem = Categories[operation.Category]; Operation.SelectedItem = operation;
    }
    internal Task CalculateAsync() => RunAsync(async token =>
    {
        var operation = Operation.SelectedItem as CalculatorOperation ?? throw new InvalidDataException("请选择计算操作");
        var input = Input.Text ?? "";
        var batch = Batch.IsChecked == true;
        var lines = batch ? input.Replace("\r\n", "\n").Split('\n') : [input];
        if (lines.Length > 1000) throw new InvalidDataException("每批最多处理 1000 行，请分批计算");
        var passphrase = _passphrase.Text ?? "";
        var compressed = _compressed.IsChecked != false;
        var output = new StringBuilder();
        for (var i = 0; i < lines.Length; i++)
        {
            token.ThrowIfCancellationRequested();
            try
            {
                var value = await Services.Core.CalculateAsync(operation.Id, lines[i], passphrase, compressed, token);
                token.ThrowIfCancellationRequested();
                if (batch) output.AppendLine($"[{i + 1}] {value}"); else output.Append(value);
            }
            catch (CoreException error)
            {
                if (!batch) throw;
                output.AppendLine($"[{i + 1}] 错误：{error.Message}");
            }
            Status.Text = $"已处理 {i + 1} / {lines.Length}";
        }
        token.ThrowIfCancellationRequested(); Output.Text = output.ToString();
    });
}

internal sealed class PuzzlePage : FeaturePage
{
    internal readonly PuzzleCatalog Catalog;
    private readonly ComboBox _filter = Ui.Select(new[] { "全部", "未解", "已解" }, "未解", 100);
    internal readonly TextBox Search = Ui.Input("题号或公开地址");
    internal readonly ListBox List = new() { Height = 400, BorderThickness = new(0) };
    private readonly StackPanel _details = new() { Spacing = 10 };
    private readonly Dictionary<int, BalanceRecord> _balances = [];
    private readonly Dictionary<int, TextBlock> _balanceLabels = [];
    private readonly TextBlock _count = Ui.Text("", 12, Ui.Muted);
    private readonly Control _empty;
    private readonly Func<PublicAddress, bool, CancellationToken, Task<BalanceRecord>> _fetchBalance;
    private readonly HashSet<int> _pending = [];
    private CancellationTokenSource? _balanceWork;
    private int _renderVersion;
    internal PuzzlePage(AppServices services, Func<PublicAddress, bool, CancellationToken, Task<BalanceRecord>>? fetchBalance = null) : base(services)
    {
        _fetchBalance = fetchBalance ?? services.Balances.FetchAsync;
        Catalog = PuzzleCatalog.Load(System.IO.Path.Combine(AppContext.BaseDirectory, "btc-puzzles.json"));
        var overview = Ui.Wrap(Metric("全部题目", Catalog.Puzzles.Length), Metric("未解 · 快照", Catalog.Puzzles.Count(p => !p.Solved)), Metric("已解 · 快照", Catalog.Puzzles.Count(p => p.Solved)));
        var header = PuzzleColumns();
        header.HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Left;
        List.Styles.Add(new Style(s => s.OfType<ListBoxItem>()) { Setters = {
            new Setter(ListBoxItem.HorizontalContentAlignmentProperty, Avalonia.Layout.HorizontalAlignment.Stretch), new Setter(ListBoxItem.PaddingProperty, new Thickness(0)) } });
        List.LayoutUpdated += (_, _) =>
        {
            var first = List.GetVisualDescendants().OfType<Grid>().FirstOrDefault(g => g.Classes.Contains("puzzle-table-row"));
            if (first is { Bounds.Width: > 0 } && (!double.IsFinite(header.Width) || Math.Abs(header.Width - first.Bounds.Width) > 0.5)) header.Width = first.Bounds.Width;
        };
        foreach (var (text, column) in new[] { ("编号", 0), ("状态", 1), ("目标地址", 2), ("余额", 3) }) { var label = Ui.Text(text, 12, Ui.Muted); Grid.SetColumn(label, column); header.Children.Add(label); }
        _empty = Ui.Stack(Ui.Text("没有匹配的题目", 15), Ui.Button("清除筛选", () => { Search.Text = ""; _filter.SelectedItem = "全部"; }));
        var listPanel = Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Text("题目列表", 17), _count), header, List, _empty));
        var details = Ui.Panel(_details);
        var columns = new ResultColumns { Breakpoint = 780, TrailingWidth = 320, Gap = 10, Children = { listPanel, details } };
        var filters = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 10 };
        filters.Children.Add(_filter); Grid.SetColumn(Search, 1); filters.Children.Add(Search);
        Layout("BTC Puzzle", $"160 题离线目录 · 状态快照 {Catalog.CapturedAt[..10]}",
            Ui.Panel(overview), filters, columns, Ui.Text($"状态快照 {Catalog.CapturedAt[..10]} · 不随余额变化自动判定已解状态", 11, Ui.Muted),
            Ui.Button("数据来源 ↗", () => { try { AppServices.OpenUrl(Catalog.SourceUrl); } catch { Error.Text = "无法打开数据来源"; } }));
        _filter.SelectionChanged += (_, _) => RenderList(); Search.TextChanged += (_, _) => RenderList();
        List.ItemTemplate = new Avalonia.Controls.Templates.FuncDataTemplate<Puzzle>((p, _) => PuzzleRow(p!));
        List.SelectionChanged += (_, _) => RenderDetails();
        RenderList();
    }
    private static Control Metric(string label, int value) => new StackPanel { Width = 180, Spacing = 4, Children = { Ui.Text(value.ToString(), 25), Ui.Text(label, 12, Ui.Muted) } };
    private static Grid PuzzleColumns() => new() { ColumnDefinitions = new ColumnDefinitions("44,44,*,80"), ColumnSpacing = 6 };
    private Control PuzzleRow(Puzzle puzzle)
    {
        var row = PuzzleColumns(); row.Classes.Add("puzzle-table-row"); row.Margin = new(0, 4);
        row.Children.Add(Ui.Text($"#{puzzle.Id}", 12));
        var state = Ui.Text(puzzle.State, 12, puzzle.Solved ? ResultRows.Positive : Ui.Muted); Grid.SetColumn(state, 1); row.Children.Add(state);
        var address = Ui.Text(puzzle.Address, 12); address.FontFamily = Ui.Mono; address.TextWrapping = TextWrapping.NoWrap; address.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTip.SetTip(address, puzzle.Address);
        var target = new StackPanel { Spacing = 3, Children = { address, Ui.Text($"{puzzle.Id} 位 · 2^{puzzle.Id - 1} 个候选", 10, Ui.Muted) } };
        Grid.SetColumn(target, 2); row.Children.Add(target);
        var balance = Ui.Text(BalanceText(puzzle.Id), 11, _balances.GetValueOrDefault(puzzle.Id)?.Funded == true ? ResultRows.Positive : Ui.Muted);
        balance.FontFamily = Ui.Mono; balance.TextWrapping = TextWrapping.NoWrap; balance.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTip.SetTip(balance, _balances.GetValueOrDefault(puzzle.Id)?.Balance ?? "进入页面后自动查询公开地址余额");
        _balanceLabels[puzzle.Id] = balance; Grid.SetColumn(balance, 3); row.Children.Add(balance); return row;
    }
    private string BalanceText(int id) => _pending.Contains(id) ? "查询中…" : _balances.GetValueOrDefault(id) is { } record ? record.Success ? record.Balance ?? "—" : "不可用" : "—";
    private void RenderList()
    {
        var query = Ui.Value(Search);
        var number = int.TryParse(query.TrimStart('#'), out var parsed) ? parsed : (int?)null;
        var selected = List.SelectedItem as Puzzle;
        var items = Catalog.Puzzles.Where(p => (Ui.Selected(_filter) == "全部" || p.State == Ui.Selected(_filter)) &&
            (query.Length == 0 || (number != null ? p.Id == number : p.Address.Contains(query, StringComparison.OrdinalIgnoreCase)))).ToArray();
        _balanceLabels.Clear(); List.ItemsSource = items; List.SelectedItem = selected != null && items.Contains(selected) ? selected : items.FirstOrDefault();
        List.IsVisible = items.Length > 0; _empty.IsVisible = items.Length == 0; _count.Text = $"{items.Length} 题";
        List.Height = Math.Min(400, Math.Max(160, items.Length * 40 + 32));
        Status.Text = $"显示 {items.Length} / 160 题 · 状态为带日期的离线快照";
    }
    private void RenderDetails()
    {
        _details.Children.Clear();
        if (List.SelectedItem is not Puzzle puzzle) { _details.Children.Add(Ui.Text("请选择题目", 15, Ui.Muted)); return; }
        _details.Children.Add(Ui.Wrap(Ui.Text($"Puzzle #{puzzle.Id}", 18), Ui.Text("快照" + puzzle.State, 11, puzzle.Solved ? ResultRows.Positive : Ui.Accent)));
        _details.Children.Add(Ui.Text("BTC 目标地址 · Legacy 压缩公钥", 12, Ui.Muted));
        _details.Children.Add(new SelectableTextBlock { Text = puzzle.Address, TextWrapping = TextWrapping.Wrap, FontFamily = Ui.Mono, FontSize = 12, Foreground = Ui.Ink });
        _details.Children.Add(Ui.Wrap(Ui.AsyncButton("复制地址", () => Services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), puzzle.Address, false)),
            Ui.Button("区块浏览器 ↗", () => { try { AppServices.OpenUrl(Core.Coins.Explorer("BTC") + puzzle.Address); } catch { Error.Text = "无法打开区块浏览器"; } })));
        _details.Children.Add(Ui.Text($"私钥区间 · {puzzle.Id} 位", 13));
        _details.Children.Add(Ui.Field("起点（含）", new SelectableTextBlock { Text = puzzle.LowerBound, FontFamily = Ui.Mono, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Ink }));
        _details.Children.Add(Ui.Field("终点（含）", new SelectableTextBlock { Text = puzzle.UpperBound, FontFamily = Ui.Mono, TextWrapping = TextWrapping.Wrap, Foreground = Ui.Ink }));
        _details.Children.Add(Ui.Text($"范围内共 2^{puzzle.Id - 1} 个候选", 11, Ui.Muted));
        _details.Children.Add(Ui.Wrap(Ui.Button("浏览范围", () => Services.OpenPuzzle?.Invoke(puzzle, "first"), true),
            Ui.Button("范围内随机", () => Services.OpenPuzzle?.Invoke(puzzle, "random")),
            Ui.Button("范围末页", () => Services.OpenPuzzle?.Invoke(puzzle, "last"))));
        _details.Children.Add(ResultRows.Balance(_balances.GetValueOrDefault(puzzle.Id), _pending.Contains(puzzle.Id)));
        var refresh = Ui.AsyncButton("刷新公开地址余额", () => RefreshBalanceAsync(puzzle));
        refresh.IsEnabled = !_pending.Contains(puzzle.Id);
        _details.Children.Add(refresh);
    }
    internal override void Enter()
    {
        Cancel();
        _balanceWork = new CancellationTokenSource();
        BalanceLoad = RefreshCatalogAsync(_balanceWork.Token);
    }
    internal Task BalanceLoad { get; private set; } = Task.CompletedTask;
    internal int BalanceCount => _balances.Count;
    private async Task RefreshCatalogAsync(CancellationToken token)
    {
        // Keep work on the UI context and limit the number of queued address requests.
        var selected = List.SelectedItem is Puzzle puzzle ? new[] { puzzle } : [];
        var visible = List.ItemsSource?.Cast<Puzzle>() ?? [];
        var puzzles = selected.Concat(visible).Concat(Catalog.Puzzles).DistinctBy(p => p.Id).ToArray();
        foreach (var group in puzzles.Chunk(3))
        {
            if (token.IsCancellationRequested) return;
            await Task.WhenAll(group.Select(p => RefreshBalanceAsync(p, false)));
        }
    }
    private async Task RefreshBalanceAsync(Puzzle puzzle, bool force = true)
    {
        if (_balanceWork is null || _pending.Contains(puzzle.Id)) return;
        var token = _balanceWork.Token;
        var version = _renderVersion; _pending.Add(puzzle.Id); RenderDetails(); UpdateBalanceLabel(puzzle.Id);
        try
        {
            var record = await _fetchBalance(new("BTC", puzzle.Address), force, token);
            token.ThrowIfCancellationRequested(); _balances[puzzle.Id] = record;
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (version == _renderVersion) _balances[puzzle.Id] = BalanceRecord.Failed("余额查询失败，请检查服务配置后重试"); }
        finally { if (version == _renderVersion) { _pending.Remove(puzzle.Id); UpdateBalanceLabel(puzzle.Id); RenderDetails(); } }
    }
    private void UpdateBalanceLabel(int id)
    {
        if (!_balanceLabels.TryGetValue(id, out var text)) return;
        text.Text = BalanceText(id); text.Foreground = _balances.GetValueOrDefault(id)?.Funded == true ? ResultRows.Positive : Ui.Muted;
        ToolTip.SetTip(text, _balances.GetValueOrDefault(id)?.Balance ?? "进入页面后自动查询公开地址余额");
    }
    internal override void Cancel()
    {
        base.Cancel(); _renderVersion++;
        _balanceWork?.Cancel(); _balanceWork?.Dispose(); _balanceWork = null;
        var pending = _pending.ToArray(); _pending.Clear();
        foreach (var id in pending) UpdateBalanceLabel(id);
        RenderDetails();
    }
}
