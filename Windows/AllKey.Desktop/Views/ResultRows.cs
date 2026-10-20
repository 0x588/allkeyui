using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using AllKey.Core;

namespace AllKey.Desktop.Views;

// Matches the macOS ResultColumns layout: a fixed balance column on roomy rows,
// stacked sections on narrow rows, with values measured inside their own column.
internal sealed class ResultColumns : Panel
{
    internal double Breakpoint { get; init; } = 700;
    internal double TrailingWidth { get; init; } = 230;
    internal double Gap { get; init; } = 14;
    protected override Size MeasureOverride(Size available)
    {
        var width = double.IsFinite(available.Width) ? available.Width : Breakpoint;
        var horizontal = width >= Breakpoint;
        for (var i = 0; i < Children.Count; i++)
            Children[i].Measure(new Size(horizontal ? i == 0 ? Math.Max(0, width - TrailingWidth - Gap) : TrailingWidth : width, double.PositiveInfinity));
        return new Size(width, Children.Count == 0 ? 0 : horizontal ? Children.Max(c => c.DesiredSize.Height) : Children.Sum(c => c.DesiredSize.Height) + Gap * (Children.Count - 1));
    }
    protected override Size ArrangeOverride(Size final)
    {
        var horizontal = final.Width >= Breakpoint;
        double x = 0, y = 0;
        for (var i = 0; i < Children.Count; i++)
        {
            var width = horizontal ? i == 0 ? Math.Max(0, final.Width - TrailingWidth - Gap) : TrailingWidth : final.Width;
            Children[i].Arrange(new Rect(x, y, width, Children[i].DesiredSize.Height));
            if (horizontal) x += width + Gap; else y += Children[i].DesiredSize.Height + Gap;
        }
        return final;
    }
}

