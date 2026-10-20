using System.Diagnostics;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Avalonia.Styling;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class SettingsPage : FeaturePage
{
    private readonly ComboBox _appearance;
    private readonly CheckBox _auto;
    private readonly ComboBox _coin = Ui.Select(Core.Coins.All, "BTC", 100);
    private readonly ComboBox _role = Ui.Select(new[] { "primary", "backup" }, "primary", 140);
    private readonly ComboBox _provider = new() { MinWidth = 220 };
    private readonly TextBox _url = Ui.Input("HTTPS 服务地址");
    private readonly TextBox _key = Ui.Input("API Key（可选）");
    private readonly StackPanel _networks = new() { Spacing = 8 };
    private readonly TextBox _networkName = Ui.Input("网络名称");
    private readonly TextBox _chainId = Ui.Input("链 ID");
    private readonly TextBox _symbol = Ui.Input("主币符号", "ETH", 120);
    private readonly TextBox _decimals = Ui.Input("精度", "18", 100);
    private readonly TextBox _rpc = Ui.Input("HTTPS RPC");
    private readonly TextBox _explorer = Ui.Input("HTTPS 浏览器地址（可选）");
    private readonly TextBox _networkKey = Ui.Input("网络 API Key（可选）");
    private readonly Expander _networkEditor;
    private string? _editingNetwork;
    private bool _loading;
    internal SettingsPage(AppServices services) : base(services)
    {
        _appearance = Ui.Select(new[] { "light", "dark", "system" }, services.Settings.Current.Appearance, 150);
        _auto = new CheckBox { Content = "导航后自动刷新余额", IsChecked = services.Settings.Current.AutoRefresh };
        _key.PasswordChar = _networkKey.PasswordChar = '●';
        var networkForm = Ui.Stack(Ui.Field("网络名称", _networkName),
            Ui.Wrap(Ui.Field("链 ID", _chainId), Ui.Field("主币符号", _symbol), Ui.Field("小数精度", _decimals)),
            Ui.Field("RPC", _rpc), Ui.Field("区块浏览器", _explorer), Ui.Field("API Key", _networkKey),
            Ui.Wrap(Ui.AsyncButton("保存网络", SaveNetworkAsync, true), Ui.Button("新建网络", ResetNetwork)));
        _networkEditor = new Expander { Header = "新增 / 编辑网络", IsExpanded = false, Content = networkForm, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch };
        _provider.ItemTemplate = new Avalonia.Controls.Templates.FuncDataTemplate<string>((provider, _) => Ui.Text(Providers.Title(provider ?? "")));
        Layout("设置", "外观、本机配置与公开地址余额服务",
            Ui.Panel(Ui.Stack(Ui.Text("外观与行为", 17), Ui.Wrap(_appearance, _auto, Ui.AsyncButton("保存偏好", SavePreferencesAsync)),
                Ui.Text("开启自动查询后，仅将生成的公开地址发送给已配置的余额服务。", 12, Ui.Muted))),
            Ui.Panel(Ui.Stack(Ui.Text("余额服务", 17), Ui.Wrap(Ui.Field("币种", _coin), Ui.Field("服务顺序", _role), Ui.Field("供应商", _provider)),
                Ui.Field("HTTPS 服务地址", _url), Ui.Field("API Key", _key),
                Ui.Wrap(Ui.AsyncButton("保存服务", SaveServiceAsync, true), Ui.AsyncButton("移除当前服务", RemoveServiceAsync)),
                Ui.Text("主服务失败后使用备用服务；失败不会显示为零余额。API Key 保存在当前用户配置文件中。", 12, Ui.Muted))),
            Ui.Panel(Ui.Stack(Ui.Text("自定义 EVM 网络", 17), Ui.Text("选中 ETH 时附加启用的网络，复用 ETH 派生路径；查询前核对链 ID，仅查询主币余额。", 12, Ui.Muted),
                _networks, _networkEditor)),
            Ui.Panel(Ui.Stack(Ui.Text("配置文件", 17), Ui.Text(services.Settings.FilePath, 12, Ui.Muted),
                Ui.Wrap(Ui.Button("打开配置目录", OpenDirectory), Ui.AsyncButton("导入配置", ImportAsync), Ui.AsyncButton("导出配置（含 API Key）", ExportAsync)))));
        _coin.SelectionChanged += (_, _) => LoadService(); _role.SelectionChanged += (_, _) => LoadService();
        _provider.SelectionChanged += (_, _) =>
        {
            if (!_loading) { _url.Text = Providers.DefaultUrl(Ui.Selected(_provider), Ui.Selected(_coin)); _key.Text = ""; }
        };
        LoadService(); RenderNetworks();
        if (services.Settings.LoadError != null) Error.Text = services.Settings.LoadError;
    }
    private void LoadService()
    {
        _loading = true;
        var coin = Ui.Selected(_coin);
        var entries = Ui.Selected(_role) == "backup" ? Services.Settings.Current.Backup : Services.Settings.Current.Primary;
        var service = entries.GetValueOrDefault(coin);
        var choices = Providers.Choices(coin);
        _provider.ItemsSource = choices;
        _provider.SelectedItem = service?.Endpoint.Provider ?? choices.FirstOrDefault();
        _url.Text = service?.Endpoint.Url ?? Providers.DefaultUrl(Ui.Selected(_provider), coin);
        _key.Text = service?.ApiKey ?? "";
        _loading = false;
    }
    private Task SaveServiceAsync() => RunAsync(_ =>
    {
        var config = Services.Settings.Snapshot();
        var entries = Ui.Selected(_role) == "backup" ? config.Backup : config.Primary;
        entries[Ui.Selected(_coin)] = new(new(Ui.Selected(_provider), Ui.Value(_url)), Ui.Value(_key));
        Services.Settings.Save(config); Status.Text = "余额服务已保存在本机"; return Task.CompletedTask;
    });
    private Task RemoveServiceAsync() => RunAsync(_ =>
    {
        var config = Services.Settings.Snapshot();
        (Ui.Selected(_role) == "backup" ? config.Backup : config.Primary).Remove(Ui.Selected(_coin));
        Services.Settings.Save(config); LoadService(); Status.Text = "当前服务已移除"; return Task.CompletedTask;
    });
    private Task SavePreferencesAsync() => RunAsync(_ =>
    {
        var appearance = Ui.Selected(_appearance);
        Services.Settings.Save(Services.Settings.Snapshot() with { Appearance = appearance, AutoRefresh = _auto.IsChecked == true });
        ApplyAppearance(appearance); Status.Text = "偏好设置已保存"; return Task.CompletedTask;
    });
    internal static void ApplyAppearance(string value)
    {
        if (Application.Current is not { } app) return;
        app.RequestedThemeVariant = value switch { "dark" => ThemeVariant.Dark, "system" => ThemeVariant.Default, _ => ThemeVariant.Light };
        Ui.ApplyPalette(app.ActualThemeVariant == ThemeVariant.Dark);
    }
    private Task SaveNetworkAsync() => RunAsync(_ =>
    {
        var config = Services.Settings.Snapshot();
        var network = new EvmNetwork
        {
            Id = _editingNetwork ?? Guid.NewGuid().ToString(), Name = Ui.Value(_networkName), ChainID = Ui.Value(_chainId),
            Symbol = Ui.Value(_symbol), Decimals = (int)Ui.Number(_decimals, 0, 36, "小数精度"), RpcURL = Ui.Value(_rpc),
            ExplorerUrl = Ui.Value(_explorer), ApiKey = Ui.Value(_networkKey),
            Enabled = _editingNetwork == null || config.EvmNetworks.First(n => n.Id == _editingNetwork).Enabled
        };
        config.EvmNetworks.RemoveAll(n => n.Id == network.Id); config.EvmNetworks.Add(network);
        Services.Settings.Save(config); ResetNetwork(); RenderNetworks(); Status.Text = "EVM 网络已保存"; return Task.CompletedTask;
    });
    private void RenderNetworks()
    {
        _networks.Children.Clear();
        foreach (var network in Services.Settings.Current.EvmNetworks)
        {
            var enabled = new CheckBox { Content = $"{network.Name} · {network.Symbol} · Chain {network.ChainID}", IsChecked = network.Enabled };
            enabled.IsCheckedChanged += (_, _) => _ = RunAsync(_ =>
            {
                var config = Services.Settings.Snapshot();
                var index = config.EvmNetworks.FindIndex(n => n.Id == network.Id);
                if (index >= 0) config.EvmNetworks[index] = config.EvmNetworks[index] with { Enabled = enabled.IsChecked == true };
                Services.Settings.Save(config); return Task.CompletedTask;
            });
            _networks.Children.Add(Ui.Wrap(enabled, Ui.Button("编辑", () =>
            {
                _editingNetwork = network.Id; _networkName.Text = network.Name; _chainId.Text = network.ChainID; _symbol.Text = network.Symbol;
                _networkEditor.IsExpanded = true;
                _decimals.Text = network.Decimals.ToString(); _rpc.Text = network.RpcURL; _explorer.Text = network.ExplorerUrl; _networkKey.Text = network.ApiKey;
            }), Ui.AsyncButton("移除", () => RunAsync(_ =>
            {
                var config = Services.Settings.Snapshot(); config.EvmNetworks.RemoveAll(n => n.Id == network.Id);
                Services.Settings.Save(config); if (_editingNetwork == network.Id) ResetNetwork(); RenderNetworks(); return Task.CompletedTask;
            }))));
        }
        if (_networks.Children.Count == 0) _networks.Children.Add(Ui.Text("尚未添加自定义网络", 12, Ui.Muted));
    }
    private void ResetNetwork()
    {
        _editingNetwork = null; _networkName.Text = _chainId.Text = _rpc.Text = _explorer.Text = _networkKey.Text = "";
        _symbol.Text = "ETH"; _decimals.Text = "18";
    }
    private void OpenDirectory()
    {
        try
        {
            var directory = System.IO.Path.GetDirectoryName(Services.Settings.FilePath)!;
            Directory.CreateDirectory(directory); Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true });
        }
        catch { Error.Text = "无法打开配置目录"; }
    }
    private Task ImportAsync() => RunAsync(async token =>
    {
        var files = await TopLevel.GetTopLevel(this)!.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "导入 AllKeyUI 配置", AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("JSON 配置") { Patterns = ["*.json"] }]
        });
        if (files.Count == 0) return;
        await using var stream = await files[0].OpenReadAsync();
        if (stream.CanSeek && stream.Length > 1024 * 1024) throw new InvalidDataException("配置文件过大");
        var config = await JsonSerializer.DeserializeAsync<Configuration>(stream, CoreJson.Options, token) ?? throw new InvalidDataException("配置格式无效");
        Services.Settings.Save(config); LoadService(); RenderNetworks(); _appearance.SelectedItem = config.Appearance;
        _auto.IsChecked = config.AutoRefresh; ApplyAppearance(config.Appearance); Status.Text = "配置已导入";
    });
    private Task ExportAsync() => RunAsync(async token =>
    {
        var file = await TopLevel.GetTopLevel(this)!.StorageProvider.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = "导出配置（包含 API Key）", SuggestedFileName = "allkey-settings.json", DefaultExtension = "json"
        });
        if (file == null) return;
        await using var stream = await file.OpenWriteAsync();
        if (stream.CanSeek) stream.SetLength(0);
        await JsonSerializer.SerializeAsync(stream, Services.Settings.Snapshot(), CoreJson.Options, token);
        Status.Text = "配置已导出，文件包含已保存的 API Key";
    });
}
