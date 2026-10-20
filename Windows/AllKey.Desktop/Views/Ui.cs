using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Automation;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal static class Ui
{
    internal const double ControlHeight = 36;
    internal static readonly SolidColorBrush Ink = new(Color.Parse("#263D36"));
    internal static readonly SolidColorBrush Muted = new(Color.Parse("#68756E"));
    internal static readonly SolidColorBrush CanvasFill = new(Color.Parse("#F4F5EF"));
    private static readonly SolidColorBrush PanelFill = new(Colors.White);
    private static readonly SolidColorBrush Line = new(Color.Parse("#DDE3DA"));
    internal static readonly IBrush Accent = Brush.Parse("#DDB550");
    internal static readonly FontFamily Mono = new("Cascadia Mono,Consolas,Menlo,Microsoft YaHei UI");
    internal static void ApplyPalette(bool dark)
    {
        Ink.Color = Color.Parse(dark ? "#E0E8DF" : "#263D36");
        Muted.Color = Color.Parse(dark ? "#A5B4AA" : "#68756E");
        CanvasFill.Color = Color.Parse(dark ? "#19231F" : "#F4F5EF");
        PanelFill.Color = Color.Parse(dark ? "#24312B" : "#FFFFFF");
        Line.Color = Color.Parse(dark ? "#3D5044" : "#DDE3DA");
    }
    internal static TextBlock Text(string text, double size = 13, IBrush? foreground = null) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = foreground ?? Ink,
        VerticalAlignment = VerticalAlignment.Center
    };
    internal static StackPanel Stack(params Control[] items)
    {
        var panel = new StackPanel { Spacing = 12 };
        foreach (var item in items) panel.Children.Add(item);
        return panel;
    }
    internal static StackPanel Row(params Control[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        foreach (var item in items) row.Children.Add(item);
        return row;
    }
    internal static WrapPanel Wrap(params Control[] items)
    {
        var row = new WrapPanel { Orientation = Orientation.Horizontal };
        row.Children.CollectionChanged += (_, _) => AlignWrap(row);
        foreach (var item in items) row.Children.Add(item);
        return row;
    }
    internal static void AlignWrap(WrapPanel row)
    {
        // A field includes a label above its editor. Align the editor edge with actions.
        var alignment = row.Children.Any(c => c.Classes.Contains("form-field")) ? VerticalAlignment.Bottom : VerticalAlignment.Center;
        foreach (var child in row.Children)
        {
            child.Margin = new Thickness(0, 0, 8, 8);
            child.VerticalAlignment = alignment;
            if (child is Avalonia.Controls.Button or TextBox or ComboBox or CheckBox) child.MinHeight = Math.Max(child.MinHeight, ControlHeight);
        }
    }
    internal static Border Panel(Control child) => new()
    {
        Child = child, Background = PanelFill, BorderBrush = Line, BorderThickness = new(1),
        CornerRadius = new(10), Padding = new(18)
    };
    internal static Button Button(string title, Action action, bool primary = false)
    {
        var button = new Button { Content = title, Padding = new(14, 7), MinHeight = ControlHeight, VerticalContentAlignment = VerticalAlignment.Center, CornerRadius = new(6) };
        if (primary) { button.Background = Accent; button.Foreground = Brush.Parse("#263D36"); button.FontWeight = FontWeight.SemiBold; }
        button.Click += (_, _) => action();
        AutomationProperties.SetName(button, title);
        return button;
    }
    internal static Button AsyncButton(string title, Func<Task> action, bool primary = false)
    {
        var button = Button(title, () => { }, primary);
        button.Click += async (_, _) =>
        {
            try { await action(); }
            catch (Exception error) { ToolTip.SetTip(button, error is CoreException ? error.Message : "操作失败，请重试"); }
        };
        return button;
    }
    internal static TextBox Input(string placeholder, string text = "", double width = double.NaN)
    {
        var box = new TextBox { PlaceholderText = placeholder, Text = text, MinWidth = 100, MinHeight = ControlHeight, Width = width, VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(box, placeholder);
        return box;
    }
    internal static StackPanel Field(string title, Control input)
    {
        var label = Text(title, 12, Muted);
        if (input is TextBox or ComboBox) input.MinHeight = Math.Max(input.MinHeight, ControlHeight);
        var field = new StackPanel { Spacing = 6, Children = { label, input } };
        field.Classes.Add("form-field");
        if (double.IsFinite(input.Width)) field.Width = input.Width;
        return field;
    }
    internal static ComboBox Select<T>(IEnumerable<T> values, T selected, double width = 160)
    {
        return new ComboBox { ItemsSource = values, SelectedItem = selected, Width = width, MinHeight = ControlHeight, VerticalContentAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Left,
            ItemTemplate = new Avalonia.Controls.Templates.FuncDataTemplate<object>((value, _) => Text(value?.ToString() switch
            {
                "all" => "全部类型", "legacy" => "Legacy · 压缩", "legacyUncompressed" => "Legacy · 未压缩",
                "segwit" => "Native SegWit", "nested" => "Nested SegWit", "taproot" => "Taproot",
                "receive" => "标准收款", "change" => "UTXO 找零", "light" => "浅色", "dark" => "深色", "system" => "跟随系统",
                "primary" => "主服务", "backup" => "备用服务", _ => value?.ToString() ?? ""
            })) };
    }
    internal static string Value(TextBox box) => box.Text?.Trim() ?? "";
    internal static long Number(TextBox box, long minimum, long maximum, string title)
    {
        var value = Value(box);
        if (value.Length == 0 || !value.All(char.IsAsciiDigit) || !long.TryParse(value, out var number) || number < minimum || number > maximum)
            throw new InvalidDataException($"{title}须为 {minimum}–{maximum} 的十进制整数");
        return number;
    }
    internal static string Selected(ComboBox box) => box.SelectedItem?.ToString() ?? "";
    internal static void Replace(Panel panel, IEnumerable<Control> children)
    {
        panel.Children.Clear();
        foreach (var child in children) panel.Children.Add(child);
    }
}

internal sealed class CoinPicker
{
    private readonly Dictionary<string, CheckBox> _boxes;
    internal Control View { get; }
    internal event Action? Changed;
    internal CoinPicker(params string[] selected)
    {
        _boxes = Coins.All.ToDictionary(c => c, c => new CheckBox { Content = c, IsChecked = selected.Contains(c), Margin = new(0, 0, 14, 0) });
        View = Ui.Wrap(_boxes.Values.ToArray());
        foreach (var box in _boxes.Values) box.IsCheckedChanged += (_, _) => Changed?.Invoke();
    }
    internal string[] Selected => _boxes.Where(p => p.Value.IsChecked == true).Select(p => p.Key).ToArray();
    internal void Set(params string[] coins) { foreach (var (coin, box) in _boxes) box.IsChecked = coins.Contains(coin); }
}

internal abstract class FeaturePage(AppServices services) : UserControl
{
    protected AppServices Services { get; } = services;
    protected readonly TextBlock Error = Ui.Text("", 13, Brush.Parse("#A23530"));
    protected readonly TextBlock Status = Ui.Text("", 12, Ui.Muted);
    protected readonly ProgressBar Busy = new() { IsIndeterminate = true, Height = 3, IsVisible = false };
    private CancellationTokenSource? _work;
    private long _version;
    internal bool IsBusy { get; private set; }
    internal string ErrorMessage => Error.Text ?? "";
    internal virtual void Enter() { }
    internal virtual void Leave() => Cancel();
    internal virtual void Cancel()
    {
        _version++;
        _work?.Cancel();
        IsBusy = false;
        Busy.IsVisible = false;
    }
    protected async Task RunAsync(Func<CancellationToken, Task> operation)
    {
        Cancel();
        var version = _version;
        _work = new CancellationTokenSource();
        var token = _work.Token;
        IsBusy = true; Busy.IsVisible = true; Error.Text = "";
        try { await operation(token); }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            if (version != _version) return;
            Error.Text = error switch
            {
                CoreException or InvalidDataException => error.Message,
                DllNotFoundException or BadImageFormatException => "无法加载本机计算核心，请使用匹配系统架构的完整应用包",
                _ => "操作失败，请检查输入、文件权限或服务配置"
            };
        }
        finally { if (version == _version) { IsBusy = false; Busy.IsVisible = false; } }
    }
    protected void Layout(string title, string subtitle, params Control[] content)
    {
        var header = Ui.Stack(Ui.Text(title, 26), Ui.Text(subtitle, 13, Ui.Muted));
        var body = Ui.Stack(new Control[] { header, Busy, Error }.Concat(content).Append(Status).ToArray());
        body.Margin = new(28, 24, 28, 30);
        Content = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled };
    }
}
