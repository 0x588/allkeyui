using System.Net;
using System.Text;
using System.Text.Json;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.Versioning;
using AllKey.Core;

namespace AllKey.Verification;

public static class VerificationSuite
{
    public static async Task<int> RunAsync(string? reportPath = null)
    {
        var checks = new List<string>();
        var directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "AllKeyTests-" + Guid.NewGuid().ToString("N"));
        string? failure = null;
        void Check(bool condition, string name)
        {
            if (!condition) throw new InvalidOperationException(name);
            checks.Add(name); Console.WriteLine("PASS " + name);
        }
        try
        {
            var core = new CoreClient();
            var key = await core.KeysAsync("1", ["ETH"]);
            Check(key.Items.Single().Address == "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", "ETH scalar-one vector");
            var wif = await core.KeysAsync("KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn", ["BTC"], btcType: "legacy");
            Check(wif.Index == "1" && wif.WifCompressed == true && wif.Items.Single().Address == "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", "WIF normalization");
            var sevenCoins = await core.KeysAsync("1", Coins.All);
            Check(sevenCoins.Items.Select(i => i.Coin).Distinct().Order().SequenceEqual(Coins.All.Order()) && sevenCoins.Items.All(i => i.Address.Length > 0), "all seven coins derive in native library");
            try { await core.KeysAsync("xyz", ["BTC"]); throw new InvalidOperationException("invalid scalar accepted"); }
            catch (CoreException e) { Check(e.Code == "invalid_request", "structured error envelope"); }
            var mnemonic = await core.MnemonicAsync(new() { Coins = ["BTC"], BtcType = "segwit" });
            Check(mnemonic.Items.Single().Address == "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", "BIP84 vector");
            var pattern = await core.MnemonicAsync(new() { Coins = ["ETH"], Op = "search", Index = string.Join(' ', Enumerable.Repeat("abandon", 11)) + " ?" });
            Check(pattern.Index == "0" && pattern.Items[0].Address == "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", "missing-word search batches");
            var matched = await core.MnemonicAsync(new() { Coins = ["ETH"], Op = "search", Index = pattern.Mnemonic,
                TargetAddress = "0x9858effd232b4033e47d90003d41ec34ecaeda94", TargetCoin = "ETH" });
            Check(matched.MatchedItem?.Address == pattern.Items[0].Address, "known-address local matching");
            var custom = await core.MnemonicAsync(new() { Coins = ["ETH"], CustomPath = "m/44'/60'/0'/0/{index}" });
            Check(custom.Items[0].Address == pattern.Items[0].Address && custom.Items[0].Path == "m/44'/60'/0'/0/0", "custom derivation path serialization");
            var page = await core.DirectoryAsync(128, 10, ["ETH"], "0", "first", "all");
            Check(page.Items.Length == 10 && page.Start == "0" && page.End == "9", "mnemonic directory bounds");
            var inspection = await core.InspectAsync("abndon about", 128, 0);
            Check(inspection.Suggestions.First() == "abandon" && inspection.InvalidWords.Single().Position == 0, "word completion and typo position");
            Check((await core.ElectrumAsync("0", 1, "standard", "current")).Items.Length == 1, "Electrum standard");
            Check(await core.CalculateAsync("ascii-to-hex", " 中\n") == "20e4b8ad0a", "UTF8 and whitespace through production bridge");
            using (var cancelled = new CancellationTokenSource())
            {
                cancelled.Cancel();
                try { await core.CalculateAsync("sha256-text", "abc", cancellationToken: cancelled.Token); throw new InvalidOperationException("cancellation ignored"); }
                catch (OperationCanceledException) { Check(true, "cancelled queued call does not enter native bridge"); }
            }
            var store = new SettingsStore(directory);
            var config = new Configuration { Primary = new() { ["BTC"] = new(new("blockchain", "https://primary.test/balance"), "") },
                Backup = new() { ["BTC"] = new(new("blockchain", "https://backup.test/balance"), "") } };
            store.Save(config);
            var loaded = new SettingsStore(directory);
            Check(loaded.LoadError == null && loaded.Services("BTC").Length == 2, "configuration atomic round trip");
            if (!OperatingSystem.IsWindows()) Check((File.GetUnixFileMode(store.FilePath) & (UnixFileMode.GroupRead | UnixFileMode.OtherRead)) == 0, "configuration user-only file mode");
            else
            {
                Check(HasUserOnlyWindowsAccess(store.FilePath), "configuration Windows ACL grants current user only");
            }
            var old = await File.ReadAllTextAsync(store.FilePath);
            try { store.Save(config with { Version = 99 }); throw new InvalidOperationException("invalid config saved"); }
            catch (InvalidDataException) { Check(await File.ReadAllTextAsync(store.FilePath) == old, "invalid configuration preserves previous file"); }
            await File.WriteAllTextAsync(store.FilePath, "{broken");
            var corrupted = new SettingsStore(directory);
            Check(corrupted.LoadError != null && corrupted.Current.Primary.Count == 0 && !corrupted.Current.AutoRefresh && await File.ReadAllTextAsync(store.FilePath) == "{broken", "corrupt configuration disables services without overwriting file");
            await File.WriteAllTextAsync(store.FilePath, old);
            const string address = "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH";
            var publicAddress = new PublicAddress("BTC", address);
            var fixtures = new (string Provider, string Coin, string Json, string Expected)[]
            {
                ("blockchain", "BTC", "{\"" + address + "\":{\"final_balance\":1,\"n_tx\":2,\"total_received\":3}}", "0.00000001 BTC"),
                ("blockcypher", "DOGE", "{\"address\":\"" + address + "\",\"final_balance\":123456789,\"n_tx\":2}", "1.23456789 DOGE"),
                ("blockchair", "LTC", "{\"context\":{\"code\":200},\"data\":{\"" + address + "\":{\"address\":{\"balance\":100000000}}}}", "1 LTC"),
                ("etherscan", "ETH", "{\"status\":\"1\",\"result\":\"1\"}", "0.000000000000000001 ETH"),
                ("evmRPC", "BSC", "{\"result\":\"0xde0b6b3a7640000\"}", "1 BNB"),
                ("tronGrid", "TRX", "{\"success\":true,\"data\":[{\"balance\":1234567}]}", "1.234567 TRX"),
                ("solanaRPC", "SOL", "{\"result\":{\"value\":1}}", "0.000000001 SOL"),
                ("chainz", "LTC", "{\"" + address + "\":\"0.00000001\"}", "0.00000001 LTC"),
                ("okLink", "DOGE", "{\"code\":\"0\",\"data\":[{\"balance\":\"1.25\",\"transactionCount\":\"2\"}]}", "1.25 DOGE")
            };
            foreach (var fixture in fixtures)
            {
                using var json = JsonDocument.Parse(fixture.Json);
                Check(BalanceClient.Parse(json.RootElement, new(fixture.Coin, address), fixture.Provider).Balance == fixture.Expected, fixture.Provider + " precision and parsing");
            }
            Check(BalanceClient.HexInteger("0xffffffffffffffff") == "18446744073709551615" && BalanceRecord.NonZero("1e-100 ETH"), "large integers and tiny nonzero amounts");
            using (var invalid = JsonDocument.Parse("{}"))
            {
                try { BalanceClient.Parse(invalid.RootElement, publicAddress, "blockchain"); throw new InvalidOperationException("malformed balance accepted"); }
                catch (KeyNotFoundException) { Check(true, "missing balance is not zero"); }
            }
            var primaryCalls = 0; var backupCalls = 0;
            using var handler = new FixtureHandler(async request =>
            {
                await Task.Delay(15);
                if (request.RequestUri!.Host == "primary.test")
                {
                    Interlocked.Increment(ref primaryCalls);
                    var response = new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
                    response.Headers.RetryAfter = new(TimeSpan.Zero); return response;
                }
                Interlocked.Increment(ref backupCalls);
                return new(HttpStatusCode.OK) { Content = new StringContent(fixtures[0].Json, Encoding.UTF8, "application/json") };
            });
            using var http = new HttpClient(handler);
            using var balances = new BalanceClient(store, http, TimeSpan.Zero);
            var results = await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => balances.FetchAsync(publicAddress)));
            Check(results.All(r => r.Success) && primaryCalls == 2 && backupCalls == 1, "shared requests and primary-to-backup fallback");
            Check((await balances.FetchAsync(publicAddress)).Cached && backupCalls == 1, "successful balance cache");
            await balances.FetchAsync(publicAddress, true);
            Check(backupCalls == 2, "force refresh bypasses cache");
            Check(handler.Bodies.All(b => !b.Contains("privateKey") && !b.Contains("mnemonic") && !b.Contains("passphrase")), "network boundary contains no wallet secrets");

            var network = new EvmNetwork { Name = "Fixture", ChainID = "137", Symbol = "POL", RpcURL = "https://network.test/rpc" };
            var nc = store.Snapshot(); nc.EvmNetworks.Add(network); store.Save(nc);
            var balanceCalled = false;
            using var chainHandler = new FixtureHandler(async request =>
            {
                var text = await request.Content!.ReadAsStringAsync();
                if (text.Contains("eth_getBalance")) balanceCalled = true;
                return new(HttpStatusCode.OK) { Content = new StringContent("{\"result\":\"0x1\"}") };
            });
            using var chainHttp = new HttpClient(chainHandler);
            using var chains = new BalanceClient(store, chainHttp, TimeSpan.Zero);
            var mismatched = await chains.FetchAsync(new("ETH", "0x9858EfFD232B4033E47d90003D41EC34EcaEda94", network));
            Check(!mismatched.Success && !balanceCalled && mismatched.Error!.Contains("链 ID"), "wrong EVM chain stops balance query");
            var projected = store.Project([mnemonic.Items[0] with { Coin = "ETH" }]);
            Check(projected.Length == 2 && projected[1].Network?.ChainID == "137", "custom EVM address projection");
        }
        catch (Exception error) { failure = error.GetType().Name + ": " + error.Message; Console.Error.WriteLine("FAIL " + failure); }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
        var report = new { status = failure == null ? "passed" : "failed", platform = RuntimeInformation.OSDescription,
            architecture = RuntimeInformation.ProcessArchitecture.ToString(), checks, error = failure };
        var output = JsonSerializer.Serialize(report, CoreJson.Options);
        Console.WriteLine(output);
        if (reportPath != null) { Directory.CreateDirectory(System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(reportPath))!); await File.WriteAllTextAsync(reportPath, output); }
        return failure == null ? 0 : 1;
    }
    [SupportedOSPlatform("windows")]
    private static bool HasUserOnlyWindowsAccess(string path)
    {
        var user = WindowsIdentity.GetCurrent().User!;
        var rules = new FileInfo(path).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)).OfType<FileSystemAccessRule>()
            .Where(r => r.AccessControlType == AccessControlType.Allow).ToArray();
        return rules.Length > 0 && rules.All(r => r.IdentityReference.Value == user.Value);
    }
    private sealed class FixtureHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> action) : HttpMessageHandler
    {
        public List<string> Bodies { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var content = request.Content == null ? request.RequestUri!.Query : await request.Content.ReadAsStringAsync(cancellationToken);
            lock (Bodies) Bodies.Add(content);
            return await action(request);
        }
    }
}
