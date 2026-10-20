using System.Text.RegularExpressions;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Primitives.PopupPositioning;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Media;
using Avalonia.VisualTree;
using AllKey.Core;

namespace AllKey.Desktop.Views;

// Uses the production word list and TextBox's selection replacement/undo support.
internal sealed class MnemonicEditor : UserControl
{
    private readonly AppServices _services;
    private readonly TextBox _input;
    private readonly Func<int> _bits;
    private readonly Action _detect;
    private readonly Func<Task> _search;
    private readonly TextBlock _feedback = Ui.Text("", 12, Ui.Muted);
    private readonly WrapPanel _issues = Ui.Wrap();
    private readonly ListBox _suggestions = new() { MaxHeight = 220, MinWidth = 180, Focusable = false };
    private readonly Popup _popup;
    private CancellationTokenSource? _inspection;
    private string? _source;
    private int _sourceBits;
    private bool _replacing;
    private int? _dismissedCaret;
    internal event Action? Changed;
    internal MnemonicInspection? Inspection { get; private set; }
    internal bool CompletionIsOpen => _popup.IsOpen;
    internal Task PendingInspection { get; private set; } = Task.CompletedTask;
    internal async Task WaitForInspectionAsync()
    {
        await Task.Yield();
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (_source != _input.Text || _sourceBits != _bits() || Inspection == null)
        {
            if (DateTime.UtcNow > deadline) throw new InvalidOperationException("Input inspection timeout");
            await Task.Delay(10);
        }
    }
    internal bool CanSearch => _source == _input.Text && _sourceBits == _bits() && Inspection is { WordCount: > 0 } i &&
        i.WordCount <= _bits() / 32 * 3 && i.InvalidWords.Length == 0 && i.Checksum != "invalid" && (i.MissingCount == 0 || i.WordCount == _bits() / 32 * 3);
    private TextPresenter? InputPresenter => _input.GetVisualDescendants().OfType<TextPresenter>().FirstOrDefault();
    internal MnemonicEditor(AppServices services, TextBox input, Func<int> bits, Action detect, Func<Task> search)
    {
        _services = services; _input = input; _bits = bits; _detect = detect; _search = search;
        input.AcceptsReturn = true; input.MinHeight = 92; input.TextWrapping = TextWrapping.Wrap; input.FontFamily = Ui.Mono;
        input.VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Top;
        _popup = new Popup
        {
            PlacementTarget = input,
            Placement = PlacementMode.AnchorAndGravity,
            PlacementAnchor = PopupAnchor.BottomLeft,
            PlacementGravity = PopupGravity.BottomRight,
            IsLightDismissEnabled = true,
            TakesFocusFromNativeControl = false,
            Child = Ui.Panel(_suggestions)
        };
        Content = Ui.Stack(input, _feedback, _issues, _popup);
        input.TextChanged += (_, _) => { _dismissedCaret = null; if (!_replacing) _detect(); Inspect(); };
        input.PropertyChanged += (_, e) => { if (e.Property == TextBox.CaretIndexProperty && !_replacing) Inspect(); };
        input.LostFocus += (_, _) => { if (!_suggestions.IsPointerOver) _popup.IsOpen = false; };
        input.AddHandler(InputElement.KeyDownEvent, OnKeyDown, RoutingStrategies.Tunnel);
        _suggestions.AddHandler(InputElement.PointerPressedEvent, (_, e) =>
        {
            var item = (e.Source as Visual)?.GetSelfAndVisualAncestors().OfType<ListBoxItem>().FirstOrDefault();
            if (item?.Content is not string word) return;
            Accept(word); e.Handled = true;
        }, RoutingStrategies.Tunnel);
        _popup.Closed += (_, _) => _dismissedCaret = _input.CaretIndex;
    }
    internal void Inspect()
    {
        Cancel(); Inspection = null; _source = null; Changed?.Invoke();
        var token = (_inspection = new()).Token;
        PendingInspection = InspectLaterAsync(token);
    }
    private async Task InspectLaterAsync(CancellationToken token)
    {
        try
        {
            await Task.Delay(120, token);
            var text = _input.Text ?? ""; var bits = _bits();
            if (text.Length == 0) { _feedback.Text = "输入后显示词数、词表与校验和状态"; _issues.Children.Clear(); return; }
            var caret = _input.CaretIndex;
            var tokens = Regex.Matches(text, @"\S+").Cast<Match>().ToArray();
            var position = Array.FindIndex(tokens, t => caret > t.Index && caret <= t.Index + t.Length && t.Value != "?");
            var check = await _services.Core.InspectAsync(text, bits, position, token);
            token.ThrowIfCancellationRequested();
            if (_input.Text != text || bits != _bits()) return;
            Inspection = check; _source = text; _sourceBits = bits;
            var checksum = check.Checksum switch { "valid" => "通过", "invalid" => "无效", "missing" => "缺词待补全", _ => "待完整输入" };
            _feedback.Text = $"词数 {check.WordCount} / {bits / 32 * 3} · 词表 {(check.InvalidWords.Length == 0 ? "有效" : "有未知词")} · 校验和 {checksum}" +
                (check.MissingCount > 0 ? $" · 缺词 {check.MissingCount}" : "");
            _issues.Children.Clear();
            foreach (var issue in check.InvalidWords)
            {
                var button = Ui.Button($"第 {issue.Position + 1} 词：{issue.Word}", () => SelectIssue(issue.Position));
                _issues.Children.Add(button);
            }
            _suggestions.ItemsSource = check.Suggestions; _suggestions.SelectedIndex = check.Suggestions.Length > 0 ? 0 : -1;
            if (position >= 0 && check.Suggestions.Length > 0 && _input.IsFocused && _dismissedCaret != caret && string.IsNullOrEmpty(InputPresenter?.PreeditText))
            {
                if (InputPresenter is { } presenter)
                {
                    var rect = presenter.TextLayout.HitTestTextPosition(caret);
                    var point = presenter.TranslatePoint(rect.Position, _input) ?? new Point(8, 24);
                    _popup.PlacementRect = new Rect(point, rect.Size);
                }
                _popup.IsOpen = true;
            }
            else _popup.IsOpen = false;
            Changed?.Invoke();
        }
        catch (OperationCanceledException) { }
        catch { if (!token.IsCancellationRequested) _feedback.Text = "暂时无法校验，请重新输入后重试"; }
    }
    private async void OnKeyDown(object? sender, KeyEventArgs e)
    {
        if (!string.IsNullOrEmpty(InputPresenter?.PreeditText)) return;
        if (e.Key == Key.Enter && (e.KeyModifiers & (KeyModifiers.Control | KeyModifiers.Meta)) != 0)
        { e.Handled = true; if (CanSearch) await _search(); return; }
        if (!_popup.IsOpen) return;
        if (e.Key == Key.Escape) { e.Handled = true; _popup.IsOpen = false; return; }
        if (e.Key is Key.Up or Key.Down)
        {
            e.Handled = true;
            var count = Inspection?.Suggestions.Length ?? 0;
            if (count > 0) { _suggestions.SelectedIndex = (_suggestions.SelectedIndex + (e.Key == Key.Down ? 1 : count - 1)) % count; _suggestions.ScrollIntoView(_suggestions.SelectedItem!); }
        }
        else if (e.Key is Key.Enter or Key.Tab && _suggestions.SelectedItem is string word) { e.Handled = true; Accept(word); }
    }
    internal void SelectIssue(int position)
    {
        var tokens = Regex.Matches(_input.Text ?? "", @"\S+");
        if (position < 0 || position >= tokens.Count) return;
        _input.Focus(); _input.CaretIndex = tokens[position].Index + tokens[position].Length; _dismissedCaret = null; Inspect();
    }
    internal void Accept(string word)
    {
        if (_source != _input.Text || Inspection?.Suggestions.Contains(word) != true) return;
        var tokens = Regex.Matches(_input.Text ?? "", @"\S+");
        var position = Inspection.CompletionPosition;
        if (position < 0 || position >= tokens.Count) return;
        var target = tokens[position];
        _replacing = true;
        _input.SelectionStart = target.Index; _input.SelectionEnd = target.Index + target.Length;
        _input.SelectedText = word;
        _input.CaretIndex = target.Index + word.Length;
        _input.SelectionStart = _input.SelectionEnd = _input.CaretIndex;
        _replacing = false; _popup.IsOpen = false; _input.Focus(); _dismissedCaret = _input.CaretIndex; Inspect();
    }
    internal void Cancel() { _inspection?.Cancel(); _popup.IsOpen = false; }
    internal void Clear()
    {
        Cancel(); Inspection = null; _source = null; _suggestions.ItemsSource = null;
        _issues.Children.Clear(); _feedback.Text = ""; _input.IsUndoEnabled = false; _input.IsUndoEnabled = true;
    }
}
