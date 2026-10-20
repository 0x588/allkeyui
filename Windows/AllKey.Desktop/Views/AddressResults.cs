using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class AddressResults : UserControl
{
    private readonly AppServices _services;
    private readonly StackPanel _rows = new() { Spacing = 6 };
    private readonly TextBlock _title = Ui.Text("派生地址", 18);
    private readonly TextBlock _context = Ui.Text("", 12, Ui.Muted);
    private readonly TextBlock _summary = Ui.Text("", 12, Ui.Muted);
    private readonly TextBlock _visible = Ui.Text("", 12, Ui.Muted);
    private readonly TextBlock _message = Ui.Text("", 12, Ui.Muted);
    private readonly ProgressBar _progress = new() { Height = 3, Minimum = 0, IsVisible = false };
    private readonly Dictionary<string, Button> _filters = [];
    private readonly Button _query, _force, _retry, _cancel;
    private readonly Dictionary<string, BalanceRecord> _balances = [];
    private readonly HashSet<string> _pending = [];
    private CancellationTokenSource? _balanceWork;
    private long _generation;
    private string _filter = "全部";
    private string? _copied;
    internal AddressItem[] Items { get; private set; } = [];
    internal event Action? Changed;
    internal bool ShowRows { get; set; } = true;
    internal string Filter { get => _filter; set { _filter = value; Render(); } }
    internal BalanceRecord? Record(AddressItem item) => _pending.Contains(item.Id) ? null : _balances.GetValueOrDefault(item.Id);
    internal bool Includes(AddressItem item) => Filter switch
    {
        "有余额" => Record(item)?.Funded == true,
        "有交易记录" => Record(item)?.Activity == true,
        "失败" => Record(item)?.Success == false,
        _ => true
    };
    internal AddressResults(AppServices services)
    {
        _services = services;
        _query = Ui.AsyncButton("查询公开地址余额", () => RefreshAsync(false));
        _force = Ui.AsyncButton("强制刷新", () => RefreshAsync(true));
        _retry = Ui.AsyncButton("重试失败项", () => RefreshAsync(true, true));
        _cancel = Ui.Button("取消查询", Cancel);
        var filters = Ui.Wrap();
        foreach (var name in new[] { "全部", "有余额", "有交易记录", "失败" })
        {
            var button = Ui.Button(name, () => Filter = name); button.Padding = new(10, 5); _filters[name] = button; filters.Children.Add(button);
        }
        var heading = new ResultColumns
        {
            Breakpoint = 800,
            TrailingWidth = 330,
            Gap = 12,
            Children = { Ui.Stack(_title, _context), Ui.Wrap(_retry, _force, _query, _cancel) }
        };
        Content = Ui.Stack(heading, _summary, _progress, Ui.Wrap(filters, _visible), _message, _rows);
        Render();
    }
    internal void SetContext(string title, string text) { _title.Text = title; _context.Text = text; }
    internal void SetItems(IEnumerable<AddressItem> items)
    {
        CancelWork(); Items = _services.Settings.Project(items); _balances.Clear(); _copied = null; _message.Text = "";
        if (Items.Length == 0) _context.Text = "";
        Render();
    }
    private void CancelWork() { _generation++; _balanceWork?.Cancel(); _pending.Clear(); }
    internal void Cancel() { CancelWork(); Render(); }
    internal async Task RefreshAsync(bool force, bool onlyFailed = false)
    {
        CancelWork(); var version = _generation;
        _balanceWork = new(); var token = _balanceWork.Token;
        var selected = Items.Where(i => !onlyFailed || _balances.GetValueOrDefault(i.Id)?.Success == false).ToArray();
        if (selected.Length == 0) { Render(); return; }
        _pending.UnionWith(selected.Select(i => i.Id)); Render();
        try
        {
            await Parallel.ForEachAsync(selected, new ParallelOptions { MaxDegreeOfParallelism = 3, CancellationToken = token }, async (item, cancellation) =>
            {
                var record = await _services.Balances.FetchAsync(new(item.Coin, item.Address, item.Network), force, cancellation);
                await Dispatcher.UIThread.InvokeAsync(() =>
                {
                    if (version != _generation) return;
                    _balances[item.Id] = record; _pending.Remove(item.Id); Render();
                });
            });
        }
        catch (OperationCanceledException) { }
        catch { if (version == _generation) _message.Text = "余额查询失败，请重试"; }
        finally { if (version == _generation) { _pending.Clear(); Render(); } }
    }
    private void Render()
    {
        var visible = Items.Where(Includes).ToArray(); var values = Items.Select(Record).Where(r => r != null).ToArray();
        _rows.Children.Clear();
        if (ShowRows) foreach (var item in visible) _rows.Children.Add(CreateRow(item));
        if (ShowRows && Items.Length == 0) _rows.Children.Add(Ui.Panel(Ui.Stack(Ui.Text("等待生成", 17), Ui.Text("选择币种并输入索引。所有计算均在本机完成。", 13, Ui.Muted))));
        else if (ShowRows && visible.Length == 0) _rows.Children.Add(Ui.Text(_pending.Count > 0 ? "当前筛选下暂无已完成结果，查询仍在继续。" : "当前筛选下没有结果；尚未查询的条目不会当作零余额。", 12, Ui.Muted));
        _summary.Text = $"已完成 {values.Length}/{Items.Length} · 成功 {values.Count(r => r!.Success)} · 失败 {values.Count(r => !r!.Success)} · 有余额 {values.Count(r => r!.Funded)}";
        _visible.Text = $"匹配地址 {visible.Length} / {Items.Length} 条";
        _context.IsVisible = !string.IsNullOrEmpty(_context.Text);
        _force.IsVisible = _balances.Count > 0; _retry.IsVisible = _balances.Values.Any(r => !r.Success); _cancel.IsVisible = _pending.Count > 0;
        _query.IsEnabled = _force.IsEnabled = _retry.IsEnabled = Items.Length > 0 && _pending.Count == 0;
        _progress.Maximum = Math.Max(1, Items.Length); _progress.Value = values.Length; _progress.IsVisible = _pending.Count > 0;
        _message.IsVisible = !string.IsNullOrEmpty(_message.Text);
        foreach (var (name, button) in _filters) button.Background = Filter == name ? Ui.Accent : Brushes.Transparent;
        Changed?.Invoke();
    }
    internal Control CreateRow(AddressItem item) => ResultRows.Address(item, Record(item), _pending.Contains(item.Id), _copied, CopyAsync, () =>
    {
        try { AppServices.OpenUrl(item.Explorer); }
        catch { _message.Text = "无法打开区块浏览器，请检查网络地址"; _message.IsVisible = true; }
    });
    private async Task CopyAsync(string value, bool sensitive)
    {
        if (value.Length == 0) return;
        try { await _services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), value, sensitive); _copied = value; _message.Text = sensitive ? "已复制，60 秒后在内容未变更时自动清除" : "已复制公开地址"; Render(); }
        catch { _message.Text = "复制失败，请重试"; _message.IsVisible = true; }
    }
}
