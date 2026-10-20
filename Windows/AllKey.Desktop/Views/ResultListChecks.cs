using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal static class ResultListChecks
{
    internal static async Task RunAsync(MainWindow window, AppServices services, Action<bool, string> check)
    {
        window.Navigate("keys"); window.Keys.ExitPuzzle(); window.Keys.Coins.Set("BTC", "SOL"); window.Keys.Index.Text = "1";
        await window.Keys.GenerateAsync();
        var item = window.Keys.Result!.Items.First(i => i.Coin == "BTC");
        var values = window.Keys.Results.GetLogicalDescendants().OfType<SelectableTextBlock>().Select(t => t.Text).ToArray();
        check(values.Contains(item.Address) && values.Contains(item.PrivateKey) && values.Contains(item.AlternateKey), "result list displays address private key and alternate key like macOS");
        check(window.Keys.Results.GetLogicalDescendants().OfType<TextBlock>().Any(t => t.Text == "尚未查询"), "unqueried result displays explicit balance state");
        var copy = window.Keys.Results.GetLogicalDescendants().OfType<Button>().First(b => AutomationProperties.GetName(b) == "复制" + item.PrivateKeyLabel);
        copy.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Task.Delay(50);
        check(await window.Clipboard!.TryGetTextAsync() == item.PrivateKey, "inline private-key copy copies the exact displayed value");
        check(window.Keys.Results.GetLogicalDescendants().OfType<Button>().Any(b => AutomationProperties.GetName(b) == "已复制" + item.PrivateKeyLabel), "inline copy gives per-field confirmation");
        await services.Clipboard.ClearOwnedAsync();

        var sol = (await services.Core.MnemonicAsync(new() { Coins = ["SOL"] })).Items.Single();
        foreach (var width in new[] { 900, 600, 400 })
        {
            var row = ResultRows.Address(sol, new(true, "0.00000001 SOL", "7", "123456789012345678901234567890.123456789 SOL", Source: "fixture · local", QueriedAt: DateTimeOffset.UtcNow, Cached: true), false, null, (_, _) => Task.CompletedTask, () => { });
            row.Measure(new Size(width, double.PositiveInfinity)); row.Arrange(new Rect(0, 0, width, row.DesiredSize.Height));
            var columns = row.GetLogicalDescendants().OfType<ResultColumns>().Single(); var left = columns.Children[0].Bounds; var right = columns.Children[1].Bounds;
            check(width == 900 ? right.Left >= left.Right + 13 : right.Top >= left.Bottom + 13, "address balance columns adapt at width " + width);
            var secret = row.GetLogicalDescendants().OfType<SelectableTextBlock>().Single(t => t.Text == sol.PrivateKey);
            check(secret.Bounds.Height > 20 && secret.Bounds.Width < left.Width, "long SOL key wraps inside its value column at width " + width);
            var labels = row.GetLogicalDescendants().OfType<TextBlock>().Select(t => t.Text).ToArray();
            check(labels.Contains("交易数") && labels.Contains("累计收到") && labels.Any(t => t?.Contains("缓存") == true), "balance details include statistics source time and cache at width " + width);
        }
        foreach (var (record, pending, expected) in new (BalanceRecord?, bool, string)[] { (null, false, "尚未查询"), (null, true, "正在查询…"), (BalanceRecord.Failed("fixture failure"), false, "查询失败") })
        {
            var panel = ResultRows.Balance(record, pending);
            var texts = panel.GetLogicalDescendants().Select(c => c is TextBlock t ? t.Text : c is SelectableTextBlock s ? s.Text : null).ToArray();
            check(texts.Contains(expected), "distinct balance display: " + expected);
        }
        foreach (var (width, rows) in new[] { (900, 2), (600, 3), (450, 4) })
        {
            var grid = new MnemonicWordGrid(); grid.SetWords(string.Join(' ', Enumerable.Repeat("abandon", 11)) + " about");
            grid.Measure(new Size(width, double.PositiveInfinity)); grid.Arrange(new Rect(0, 0, width, grid.DesiredSize.Height));
            check(grid.Children.Count == 12 && grid.Children.Select(c => c.Bounds.Y).Distinct().Count() == rows, "numbered mnemonic grid uses macOS column breakpoints at width " + width);
        }
        window.Navigate("bip39"); window.Mnemonics.SelectMode("directory");
        window.Navigate("keys"); window.Navigate("bip39"); window.Mnemonics.SelectMode("single");
        while (window.Mnemonics.IsBusy) await Task.Delay(10);
        check(window.Mnemonics.Result != null, "returning from directory to empty single mode populates mnemonic results");
        var requests = new List<(PublicAddress Address, bool Force)>();
        var gate = new TaskCompletionSource<BalanceRecord>();
        var puzzlePage = new PuzzlePage(services, async (address, force, token) =>
        {
            requests.Add((address, force));
            return await gate.Task; // Simulate a service finishing after the page has left.
        });
        puzzlePage.Enter();
        check(requests.Count == 3, "puzzle page starts automatic public-address queries with bounded concurrency");
        puzzlePage.List.SelectedIndex = 1;
        puzzlePage.Leave();
        gate.SetResult(new(true, "1 BTC"));
        await puzzlePage.BalanceLoad;
        check(puzzlePage.BalanceCount == 0 && requests.Count == 3, "leaving puzzle page rejects late results and stops queued requests");
        puzzlePage.Enter();
        await puzzlePage.BalanceLoad;
        check(puzzlePage.BalanceCount == 160 && requests.Count == 163, "reentering puzzle page loads every catalog balance");
        check(requests.All(r => !r.Force && r.Address.Coin == "BTC" && puzzlePage.Catalog.Puzzles.Any(p => p.Address == r.Address.Address)), "automatic puzzle queries allow cache and contain public catalog addresses only");
        var refreshPuzzle = puzzlePage.GetLogicalDescendants().OfType<Button>().Single(b => b.Content?.ToString() == "刷新公开地址余额");
        refreshPuzzle.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        check(requests.Count == 164 && requests.Last().Force, "puzzle detail keeps forced manual refresh");
        puzzlePage.Leave();
        window.Navigate("puzzle");
        var headings = window.Puzzles.GetLogicalDescendants().OfType<TextBlock>().Select(t => t.Text).ToArray();
        check(new[] { "编号", "状态", "目标地址", "余额" }.All(headings.Contains), "puzzle table includes all macOS list columns");
    }
}
