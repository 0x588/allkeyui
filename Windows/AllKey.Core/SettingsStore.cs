using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Runtime.Versioning;

namespace AllKey.Core;

public record ServiceEndpoint(string Provider, string Url);
public record StoredService(ServiceEndpoint Endpoint, string ApiKey);
public record EvmNetwork
{
    public string Id { get; init; } = Guid.NewGuid().ToString();
    public string Name { get; init; } = "";
    public string ChainID { get; init; } = "";
    public string Symbol { get; init; } = "ETH";
    public int Decimals { get; init; } = 18;
    public string RpcURL { get; init; } = "";
    public string ExplorerUrl { get; init; } = "";
    public string ApiKey { get; init; } = "";
    public bool Enabled { get; init; } = true;
    public void Validate()
    {
        if (!Guid.TryParse(Id, out _) || string.IsNullOrWhiteSpace(Name) || Name.Length > 60 ||
            !ulong.TryParse(ChainID, out var chain) || chain == 0 || chain.ToString() != ChainID ||
            !Regex.IsMatch(Symbol, "^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$") || Decimals is < 0 or > 36 ||
            !Providers.IsHttps(RpcURL) || (ExplorerUrl.Length > 0 && !Providers.IsHttps(ExplorerUrl)))
            throw new InvalidDataException("请填写网络名称、正整数链 ID、主币符号、0–36 位精度和有效 HTTPS RPC");
        Providers.ValidateKey("evmRPC", RpcURL, ApiKey);
    }
}
public sealed record Configuration
{
    public int Version { get; init; } = 1;
    public Dictionary<string, StoredService> Primary { get; init; } = [];
    public Dictionary<string, StoredService> Backup { get; init; } = [];
    public List<EvmNetwork> EvmNetworks { get; init; } = [];
    public string Appearance { get; init; } = "light";
    public bool AutoRefresh { get; init; }
    public void Validate()
    {
        if (Version != 1 || Appearance is not ("light" or "dark" or "system")) throw new InvalidDataException("配置文件版本或外观设置无效");
        foreach (var entries in new[] { Primary, Backup })
            foreach (var (coin, service) in entries)
            {
                if (!Providers.Choices(coin).Contains(service.Endpoint.Provider) || !Providers.IsHttps(service.Endpoint.Url))
                    throw new InvalidDataException("余额服务类型或 HTTPS 地址无效");
                Providers.ValidateKey(service.Endpoint.Provider, service.Endpoint.Url, service.ApiKey);
            }
        foreach (var network in EvmNetworks) network.Validate();
        if (EvmNetworks.Select(n => n.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != EvmNetworks.Count ||
            EvmNetworks.Select(n => n.ChainID).Distinct().Count() != EvmNetworks.Count)
            throw new InvalidDataException("网络 ID 或链 ID 重复");
    }
}

public static class Providers
{
    public static string[] Choices(string coin) => coin switch
    {
        "BTC" => ["blockchain", "blockchair"], "LTC" => ["blockchair", "chainz"],
        "DOGE" => ["blockcypher", "blockchair", "okLink"], "ETH" or "BSC" => ["evmRPC", "etherscan"],
        "TRX" => ["tronGrid"], "SOL" => ["solanaRPC"], _ => []
    };
    public static string Title(string provider) => provider switch
    {
        "blockchain" => "Blockchain.info", "blockchair" => "Blockchair", "blockcypher" => "BlockCypher",
        "etherscan" => "Etherscan V2", "evmRPC" => "EVM JSON-RPC", "tronGrid" => "TronGrid",
        "solanaRPC" => "Solana RPC", "chainz" => "Chainz CryptoID", "okLink" => "OKLink", _ => provider
    };
    public static string DefaultUrl(string provider, string coin) => provider switch
    {
        "blockchain" => "https://blockchain.info/balance", "blockchair" => "https://api.blockchair.com",
        "blockcypher" => "https://api.blockcypher.com/v1/doge/main", "etherscan" => "https://api.etherscan.io/v2/api",
        "evmRPC" => coin == "ETH" ? "https://ethereum-rpc.publicnode.com" : "https://bsc-dataseed.bnbchain.org",
        "tronGrid" => "https://api.trongrid.io", "solanaRPC" => "https://api.mainnet.solana.com",
        "chainz" => "https://chainz.cryptoid.info/ltc/api.dws", "okLink" => "https://www.oklink.com/api/v5/explorer/address/address-summary", _ => ""
    };
    public static bool IsHttps(string value) => Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == "https" &&
        uri.Host.Length > 0 && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0;
    public static void ValidateKey(string provider, string url, string key)
    {
        if ((provider is "etherscan" or "tronGrid" or "chainz" or "okLink" ||
            url.Contains("{API_KEY}", StringComparison.OrdinalIgnoreCase) || url.Contains("%7BAPI_KEY%7D", StringComparison.OrdinalIgnoreCase)) && string.IsNullOrWhiteSpace(key))
            throw new InvalidDataException("此服务需要 API Key");
    }
}

public sealed class SettingsStore
{
    public string FilePath { get; }
    public Configuration Current { get; private set; } = new();
    public string? LoadError { get; private set; }
    public SettingsStore(string? directory = null)
    {
        directory ??= System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AllKeyUI");
        FilePath = System.IO.Path.Combine(directory, "balance-settings.json");
        if (!File.Exists(FilePath)) return;
        try
        {
            Current = JsonSerializer.Deserialize<Configuration>(File.ReadAllText(FilePath), CoreJson.Options)
                ?? throw new InvalidDataException();
            Current.Validate();
        }
        catch
        {
            Current = new();
            LoadError = "无法读取余额配置，请检查 JSON 格式、版本或文件权限；原文件未被覆盖";
        }
    }
    public Configuration Snapshot() => JsonSerializer.Deserialize<Configuration>(JsonSerializer.Serialize(Current, CoreJson.Options), CoreJson.Options)!;
    public void Save(Configuration config)
    {
        config.Validate();
        if (LoadError != null) throw new InvalidDataException(LoadError);
        var directory = System.IO.Path.GetDirectoryName(FilePath)!;
        Directory.CreateDirectory(directory);
        if (OperatingSystem.IsWindows()) RestrictWindowsDirectory(directory);
        else File.SetUnixFileMode(directory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        var temporary = System.IO.Path.Combine(directory, ".balance-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            var data = JsonSerializer.SerializeToUtf8Bytes(config, CoreJson.Options);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                stream.Write(data);
                stream.Flush(true);
            }
            File.Move(temporary, FilePath, true);
            Current = JsonSerializer.Deserialize<Configuration>(JsonSerializer.Serialize(config, CoreJson.Options), CoreJson.Options)!;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    [SupportedOSPlatform("windows")]
    private static void RestrictWindowsDirectory(string directory)
    {
        var user = WindowsIdentity.GetCurrent().User ?? throw new IOException("无法确认当前 Windows 用户");
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(directory).SetAccessControl(security);
    }
    public StoredService[] Services(string coin) => new[] { Current.Primary.GetValueOrDefault(coin), Current.Backup.GetValueOrDefault(coin) }
        .OfType<StoredService>().ToArray();
    public AddressItem[] Project(IEnumerable<AddressItem> items) => items.SelectMany(item =>
        item.Coin == "ETH" && item.Network == null
            ? new[] { item }.Concat(Current.EvmNetworks.Where(n => n.Enabled).Select(n => item with { Network = n }))
            : [item]).ToArray();
}
