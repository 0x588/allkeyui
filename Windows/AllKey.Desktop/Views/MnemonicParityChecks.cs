using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.LogicalTree;
using AllKey.Core;

namespace AllKey.Desktop.Views;

internal static class MnemonicParityChecks
{
    internal static async Task RunAsync(MainWindow window, AppServices services, Action<bool, string> check)
    {
        var m = window.Mnemonics;
        foreach (var name in new[] { "单组派生", "多组目录", "查找助记词" })
            check(m.GetLogicalDescendants().OfType<Button>().Any(b => b.Content?.ToString() == name), "BIP39 mode available: " + name);
        m.SelectMode("single");
        check(m.ActivePattern == null, "return to single mode exits template scope");
        m.Coins.Set("ETH"); await m.PendingRefresh;
        var index = m.Result!.Index;
        m.Account.Text = "1"; m.Passphrase.Text = "TREZOR";
        check(m.HasPendingSettings && m.Applied?.Account == 0 && m.Applied.Passphrase == "", "advanced edits stay pending without changing published wallet");
        m.Count.SelectedItem = 2; await m.PendingRefresh;
        check(m.Result?.Index == index && m.Result.Items.Length == 2 && m.Applied?.Account == 0 && m.Applied.Passphrase == "" && m.HasPendingSettings,
            "count automatically refreshes with applied advanced settings");
        m.Preset.SelectedItem = "change"; await m.PendingRefresh;
        check(m.Result?.Items.Length == 2 && m.HasPendingSettings, "path preset automatically refreshes without committing draft passphrase");
        await m.GenerateAsync();
        check(!m.HasPendingSettings && m.Applied?.Account == 1 && m.Applied.Passphrase == "TREZOR" && m.Result?.Items[0].Path.Contains("/1'/") == true,
            "apply commits account and passphrase");
        m.Passphrase.Text = "draft"; await m.NavigateAddressesAsync(1);
        check(m.Applied?.AddressStart == 2 && m.Applied.Passphrase == "draft" && !m.HasPendingSettings, "explicit address pagination applies edited advanced settings like macOS");
        m.Words.SelectedItem = 15; await m.PendingRefresh;
        check(m.Result?.Index == "0" && m.Result.Mnemonic.Split(' ').Length == 15 && m.Applied?.AddressStart == 0 && m.AutoWords.IsChecked == false,
            "manual word length resets entropy and address page");

        m.SelectMode("search"); m.AutoWords.IsChecked = true;
        m.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 23)) + " art";
        await m.Editor.WaitForInspectionAsync();
        check(Equals(m.Words.SelectedItem, 24) && m.Editor.Inspection?.Checksum == "valid", "input automatically detects 24 words and validates checksum");
        m.Words.SelectedItem = 24; m.AutoWords.IsChecked = false;
        m.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 11)) + " about";
        await m.Editor.WaitForInspectionAsync();
        check(Equals(m.Words.SelectedItem, 24) && m.Editor.CanSearch, "manual longer word count preserves shorter prefix mode");
        m.Words.SelectedItem = 12; await m.PendingRefresh;
        m.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 12)); await m.Editor.WaitForInspectionAsync();
        var previous = m.Result; await m.GenerateAsync("search");
        check(!m.Editor.CanSearch && m.Result == previous && m.ErrorMessage.Length > 0, "invalid complete checksum blocks search and preserves result");

        m.Phrase.Text = " \taban  \nability "; m.Phrase.CaretIndex = 7;
        m.Editor.SelectIssue(0); await m.Editor.WaitForInspectionAsync();
        check(m.Editor.Inspection?.CompletionPosition == 0 && m.Editor.Inspection.Suggestions.Contains("abandon"), "unknown word can select completion at its actual position");
        var down = new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Down };
        m.Phrase.RaiseEvent(down);
        var up = new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Up };
        m.Phrase.RaiseEvent(up);
        check(down.Handled && up.Handled && m.Phrase.IsFocused && m.Editor.CompletionIsOpen, "completion arrow keys retain input focus");
        m.Phrase.RaiseEvent(new KeyEventArgs { RoutedEvent = InputElement.KeyDownEvent, Key = Key.Enter });
        check(m.Phrase.Text == " \tabandon  \nability ", "completion preserves surrounding spaces and newlines");
        m.Phrase.Undo();
        check(m.Phrase.Text == " \taban  \nability ", "word completion supports native undo");

        m.Account.Text = "0"; m.Passphrase.Text = ""; m.Preset.SelectedItem = "receive"; await m.PendingRefresh;
        m.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 11)) + " ?";
        await m.GenerateAsync("search"); var templatePhrase = m.Result!.Mnemonic;
        await m.NavigateAddressesAsync(1);
        check(m.Result.Mnemonic == templatePhrase && m.ActivePattern != null, "template address pagination does not advance mnemonic candidate");
        await m.GenerateAsync("next");
        check(m.Result.Mnemonic != templatePhrase && m.Applied?.AddressStart == 0, "next mnemonic advances template candidate and resets address window");
        var draft = m.Phrase.Text; m.SelectMode("single");
        check(m.ActivePattern == null && m.Applied?.Pattern == null && m.Phrase.Text == draft, "mode switch clears active template but preserves query draft");
        m.Entropy.Text = "-1"; previous = m.Result; await m.GenerateAsync("jump");
        check(m.Result == previous && m.ErrorMessage.Length > 0, "invalid entropy jump preserves published mnemonic");
        m.AddressStart.Text = "2147483648"; previous = m.Result; await m.JumpAddressAsync();
        check(m.Result == previous && m.ErrorMessage.Length > 0, "out-of-range address jump preserves result");

        m.SelectMode("search"); m.Phrase.Text = string.Join(' ', Enumerable.Repeat("abandon", 11)) + " ?";
        m.TargetCoin.SelectedItem = "ETH"; m.Target.Text = "0x9858EfFD232B4033E47d90003D41EC34EcaEda94";
        m.AddressStart.Text = "0"; m.MatchLimit.Text = "1"; await m.MatchAsync();
        check(m.Result?.MatchedItem?.Address == m.Target.Text, "known-address matching publishes actual matching address and path");
        previous = m.Result; m.TargetCoin.SelectedItem = "BTC"; await m.MatchAsync();
        check(m.Result == previous && m.ErrorMessage.Contains("派生币种"), "known-address matching rejects coin outside selected derivation set");
        m.TargetCoin.SelectedItem = "ETH"; m.Target.Text = "0x0000000000000000000000000000000000000000"; m.MatchLimit.Text = "10000";
        var cancelledMatch = m.MatchAsync(); m.Cancel(); await cancelledMatch;
        check(m.Result == previous && !m.IsBusy, "cancelled address matching cannot replace the last published result");

        m.SelectMode("directory"); var d = m.DirectoryPage;
        await WaitAsync(() => !d.IsBusy);
        d.Coins.Set("ETH"); await d.PendingRefresh;
        d.PageSize.SelectedItem = 20; await d.PendingRefresh;
        check(d.Result?.Start == "0" && d.Result.Items.Length == 20 && d.VisibleGroups == 20, "directory page-size and coins automatically regenerate complete groups");
        d.Results.Filter = "有余额";
        check(d.VisibleGroups == 0 && d.Results.Items.Length == 20, "directory balance filter hides groups without changing query collection");
        d.Results.Filter = "全部";
        check(d.VisibleGroups == 20, "directory all filter restores complete mnemonic cards");
        check(services.Settings.Services("ETH").Length == 0, "directory balance smoke uses no configured external service");
        await d.Results.RefreshAsync(true); d.Results.Filter = "失败";
        check(d.VisibleGroups == 20 && d.Results.Items.All(i => d.Results.Record(i)?.Success == false), "directory progressive failures update group filter without treating missing service as zero");
        d.Results.Filter = "全部";
        d.Index.Text = "340282366920938463463374607431768211455"; await d.GenerateAsync("jump");
        check(d.Result?.Items.Length == 1 && d.Result.HasNext == false, "directory accepts maximum entropy as one final group");
        var entry = d.Result!.Items.Single();
        m.Count.SelectedItem = 5; await m.PendingRefresh;
        await d.OpenEntryAsync(entry);
        check(m.Mode == "single" && Equals(m.Count.SelectedItem, 1) && m.Applied?.Account == 0 && m.Applied.Passphrase == "" &&
            m.Applied.CustomPath == "" && m.Result?.Items[0].Address == entry.Items[0].Address,
            "directory detail resets single count and advanced parameters to match card addresses");

        m.Passphrase.Text = "temporary passphrase"; m.Target.Text = "temporary target"; m.Phrase.Text = "temporary phrase";
        window.Navigate("electrum");
        check(m.Result == null && m.Applied == null && m.DirectoryPage.Result == null && m.Phrase.Text == "" && m.Passphrase.Text == "" && m.Target.Text == "" &&
            m.Results.Items.Length == 0 && d.Results.Items.Length == 0 && !m.Phrase.CanUndo,
            "leaving BIP39 clears phrase passphrase targets directory results and undo history");
        var e = window.Electrum; await WaitAsync(() => !e.IsBusy);
        e.Count.SelectedItem = 2; await e.PendingRefresh;
        check(e.Result?.Items.Length == 2, "Electrum count automatically refreshes current seed addresses");
        e.AddressType.SelectedItem = "segwit"; await e.PendingRefresh;
        check(e.Result?.Items.Length == 2 && e.Result.Items.All(i => i.Address.StartsWith("bc1")), "Electrum type automatically refreshes current result");
        e.Phrase.Text = e.Result!.Mnemonic; await e.GenerateAsync("search");
        check(e.Phrase.Text == "" && e.Result != null, "Electrum successful lookup clears input draft");
        window.Navigate("calculator");
        check(e.Result == null && e.Results.Items.Length == 0 && e.Phrase.Text == "", "leaving Electrum clears sensitive result");
    }
    private static async Task WaitAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(30);
        while (!condition()) { if (DateTime.UtcNow > deadline) throw new InvalidOperationException("UI state timeout"); await Task.Delay(10); }
    }
}