internal static class ResultRows
{
    internal static readonly IBrush Positive = Brush.Parse("#438D69");
    internal static readonly IBrush PositiveFill = Brush.Parse("#153D9A67");
    internal static readonly IBrush NeutralFill = Brush.Parse("#10DDB550");
    internal static Control Address(AddressItem item, BalanceRecord? balance, bool pending, string? copied, Func<string, bool, Task> copy, Action open)
    {
        var header = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,Auto,*"), ColumnSpacing = 8 };
        var badge = new Border
        {
            Background = NeutralFill,
            CornerRadius = new(5),
            Padding = new(6, 3),
            Child = Ui.Text(item.DisplayCoin, 12, Ui.Accent)
        };
        ToolTip.SetTip(badge, item.DisplayNetwork); header.Children.Add(badge);
        var kind = Ui.Text((item.Network == null ? "" : item.DisplayNetwork + " · ") + item.AddressTag, 12, Ui.Muted);
        kind.MaxWidth = 220; Grid.SetColumn(kind, 1); header.Children.Add(kind);
        var path = new SelectableTextBlock
        {
            Text = item.Path,
            FontFamily = Ui.Mono,
            FontSize = 12,
            Foreground = Ui.Muted,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        ToolTip.SetTip(path, item.Path); AutomationProperties.SetName(path, "派生路径 " + item.Path); Grid.SetColumn(path, 2); header.Children.Add(path);
        var values = new StackPanel { Spacing = 6 };
        values.Children.Add(Value("公开地址", item.Address, copied == item.Address, () => copy(item.Address, false), item.Explorer.Length > 0 ? open : null));
        if (item.PrivateKey.Length > 0) values.Children.Add(Value(item.PrivateKeyLabel, item.PrivateKey, copied == item.PrivateKey, () => copy(item.PrivateKey, true)));
        if (item.AlternateKey.Length > 0) values.Children.Add(Value(item.AlternateKeyLabel, item.AlternateKey, copied == item.AlternateKey, () => copy(item.AlternateKey, true)));
        var columns = new ResultColumns { Children = { values, Balance(balance, pending) } };
        var content = new StackPanel { Spacing = 8, Children = { header, columns } };
        var card = Ui.Panel(content); card.Padding = new(10);
        if (balance is { Success: true } && (balance.Funded || balance.Activity)) card.BorderBrush = Positive;
        card.Classes.Add("address-result");
        return card;
    }
    internal static Control Value(string label, string value, bool copied, Func<Task> copy, Action? open = null)
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("76,*,Auto"), ColumnSpacing = 8 };
        grid.Classes.Add("result-value-line");
        var caption = Ui.Text(label, 12, Ui.Muted); caption.VerticalAlignment = VerticalAlignment.Top; caption.Margin = new(0, 3, 0, 0);
        grid.Children.Add(caption);
        var text = new SelectableTextBlock
        {
            Text = value,
            FontFamily = Ui.Mono,
            FontSize = 13,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Ui.Ink,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new(0, 2, 0, 0)
        };
        AutomationProperties.SetName(text, label); Grid.SetColumn(text, 1); grid.Children.Add(text);
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, VerticalAlignment = VerticalAlignment.Top };
        if (open != null) actions.Children.Add(Compact("↗", "在区块浏览器中打开公开地址", () => { open(); return Task.CompletedTask; }));
        actions.Children.Add(Compact(copied ? "✓" : "复制", copied ? "已复制" + label : "复制" + label, copy));
        Grid.SetColumn(actions, 2); grid.Children.Add(actions);
        return grid;
    }
    private static Button Compact(string content, string name, Func<Task> action)
    {
        var button = Ui.AsyncButton(content, action);
        button.MinHeight = 24; button.MinWidth = 28; button.Padding = new(5, 2); button.FontSize = 11;
        button.Background = Brushes.Transparent; button.BorderThickness = new(0);
        AutomationProperties.SetName(button, name); ToolTip.SetTip(button, name);
        return button;
    }
    internal static Control Balance(BalanceRecord? record, bool pending = false)
    {
        var content = new StackPanel { Spacing = 5 };
        if (pending) content.Children.Add(Ui.Row(new ProgressBar { IsIndeterminate = true, Width = 26, Height = 3 }, Ui.Text("正在查询…", 12, Ui.Muted)));
        else
        {
            if (record == null)
            {
                content.Children.Add(Ui.Text("余额", 12, Ui.Muted)); content.Children.Add(Ui.Text("尚未查询", 13, Ui.Muted));
            }
            else
            {
                var heading = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 10 };
                heading.Children.Add(Ui.Text("余额", 12, Ui.Muted));
                var amount = new SelectableTextBlock
                {
                    Text = record == null ? "尚未查询" : record.Success ? record.Balance ?? "—" : "查询失败",
                    FontFamily = Ui.Mono,
                    FontSize = 13,
                    Foreground = record?.Funded == true ? Positive : Ui.Ink,
                    TextWrapping = TextWrapping.Wrap
                };
                Grid.SetColumn(amount, 1); heading.Children.Add(amount); content.Children.Add(heading);
            }
            if (record?.Error is { } error) content.Children.Add(Ui.Text(error, 12, Brush.Parse("#B36B30")));
            if (record is { Success: true })
            {
                if (record.Transactions != null) content.Children.Add(Statistic("交易数", record.Transactions));
                if (record.Received != null) content.Children.Add(Statistic("累计收到", record.Received));
            }
            if (record?.Source != null)
            {
                var source = Ui.Text(record.Source.Split(" · ")[0] + " · " + record.QueriedAt?.ToLocalTime().ToString("HH:mm:ss") + (record.Cached ? " · 缓存" : ""), 11, Ui.Muted);
                ToolTip.SetTip(source, record.Source); content.Children.Add(source);
            }
        }
        var panel = new Border { Padding = new(8), CornerRadius = new(9), Background = record is { Success: true } && (record.Funded || record.Activity) ? PositiveFill : NeutralFill, Child = content };
        panel.Classes.Add("balance-details"); return panel;
    }
    private static Control Statistic(string label, string value)
    {
        var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*"), ColumnSpacing = 8 };
        row.Children.Add(Ui.Text(label, 11, Ui.Muted));
        var text = new SelectableTextBlock { Text = value, FontFamily = Ui.Mono, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = BalanceRecord.NonZero(value) ? Positive : Ui.Muted };
        Grid.SetColumn(text, 1); row.Children.Add(text); return row;
    }
}
