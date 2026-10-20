using System.Globalization;
using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal sealed class MnemonicPage : FeaturePage
{
    internal readonly ComboBox Words = Ui.Select(new[] { 12, 15, 18, 21, 24 }, 12, 110);
    internal readonly ComboBox Count = Ui.Select(new[] { 1, 2, 5, 10, 20 }, 1, 110);
    internal readonly ComboBox BtcType = Ui.Select(new[] { "all", "legacy", "segwit", "nested", "taproot" }, "all", 180);
    internal readonly ComboBox Preset = Ui.Select(new[] { "receive", "change" }, "receive", 150);
    internal readonly CoinPicker Coins = new("BTC", "ETH");
    internal readonly TextBox Entropy = Ui.Input("十进制熵索引", "0");
    internal readonly TextBox Phrase = Ui.Input("完整助记词、连续前缀；每个缺词用一个 ?");
    internal readonly TextBox Account = Ui.Input("账户编号 / SOL 起始账户", "0", 180);
    internal readonly TextBox Passphrase = Ui.Input("BIP39 passphrase（可选）");
    internal readonly CheckBox Custom = new() { Content = "使用自定义路径（单币种）" };
    internal readonly CheckBox AutoWords = new() { Content = "自动识别完整词数", IsChecked = true };
    internal readonly TextBox CustomPath = Ui.Input("路径需包含一个 {index}", "m/84'/0'/0'/0/{index}");
    internal readonly TextBox AddressStart = Ui.Input("地址起始索引", "0", 150);
    internal readonly TextBox Target = Ui.Input("目标主网公开地址（仅在本机比较）");
    internal readonly ComboBox TargetCoin = Ui.Select(Core.Coins.All, "BTC", 100);
    internal readonly TextBox MatchLimit = Ui.Input("有效候选上限", "1000", 160);
    internal readonly MnemonicEditor Editor;
    internal readonly MnemonicDirectoryPage DirectoryPage;
    internal readonly AddressResults Results;
    private readonly ContentControl _modeContent = new();
    private readonly Control _detail;
    private readonly Control _searchPanel;
    private readonly Control _jumpPanel;
    private readonly MnemonicWordGrid _wordGrid = new();
    private readonly TextBlock _wordLegend = Ui.Text("高亮单词为补全位置", 11, Ui.Accent);
    private readonly SelectableTextBlock _resultIndex = new() { FontFamily = Ui.Mono, FontSize = 12, Foreground = Ui.Muted, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _resultDerivation = Ui.Text("", 12, Ui.Muted);
    private readonly Control _mnemonicCard;
    private readonly TextBlock _derivation = Ui.Text("尚未生成助记词", 12, Ui.Muted);
    private readonly TextBlock _settingsHint = Ui.Text("", 12, Ui.Muted);
    private readonly TextBlock _match = Ui.Text("", 12, Ui.Muted);
    private readonly Button _search;
    private readonly Button _matchButton;
    private readonly Button _apply;
    private readonly Button _previousAddress;
    private readonly Button _nextAddress;
    private readonly Button _exitPattern;
    private readonly Dictionary<string, Button> _modes = [];
    private readonly Dictionary<string, Button> _navigation = [];
    private MnemonicRequest? _applied;
    private string? _pattern;
    private int _patternBits;
    private bool _updating, _active;
    private CancellationTokenSource? _optionsWork;
    internal Task PendingRefresh { get; private set; } = Task.CompletedTask;
    internal string Mode { get; private set; } = "single";
    internal MnemonicResult? Result { get; private set; }
    internal bool HasPendingSettings => _applied != null &&
        (Custom.IsChecked == true != (_applied.CustomPath.Length > 0) ||
         (Custom.IsChecked != true && Ui.Value(Account) != _applied.Account.ToString(CultureInfo.InvariantCulture)) ||
         (Passphrase.Text ?? "") != _applied.Passphrase || (Custom.IsChecked == true ? Ui.Value(CustomPath) : "") != _applied.CustomPath);
    internal string? ActivePattern => _pattern;
    internal MnemonicRequest? Applied => _applied;

    internal MnemonicPage(AppServices services) : base(services)
    {
        Results = new(services);
        Passphrase.PasswordChar = '●';
        Editor = new(services, Phrase, () => BitSize, DetectWords, () => GenerateAsync("search"));
        _search = Ui.AsyncButton("查找助记词", () => GenerateAsync("search"), true);
        _matchButton = Ui.AsyncButton("匹配目标地址", MatchAsync);
        _apply = Ui.AsyncButton("应用派生设置", () => GenerateAsync());
        _previousAddress = Ui.AsyncButton("上一页地址", () => NavigateAddressesAsync(-1));
        _nextAddress = Ui.AsyncButton("下一页地址", () => NavigateAddressesAsync(1));
        _exitPattern = Ui.Button("退出缺词查询", () => ExitPattern(true));
        Editor.Changed += UpdateControls;
        var advanced = new Expander
        {
            Header = "高级派生设置",
            HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch,
            Content = Ui.Stack(Ui.Wrap(Ui.Field("账户编号 / SOL 起始账户", Account)), Ui.Field("BIP39 passphrase", Passphrase),
                Ui.Text("Passphrase 区分大小写和前后空格；修改后点击应用。任意内容都可派生钱包，不表示密码正确。", 12, Ui.Muted),
                Custom, CustomPath, Ui.Text("自定义路径忽略账户和预设；仅选一个币种。SOL 每层都需硬化，BTC 编码仍由类型决定。", 12, Ui.Muted))
        };
        var matchStart = Ui.Input("地址窗口起点", "0", 150);
        matchStart.TextChanged += (_, _) => { if (AddressStart.Text != matchStart.Text) AddressStart.Text = matchStart.Text; };
        AddressStart.TextChanged += (_, _) => { if (matchStart.Text != AddressStart.Text) matchStart.Text = AddressStart.Text; };
        _searchPanel = Ui.Panel(Ui.Stack(Ui.Text("查找助记词", 18), AutoWords, Editor,
            Ui.Text("完整助记词或从首词开始的连续前缀；缺词时需填满所选词数。↑↓ 选择，回车 / Tab 补全，Esc 关闭，Ctrl+Enter 查找。", 12, Ui.Muted),
            _search, new Expander
            {
                Header = "用已知公开地址匹配缺词候选",
                Content = Ui.Stack(Ui.Field("目标公开地址", Target),
                Ui.Wrap(TargetCoin, Ui.Field("有效候选上限 1–10000", MatchLimit), Ui.Field("地址窗口起点", matchStart), _matchButton),
                Ui.Text("仅核对当前币种、路径、Passphrase 和地址窗口。未匹配不代表其他范围没有结果；重新点击从首个候选开始。", 12, Ui.Muted)),
                HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Stretch
            }, _match));
        _jumpPanel = Ui.Panel(Ui.Stack(Ui.Text("按索引跳转", 15), Ui.Field("助记词熵索引（十进制）", Entropy),
            Ui.Wrap(Ui.AsyncButton("跳转助记词", () => GenerateAsync("jump")), Ui.Field("地址起始索引", AddressStart), Ui.AsyncButton("跳转地址", JumpAddressAsync))));
        var nav = Ui.Wrap();
        foreach (var (op, title) in new[] { ("first", "首组"), ("previous", "上一组"), ("random", "安全随机"), ("next", "下一组"), ("last", "末组") })
        {
            var button = Ui.AsyncButton(title, () => GenerateAsync(op)); _navigation[op] = button; nav.Children.Add(button);
        }
        nav.Children.Add(Ui.Button("取消查找", Cancel)); nav.Children.Add(_exitPattern); nav.Children.Add(Ui.AsyncButton("清空", ClearAsync));
        _mnemonicCard = Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Text("助记词", 18), Ui.Text("✓ 校验通过", 11, ResultRows.Positive), Ui.AsyncButton("复制全部", () => CopyAsync(Result?.Mnemonic ?? ""))),
            _resultDerivation, Ui.Text("助记词导航 · 切换整组助记词", 12, Ui.Muted), nav, _wordGrid, _wordLegend, new Expander { Header = "查看熵索引", Content = _resultIndex }));
        Layout("BIP39 助记词", "助记词导航与地址分页独立 · 钱包派生在本机完成", _searchPanel,
            Ui.Panel(Ui.Stack(Ui.Wrap(Ui.Field("助记词长度", Words), Ui.Field("每类地址 / 页", Count), Ui.Field("BTC 类型", BtcType), Ui.Field("路径预设", Preset)),
                Coins.View, Ui.Text("常用选项自动更新；高级参数点击应用后生效", 12, Ui.Muted), advanced, _derivation, _settingsHint, _apply)),
            _jumpPanel, _mnemonicCard,
            Ui.Wrap(_previousAddress, _nextAddress), Results);
        _detail = (Control)Content!; Content = null;
        DirectoryPage = new(services, OpenDirectoryAsync);
        var modeBar = Ui.Wrap(); modeBar.Margin = new(28, 18, 28, 0);
        foreach (var (mode, title) in new[] { ("single", "单组派生"), ("directory", "多组目录"), ("search", "查找助记词") })
        {
            var button = Ui.Button(title, () => SelectMode(mode)); _modes[mode] = button; modeBar.Children.Add(button);
        }
        var root = new DockPanel(); DockPanel.SetDock(modeBar, Dock.Top); root.Children.Add(modeBar); root.Children.Add(_modeContent); Content = root;
        SetModeContent();
        Words.SelectionChanged += (_, _) =>
        {
            if (_updating) return;
            AutoWords.IsChecked = false; ExitPattern(false); Editor.Inspect(); QueueRefresh("first");
        };
        AutoWords.IsCheckedChanged += (_, _) => { if (AutoWords.IsChecked == true) DetectWords(); Editor.Inspect(); };
        foreach (var combo in new[] { Count, BtcType, Preset }) combo.SelectionChanged += (_, _) => QueueRefresh("current");
        Coins.Changed += () => QueueRefresh("current");
        foreach (var field in new[] { Account, Passphrase, CustomPath, Target, MatchLimit }) field.TextChanged += (_, _) => UpdateControls();
        Custom.IsCheckedChanged += (_, _) => UpdateControls();
        Entropy.KeyDown += async (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; await GenerateAsync("jump"); } };
        AddressStart.KeyDown += async (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; await JumpAddressAsync(); } };
        services.OpenMnemonic = index => { SelectMode("single"); Entropy.Text = index; _ = GenerateAsync("jump"); };
        UpdateControls();
    }
    internal int BitSize => (int)(Words.SelectedItem ?? 12) / 3 * 32;
    private Task CopyAsync(string text) => text.Length == 0 ? Task.CompletedTask : Services.Clipboard.CopyAsync(TopLevel.GetTopLevel(this), text);
    internal void SelectMode(string mode)
    {
        if (mode == Mode) return;
        Cancel();
        if (mode == "single") ExitPattern(false);
        Mode = mode; SetModeContent();
        if (mode == "directory" && _active) DirectoryPage.Enter();
        else if (_active && Result == null) _ = GenerateAsync("first");
        else Editor.Inspect();
    }
    private void SetModeContent()
    {
        _searchPanel.IsVisible = Mode == "search"; _jumpPanel.IsVisible = Mode == "single";
        _modeContent.Content = Mode == "directory" ? DirectoryPage : _detail;
        foreach (var (key, button) in _modes) button.Background = key == Mode ? Ui.Accent : Brushes.Transparent;
    }
    internal override void Enter()
    {
        _active = true;
        if (Mode == "directory") DirectoryPage.Enter();
        else if (Result == null) _ = GenerateAsync("first");
    }
    internal override void Leave()
    {
        _active = false; ClearSensitive(); DirectoryPage.ClearSensitive();
        _ = ClearClipboardAsync();
    }
    private async Task ClearClipboardAsync() { try { await Services.Clipboard.ClearOwnedAsync(); } catch { } }
    internal void DetectWords()
    {
        var count = Regex.Matches(Phrase.Text ?? "", @"\S+").Count;
        if (AutoWords.IsChecked != true || !new[] { 12, 15, 18, 21, 24 }.Contains(count) || Equals(Words.SelectedItem, count)) return;
        _updating = true; Words.SelectedItem = count; _updating = false; _pattern = null; _patternBits = 0; UpdateControls();
    }
    private void QueueRefresh(string operation)
    {
        if (_updating || !_active) return;
        Cancel(); var work = _optionsWork = new();
        PendingRefresh = RefreshLaterAsync(operation, work.Token);
    }
    private async Task RefreshLaterAsync(string operation, CancellationToken token)
    {
        try { await Task.Delay(60, token); _optionsWork = null; await GenerateAsync(Result == null ? "first" : operation, true); }
        catch (OperationCanceledException) { }
    }
    internal Task GenerateAsync(string operation = "current", bool preserveAdvanced = false) => RunAsync(async token =>
    {
        var bits = BitSize;
        var text = Phrase.Text ?? "";
        if (operation == "search") { DetectWords(); bits = BitSize; await ValidateSearchAsync(text, bits, token); }
        var pattern = operation == "jump" ? null : operation == "search" ? (text.Contains('?') ? text : null) : _patternBits == bits ? _pattern : null;
        var request = BuildRequest(bits, preserveAdvanced) with
        {
            Op = operation,
            Index = operation == "search" ? text : operation == "jump" ? Ui.Value(Entropy) : Result?.Index ?? "0",
            Pattern = pattern,
            AddressStart = 0
        };
        var generated = await Services.Core.MnemonicAsync(request, scanned => ShowProgress(token, $"已扫描 {scanned:N0} 个模板组合"), token);
        token.ThrowIfCancellationRequested(); _pattern = pattern; _patternBits = bits;
        Apply(generated, request);
        if (operation == "jump" || operation == "search" && pattern == null) Phrase.Text = "";
    });
    private MnemonicRequest BuildRequest(int bits, bool preserveAdvanced = false)
    {
        if (Coins.Selected.Length == 0) throw new InvalidDataException("请至少选择一个币种");
        var custom = preserveAdvanced && _applied != null ? _applied.CustomPath.Length > 0 : Custom.IsChecked == true;
        var path = preserveAdvanced && _applied != null ? _applied.CustomPath : custom ? Ui.Value(CustomPath) : "";
        if (custom && (Coins.Selected.Length != 1 || path.Length == 0)) throw new InvalidDataException("自定义路径请仅选择一个币种，并填写路径");
        return new()
        {
            BitSize = bits,
            Count = (int)(Count.SelectedItem ?? 1),
            Coins = Coins.Selected,
            BtcType = Ui.Selected(BtcType),
            PathPreset = Ui.Selected(Preset),
            Account = preserveAdvanced && _applied != null ? _applied.Account : custom ? 0 : Ui.Number(Account, 0, int.MaxValue, "账户编号"),
            CustomPath = path,
            Passphrase = preserveAdvanced && _applied != null ? _applied.Passphrase : Passphrase.Text ?? ""
        };
    }
    private async Task ValidateSearchAsync(string text, int bits, CancellationToken token)
    {
        var check = await Services.Core.InspectAsync(text, bits, -1, token);
        if (check.WordCount == 0 || check.WordCount > bits / 32 * 3) throw new InvalidDataException("请输入所选词数以内的完整助记词或连续前缀");
        if (check.InvalidWords.Length > 0) throw new InvalidDataException("请先确认未知单词：" + string.Join("、", check.InvalidWords.Select(w => (w.Position + 1).ToString())));
        if (check.Checksum == "invalid") throw new InvalidDataException("完整助记词校验和无效，请检查单词和顺序");
        if (check.MissingCount > 0 && check.WordCount != bits / 32 * 3) throw new InvalidDataException("使用 ? 时需填满所选词数");
    }
    private void Apply(MnemonicResult result, MnemonicRequest request)
    {
        Result = result; _applied = request with { Index = result.Index, Cursor = null, Op = "current", TargetAddress = null, TargetCoin = null };
        Entropy.Text = result.Index; AddressStart.Text = request.AddressStart.ToString(CultureInfo.InvariantCulture);
        RenderWords(); Results.SetItems(result.Items); Results.SetContext("派生地址", $"共 {Results.Items.Length} 条公开地址"); _resultIndex.Text = result.Index;
        _match.Text = result.MatchedItem is { } m ? $"当前结果已匹配 · {m.Coin} · {m.Path}\n{m.Address}" : "";
        Status.Text = $"熵索引 {result.Index} / {result.Max}";
        UpdateControls();
        if (Services.Settings.Current.AutoRefresh) _ = Results.RefreshAsync(true);
    }
    private void RenderWords()
    {
        _wordGrid.SetWords(Result?.Mnemonic ?? "", _pattern); _wordLegend.IsVisible = _pattern != null;
    }
    private void ShowProgress(CancellationToken token, string value) => Dispatcher.UIThread.Post(() => { if (!token.IsCancellationRequested) Status.Text = value; });
    internal void UpdateControls()
    {
        if (_apply == null) return;
        _mnemonicCard.IsVisible = Result != null;
        var custom = Custom.IsChecked == true;
        Account.IsEnabled = Preset.IsEnabled = !custom; CustomPath.IsVisible = custom;
        _derivation.Text = _applied == null ? "尚未生成助记词" :
            (_applied.CustomPath.Length > 0 ? "自定义路径 " + _applied.CustomPath : $"账户 {_applied.Account} · {(_applied.PathPreset == "change" ? "UTXO 找零" : "标准收款")}") +
            (_applied.Passphrase.Length > 0 ? " · Passphrase 已启用" : " · Passphrase 未启用") + (HasPendingSettings ? " · 参数待应用" : "") + (_pattern != null ? " · 缺词查询中" : "");
        _resultDerivation.Text = _derivation.Text;
        var advancedValid = custom ? Coins.Selected.Length == 1 && Ui.Value(CustomPath).Length > 0 :
            long.TryParse(Ui.Value(Account), out var account) && Ui.Value(Account).All(char.IsAsciiDigit) && account is >= 0 and <= int.MaxValue;
        _settingsHint.Text = Coins.Selected.Length == 0 ? "请至少选择一个币种" : !advancedValid
            ? custom ? "自定义路径需仅选择一个币种，并填写路径" : "账户编号范围为 0–2147483647，请输入十进制整数"
            : HasPendingSettings ? "修改尚未应用；当前结果仍使用上方显示的已应用参数" : "";
        _apply.IsEnabled = Coins.Selected.Length > 0 && advancedValid;
        _search.IsEnabled = Coins.Selected.Length > 0 && advancedValid && Editor.CanSearch;
        _matchButton.IsEnabled = _search.IsEnabled && Regex.Matches(Phrase.Text ?? "", @"\S+").Count == BitSize / 32 * 3 && Ui.Value(Target).Length > 0;
        _exitPattern.IsVisible = _pattern != null;
        var maximum = _applied == null ? 0 : LastAddressStart(_applied);
        _previousAddress.IsEnabled = _applied?.AddressStart > 0;
        _nextAddress.IsEnabled = _applied != null && _applied.AddressStart < maximum;
        if (_navigation.Count > 0)
        {
            _navigation["previous"].IsEnabled = Result == null || Result.Index != "0" || _pattern != null;
            _navigation["next"].IsEnabled = Result == null || Result.Index != Result.Max || _pattern != null;
        }
    }
    private static long LastAddressStart(MnemonicRequest request) => Math.Max(0, (1L << 31) - request.Count -
        (request.CustomPath.Length == 0 && request.Coins.Contains("SOL") ? request.Account : 0));
    internal Task NavigateAddressesAsync(int direction) => RunAsync(async token =>
    {
        if (_applied == null) return;
        var requested = BuildRequest(BitSize);
        var start = Math.Clamp(_applied.AddressStart + direction * requested.Count, 0, LastAddressStart(requested));
        if (start != _applied.AddressStart) await DeriveWindowCoreAsync(start, requested, token);
    });
    internal Task JumpAddressAsync() => RunAsync(async token =>
    {
        if (_applied == null) throw new InvalidDataException("请先生成助记词");
        var requested = BuildRequest(BitSize);
        await DeriveWindowCoreAsync(Ui.Number(AddressStart, 0, LastAddressStart(requested), "地址起始索引"), requested, token);
    });
    private async Task DeriveWindowCoreAsync(long start, MnemonicRequest requested, CancellationToken token)
    {
        if (_applied == null) return;
        var request = requested with { Index = Result!.Index, Pattern = _pattern, AddressStart = start };
        var generated = await Services.Core.MnemonicAsync(request, cancellationToken: token);
        token.ThrowIfCancellationRequested(); Apply(generated, request);
    }
    internal Task MatchAsync() => RunAsync(async token =>
    {
        DetectWords(); var bits = BitSize; var text = Phrase.Text ?? "";
        await ValidateSearchAsync(text, bits, token);
        if (Regex.Matches(text, @"\S+").Count != bits / 32 * 3) throw new InvalidDataException("地址匹配需填满所选词数，每个缺词使用 ?");
        var limit = (int)Ui.Number(MatchLimit, 1, 10000, "有效候选上限");
        if (Ui.Value(Target).Length == 0 || !Coins.Selected.Contains(Ui.Selected(TargetCoin))) throw new InvalidDataException("请填写目标公开地址，并在派生币种中选择该币种");
        var request = BuildRequest(bits) with
        {
            Op = "search",
            Index = text,
            Pattern = text.Contains('?') ? text : null,
            AddressStart = Ui.Number(AddressStart, 0, int.MaxValue, "地址起始索引"),
            TargetAddress = Ui.Value(Target),
            TargetCoin = Ui.Selected(TargetCoin)
        };
        for (var candidate = 1; candidate <= limit; candidate++)
        {
            MnemonicResult generated;
            try { generated = await Services.Core.MnemonicAsync(request, scanned => ShowProgress(token, $"已扫描 {scanned:N0} 个组合 · 已比较 {candidate - 1} 个有效候选"), token); }
            catch (CoreException error) when (error.Message is "已经是最后一个匹配结果" or "该范围内没有符合校验和的匹配结果")
            { throw new InvalidDataException("模板已遍历完毕，在所选路径及地址范围内未匹配目标"); }
            token.ThrowIfCancellationRequested(); Status.Text = $"已比较 {candidate} 个有效候选";
            if (generated.MatchedItem != null)
            {
                _pattern = request.Pattern; _patternBits = bits; Apply(generated, request);
                Status.Text = $"已在当前地址窗口匹配目标 · 比较 {candidate} 个有效候选";
                if (request.Pattern == null) Phrase.Text = "";
                return;
            }
            if (request.Pattern == null) throw new InvalidDataException("该助记词在所选路径与地址窗口内未匹配目标");
            request = request with { Op = "next", Index = generated.Index, Cursor = null };
        }
        throw new InvalidDataException($"已检查 {limit} 个有效候选，当前路径与地址窗口内未匹配目标");
    });
    internal async Task OpenDirectoryAsync(MnemonicResult result, int wordCount, string[] coins, string btcType)
    {
        SelectMode("single"); _updating = true;
        Coins.Set(coins); BtcType.SelectedItem = btcType; Words.SelectedItem = wordCount; Count.SelectedItem = 1;
        Account.Text = "0"; Passphrase.Text = ""; Custom.IsChecked = false; Preset.SelectedItem = "receive";
        _updating = false; Entropy.Text = result.Index; Phrase.Text = "";
        await GenerateAsync("jump");
    }
    private void ExitPattern(bool clearInput)
    {
        Cancel(); _pattern = null; _patternBits = 0;
        if (_applied != null) _applied = _applied with { Pattern = null };
        if (clearInput) Phrase.Text = "";
        Error.Text = ""; RenderWords(); UpdateControls();
    }
    internal void ClearSensitive()
    {
        Cancel(); _updating = true;
        Result = null; _applied = null; _pattern = null; _patternBits = 0;
        Phrase.Text = ""; Passphrase.Text = ""; Target.Text = ""; Entropy.Text = "0"; AddressStart.Text = "0";
        foreach (var input in new[] { Phrase, Passphrase, Target, Entropy, AddressStart }) { input.IsUndoEnabled = false; input.IsUndoEnabled = true; }
        _updating = false; Editor.Clear(); _wordGrid.SetWords(""); _resultIndex.Text = ""; _match.Text = "";
        Results.SetItems([]); Error.Text = ""; Status.Text = ""; UpdateControls();
    }
    private async Task ClearAsync() { ClearSensitive(); DirectoryPage.ClearSensitive(); await ClearClipboardAsync(); Status.Text = "已清空助记词与派生结果"; }
    internal override void Cancel() { base.Cancel(); _optionsWork?.Cancel(); Results?.Cancel(); DirectoryPage?.Cancel(); Editor?.Cancel(); }
}
