using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.LogicalTree;
using Avalonia.Media.Imaging;
using Avalonia.Styling;
using Avalonia.VisualTree;

namespace AllKey.Desktop.Views;

internal static class LayoutChecks
{
    internal static async Task RunAsync(MainWindow window, Action<bool, string> check)
    {
        var originalWidth = window.Width;
        var originalTheme = Application.Current!.RequestedThemeVariant;
        try
        {
            foreach (var width in new[] { 1020, 1260, 1600 })
            {
                window.Width = width;
                foreach (var section in new[] { "keys", "bip39", "electrum", "calculator", "puzzle", "settings" })
                {
                    window.Navigate(section);
                    if (section == "bip39") window.Mnemonics.SelectMode("single");
                    await SettleAsync(window);
                    CheckRows(window.Pages[section], window, check, $"{section} at {width}");
                    SaveScreenshot(window, $"{section}-{width}");
                    if (section is "keys" or "electrum")
                    {
                        var card = window.Pages[section].GetLogicalDescendants().OfType<Border>().FirstOrDefault(b => b.Classes.Contains("address-result"));
                        if (card != null) { card.BringIntoView(); await SettleAsync(window); SaveScreenshot(window, $"{section}-results-{width}"); }
                    }
                    if (section == "settings")
                    {
                        var editor = window.Pages[section].GetLogicalDescendants().OfType<Expander>().First();
                        editor.IsExpanded = true; await SettleAsync(window); editor.BringIntoView(); await SettleAsync(window);
                        CheckRows(window.Pages[section], window, check, $"network editor at {width}");
                        SaveScreenshot(window, $"settings-network-{width}");
                        editor.IsExpanded = false;
                    }
                    if (section == "bip39")
                    {
                        var words = window.Mnemonics.GetLogicalDescendants().OfType<MnemonicWordGrid>().FirstOrDefault();
                        if (words != null) { words.BringIntoView(); await SettleAsync(window); SaveScreenshot(window, $"bip39-results-{width}"); }
                        window.Mnemonics.SelectMode("search");
                        foreach (var expander in window.Mnemonics.GetLogicalDescendants().OfType<Expander>()) expander.IsExpanded = true;
                        await SettleAsync(window);
                        CheckRows(window.Mnemonics, window, check, $"BIP39 matching at {width}");
                        SaveScreenshot(window, $"bip39-search-{width}");
                        window.Mnemonics.SelectMode("directory");
                        await SettleAsync(window);
                        CheckRows(window.Mnemonics.DirectoryPage, window, check, $"BIP39 directory at {width}");
                        SaveScreenshot(window, $"bip39-directory-{width}");
                    }
                }
            }
            Application.Current.RequestedThemeVariant = ThemeVariant.Dark;
            window.Width = 1020; window.Navigate("keys");
            await SettleAsync(window);
            CheckRows(window.Keys, window, check, "private keys dark theme at 1020");
            SaveScreenshot(window, "keys-dark-1020");
        }
        finally { Application.Current.RequestedThemeVariant = originalTheme; window.Width = originalWidth; }
    }
    private static async Task SettleAsync(MainWindow window)
    {
        await Task.Delay(150);
        window.UpdateLayout();
    }
    private static void CheckRows(Control page, Window window, Action<bool, string> check, string label)
    {
        var rowCount = 0;
        foreach (var row in page.GetLogicalDescendants().OfType<WrapPanel>().Where(r => r.IsEffectivelyVisible))
        {
            var children = row.Children.Where(c => c.IsEffectivelyVisible && c.Bounds.Width > 0).ToArray();
            // Test rendered editor geometry rather than control alignment properties.
            foreach (var field in children.OfType<StackPanel>().Where(f => f.Classes.Contains("form-field")))
            {
                var editor = field.Children.Last();
                if (editor is not (TextBox or ComboBox) || editor.Bounds.Height > 60) continue;
                var fieldPoint = field.TranslatePoint(default, row)!.Value;
                var editorPoint = editor.TranslatePoint(default, row)!.Value;
                foreach (var peer in children.Where(c => c != field))
                {
                    var other = peer is StackPanel p && p.Classes.Contains("form-field") ? p.Children.Last() : peer;
                    if (other is not (TextBox or ComboBox or Button)) continue;
                    var peerPoint = peer.TranslatePoint(default, row)!.Value;
                    // Containers on separate wrapped lines must not be compared.
                    var sameLine = Math.Min(fieldPoint.Y + field.Bounds.Height, peerPoint.Y + peer.Bounds.Height) - Math.Max(fieldPoint.Y, peerPoint.Y) > 4;
                    if (!sameLine) continue;
                    var otherPoint = other.TranslatePoint(default, row)!.Value;
                    if (Math.Abs(editorPoint.Y - otherPoint.Y) > 1 || Math.Abs(editor.Bounds.Height - other.Bounds.Height) > 1)
                        throw new InvalidOperationException($"{label}: {editor.GetType().Name} and {other.GetType().Name} misaligned ({editorPoint.Y:F1}/{editor.Bounds.Height:F1} vs {otherPoint.Y:F1}/{other.Bounds.Height:F1})");
                }
            }
            foreach (var child in children)
            {
                var point = child.TranslatePoint(default, row)!.Value;
                if (point.X < -1 || point.X + child.Bounds.Width > row.Bounds.Width + 1)
                    throw new InvalidOperationException($"{label}: wrapped control exceeds available width");
            }
            if (!children.Any(c => c.Classes.Contains("form-field")))
            {
                var controls = children.Where(c => c is Button or TextBox or ComboBox or CheckBox).ToArray();
                for (var i = 0; i < controls.Length; i++)
                    for (var j = i + 1; j < controls.Length; j++)
                    {
                        var a = controls[i].Bounds; var b = controls[j].Bounds;
                        if (Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top) > 4 && Math.Abs(a.Center.Y - b.Center.Y) > 1)
                            throw new InvalidOperationException($"{label}: action controls have different vertical centers");
                    }
            }
            rowCount++;
        }
        check(rowCount > 0, "aligned form and action rows: " + label);
    }
    private static void SaveScreenshot(MainWindow window, string name)
    {
        var directory = Program.Argument("--layout-screenshots");
        if (directory == null) return;
        Directory.CreateDirectory(directory);
        using var bitmap = new RenderTargetBitmap(new PixelSize((int)Math.Ceiling(window.ClientSize.Width), (int)Math.Ceiling(window.ClientSize.Height)));
        bitmap.Render(window);
        bitmap.Save(System.IO.Path.Combine(directory, name + ".png"), PngBitmapEncoderOptions.Default);
    }
}
