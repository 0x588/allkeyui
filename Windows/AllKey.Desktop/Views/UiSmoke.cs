using System.Text.Json;
using Avalonia.Controls;
using Avalonia.LogicalTree;
using Avalonia.Interactivity;
using Avalonia.Styling;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal static class UiSmoke
{
    internal static async Task RunAsync(MainWindow window, AppServices services, string? reportPath)
    {
        var checks = new List<string>();
        string? failure = null;
        void Check(bool condition, string name)
        {
            if (!condition) throw new InvalidOperationException(name);
            checks.Add(name);
        }
        try
        {
            window.Navigate("keys");
            window.Keys.Index.Text = "1"; window.Keys.Coins.Set("ETH");
            var generate = window.Keys.GetLogicalDescendants().OfType<Button>().First(b => b.Content?.ToString() == "生成地址");
            generate.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            while (window.Keys.IsBusy) await Task.Delay(10);
            Check(window.Keys.Result?.Items.Single().Address == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", "private key page derives ETH vector");
            await window.Keys.GenerateAsync("next");
            Check(window.Keys.Result?.Index == "2", "private key next navigation");
            var previous = window.Keys.Result;
            window.Keys.Index.Text = "xyz"; await window.Keys.GenerateAsync();
            Check(window.Keys.ErrorMessage.Length > 0 && window.Keys.Result == previous, "invalid input preserves previous valid page");

            window.Navigate("bip39");
            window.Mnemonics.Coins.Set("ETH"); window.Mnemonics.Entropy.Text = "0";
            await window.Mnemonics.GenerateAsync("jump");
            Check(window.Mnemonics.Result?.Items[0].Address == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", "BIP39 page derives canonical vector");
            var phrase = window.Mnemonics.Result!.Mnemonic;
            await window.Mnemonics.NavigateAddressesAsync(1);
            Check(window.Mnemonics.Result?.Index == "0" && window.Mnemonics.Result.Mnemonic == phrase && window.Mnemonics.Result.Items[0].Path.EndsWith("/1"), "address pagination preserves mnemonic");
            window.Mnemonics.SelectMode("search");
            window.Mnemonics.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 11)) + " ?";
            await window.Mnemonics.GenerateAsync("search");
            Check(window.Mnemonics.Result?.Mnemonic == phrase, "missing-word template lookup");
            await window.Mnemonics.DirectoryPage.GenerateAsync("first");
            Check(window.Mnemonics.DirectoryPage.Result?.Items.Length == 10, "mnemonic directory first page");
            await window.Mnemonics.DirectoryPage.GenerateAsync("next");
            Check(window.Mnemonics.DirectoryPage.Result?.Start == "10", "mnemonic directory independent pagination");

            await MnemonicParityChecks.RunAsync(window, services, Check);

            window.Navigate("electrum"); await window.Electrum.GenerateAsync();
            Check(window.Electrum.Result?.Items.Length > 0 && window.Electrum.ErrorMessage.Length == 0, "Electrum page generates addresses");
            window.Navigate("calculator"); window.Calculator.SelectOperation("sha256-text"); window.Calculator.Input.Text = "abc";
            await window.Calculator.CalculateAsync();
            Check(window.Calculator.Output.Text == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "calculator SHA256 vector");
            window.Calculator.SelectOperation("ascii-to-hex"); window.Calculator.Input.Text = " 中\n";
            await window.Calculator.CalculateAsync();
            Check(window.Calculator.Output.Text == "20e4b8ad0a", "calculator preserves Chinese and whitespace");
            window.Calculator.Batch.IsChecked = true; window.Calculator.Input.Text = "abc\n中";
            await window.Calculator.CalculateAsync();
            Check(window.Calculator.Output.Text?.Contains("[2] e4b8ad") == true, "calculator line batching");

            window.Navigate("puzzle"); Check(window.Puzzles.Catalog.Puzzles.Length == 160, "puzzle catalog loads 160 entries");
            window.Navigate("keys"); await window.Keys.EnterPuzzleAsync(window.Puzzles.Catalog.Puzzles[0], "first");
            Check(window.Keys.Result?.Items.Single().Address == window.Puzzles.Catalog.Puzzles[0].Address, "puzzle range enters private key page");
            window.Navigate("settings"); Check(window.Pages.Count == 6, "all six sections instantiate");
            var settingsPage = window.Pages["settings"];
            var appearance = settingsPage.GetLogicalDescendants().OfType<ComboBox>().First(c => c.ItemsSource is string[] choices && choices.Contains("dark"));
            var save = settingsPage.GetLogicalDescendants().OfType<Button>().First(b => b.Content?.ToString() == "保存偏好");
            appearance.SelectedItem = "dark"; save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            while (settingsPage.IsBusy) await Task.Delay(10);
            Check(services.Settings.Current.Appearance == "dark" && Avalonia.Application.Current!.RequestedThemeVariant == ThemeVariant.Dark, "settings UI saves and applies dark theme");
            appearance.SelectedItem = "light"; save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            while (settingsPage.IsBusy) await Task.Delay(10);
            Check(new SettingsStore(System.IO.Path.GetDirectoryName(services.Settings.FilePath)).Current.Appearance == "light", "settings UI persists appearance");

            await services.Clipboard.CopyAsync(window, "AllKeyUI public clipboard check");
            var clipboard = window.Clipboard ?? throw new InvalidOperationException("clipboard unavailable");
            Check(await clipboard.TryGetTextAsync() == "AllKeyUI public clipboard check", "desktop clipboard copy");
            await clipboard.SetTextAsync("AllKeyUI user replacement"); await services.Clipboard.ClearOwnedAsync();
            Check(await clipboard.TryGetTextAsync() == "AllKeyUI user replacement", "clipboard clear preserves replacement");
            await services.Clipboard.CopyAsync(window, "AllKeyUI temporary copy"); await services.Clipboard.ClearOwnedAsync();
            Check(string.IsNullOrEmpty(await clipboard.TryGetTextAsync()), "clipboard clear releases owned value");
            await ResultListChecks.RunAsync(window, services, Check);
            await LayoutChecks.RunAsync(window, Check);
            window.Keys.ExitPuzzle();
            await window.Keys.ClearAsync(); window.Keys.Coins.Set("BTC", "ETH"); window.Keys.Index.Text = "1"; window.Keys.BtcType.SelectedItem = "all";
            await window.Keys.GenerateAsync(); window.Navigate("keys");
        }
        catch (Exception error) { failure = error.Message; }
        var report = new { status = failure == null ? "passed" : "failed", platform = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
            architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), checks, error = failure };
        var json = JsonSerializer.Serialize(report, CoreJson.Options);
        window.Title = failure == null ? "AllKeyUI · UI 验证通过" : "AllKeyUI · UI 验证失败";
        if (reportPath != null) { Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(reportPath))!); await File.WriteAllTextAsync(reportPath, json); }
        if (Program.Arguments.Contains("--exit-after-smoke")) window.Close();
    }
}
