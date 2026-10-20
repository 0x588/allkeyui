using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class MainWindow : Window
{
    internal readonly Dictionary<string, FeaturePage> Pages;
    internal readonly PrivateKeysPage Keys;
    internal readonly MnemonicPage Mnemonics;
    internal readonly ElectrumPage Electrum;
    internal readonly PuzzlePage Puzzles;
    internal readonly CalculatorPage Calculator;
    private readonly ContentControl _content = new();
    private readonly AppServices _services;
    private readonly Dictionary<string, Button> _navigation = [];
    private string _section = "keys";
    private bool _closing;
    internal MainWindow(AppServices services)
    {
        _services = services;
        Title = "AllKeyUI"; Width = 1260; Height = 860; MinWidth = 1020; MinHeight = 700;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new("Microsoft YaHei UI,PingFang SC,Segoe UI"); FontSize = 13;
        Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://AllKeyUI/Assets/app.ico")));
        Keys = new(services); Mnemonics = new(services); Electrum = new(services); Puzzles = new(services); Calculator = new(services);
        Pages = new() { ["keys"] = Keys, ["bip39"] = Mnemonics, ["electrum"] = Electrum, ["puzzle"] = Puzzles, ["calculator"] = Calculator, ["settings"] = new SettingsPage(services) };
        var root = new Grid { ColumnDefinitions = new ColumnDefinitions("236,*"), Background = Ui.CanvasFill };
        var sidebar = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), Background = Brush.Parse("#182923") };
        var brand = Ui.Stack(Ui.Text("ALLKEY", 25, Ui.Accent), Ui.Text("LOCAL KEYSPACE EXPLORER", 10, Brush.Parse("#9AAFA3")));
        brand.Margin = new(24, 30, 16, 32); sidebar.Children.Add(brand);
        var nav = new StackPanel { Spacing = 6, Margin = new(12, 0) }; Grid.SetRow(nav, 1); sidebar.Children.Add(nav);
        foreach (var item in new[]
        {
            ("keys", "01", "私钥库", "HEX / WIF · 多币种"), ("bip39", "02", "BIP39 助记词", "单组详情与多组目录"),
            ("electrum", "03", "Electrum", "Standard / SegWit"), ("puzzle", "04", "BTC Puzzle", "公开题目与范围浏览"),
            ("calculator", "05", "Crypto Calculator", "密钥、地址与密码学转换"), ("settings", "06", "设置", "外观与余额查询服务")
        })
        {
            var label = Ui.Stack(Ui.Text(item.Item3, 15, Brushes.White), Ui.Text(item.Item4, 11, Brush.Parse("#A4B6AA")));
            label.Spacing = 4;
            var button = new Button { Content = Ui.Row(Ui.Text(item.Item2, 11, Ui.Accent), label), HorizontalContentAlignment = HorizontalAlignment.Left,
                HorizontalAlignment = HorizontalAlignment.Stretch, Padding = new(14, 14), CornerRadius = new(8), Background = Brushes.Transparent, BorderThickness = new(0) };
            var key = item.Item1; button.Click += (_, _) => Navigate(key); nav.Children.Add(button); _navigation[key] = button;
        }
        var privacy = new Border { BorderBrush = Brush.Parse("#395344"), BorderThickness = new(1), CornerRadius = new(8), Padding = new(14), Margin = new(18, 20),
            Child = Ui.Stack(Ui.Text("●  本地计算", 13, Brush.Parse("#BCDFB6")), Ui.Text("钱包密钥留在此设备", 11, Brush.Parse("#A4B6AA"))) };
        Grid.SetRow(privacy, 2); sidebar.Children.Add(privacy);
        root.Children.Add(sidebar); Grid.SetColumn(_content, 1); root.Children.Add(_content); Content = root;
        services.OpenPuzzle = (puzzle, operation) => { Navigate("keys"); _ = Keys.EnterPuzzleAsync(puzzle, operation); };
        Navigate("keys");
        Opened += async (_, _) =>
        {
            if (Program.Arguments.Contains("--ui-smoke")) await UiSmoke.RunAsync(this, services, Program.Argument("--report"));
        };
        Closing += async (_, e) =>
        {
            if (_closing) return;
            e.Cancel = true; _closing = true;
            foreach (var page in Pages.Values) page.Leave();
            try { await services.Clipboard.ClearOwnedAsync(); } catch { }
            Close();
        };
    }
    internal void Navigate(string section)
    {
        if (_content.Content == Pages.GetValueOrDefault(section)) return;
        if (Pages.TryGetValue(_section, out var previous)) previous.Leave();
        _section = section; _content.Content = Pages[section];
        Pages[section].Enter();
        foreach (var (key, button) in _navigation) button.Background = key == section ? Brush.Parse("#314A3A") : Brushes.Transparent;
    }
}
