using System.Globalization;
using System.Numerics;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AllKey.Core;

public static class CoreJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };
}

public static class Coins
{
    public static readonly string[] All = ["BTC", "ETH", "BSC", "LTC", "DOGE", "TRX", "SOL"];
    public static string Name(string coin) => coin switch
    {
        "BTC" => "Bitcoin", "ETH" => "Ethereum", "BSC" => "BNB Smart Chain", "LTC" => "Litecoin",
        "DOGE" => "Dogecoin", "TRX" => "Tron", "SOL" => "Solana", _ => coin
    };
    public static string Explorer(string coin) => coin switch
    {
        "BTC" => "https://www.blockchain.com/explorer/addresses/btc/",
        "ETH" => "https://etherscan.io/address/", "BSC" => "https://bscscan.com/address/",
        "LTC" => "https://www.oklink.com/zh-hans/ltc/address/", "DOGE" => "https://www.oklink.com/zh-hans/doge/address/",
        "TRX" => "https://tronscan.org/#/address/", "SOL" => "https://solscan.io/account/", _ => ""
    };
}

public record AddressItem
{
    public string Coin { get; init; } = "";
    public string Path { get; init; } = "";
    [JsonPropertyName("hex_key")] public string PrivateKey { get; init; } = "";
    [JsonPropertyName("key_tag")] public string AlternateKey { get; init; } = "";
    [JsonPropertyName("key_format")] public string KeyFormat { get; init; } = "";
    [JsonPropertyName("addr")] public string Address { get; init; } = "";
    [JsonPropertyName("addr_tag")] public string AddressTag { get; init; } = "";
    [JsonIgnore] public EvmNetwork? Network { get; init; }
    [JsonIgnore] public string Group => Network?.Id ?? Coin;
    [JsonIgnore] public string Id => $"{Group}|{Address}|{AddressTag}|{Path}";
    [JsonIgnore] public string DisplayCoin => Network?.Symbol ?? Coin;
    [JsonIgnore] public string DisplayNetwork => Network?.Name ?? Coins.Name(Coin);
    [JsonIgnore] public string PrivateKeyLabel => KeyFormat switch
    {
        "wif" => "WIF 私钥", "base58" => "Base58 私钥", _ => Coin == "SOL" && Path.Length == 0 ? "十六进制种子" : "十六进制私钥"
    };
    [JsonIgnore] public string AlternateKeyLabel => Coin switch { "BTC" => "WIF 私钥", "SOL" => "Base58 私钥", _ => "扩展格式" };
    [JsonIgnore] public string Explorer => Network is { } n
        ? n.ExplorerUrl.Length == 0 ? "" : n.ExplorerUrl.TrimEnd('/') + "/address/" + Uri.EscapeDataString(Address)
        : Coins.Explorer(Coin) + Uri.EscapeDataString(Address);
}

public record KeyResult(string Index, AddressItem[] Items, string? InputFormat, bool? WifCompressed);
public record MnemonicResult(string Mnemonic, string Index, string Max, AddressItem[] Items,
    string? SearchCursor, AddressItem? MatchedItem);
public record MnemonicPageResult(string Start, string End, string Max, bool HasPrevious, bool HasNext, MnemonicResult[] Items);
public record WordIssue(int Position, string Word);
public record MnemonicInspection(int WordCount, int DetectedBitSize, int MissingCount, WordIssue[] InvalidWords,
    string Checksum, int CompletionPosition, string[] Suggestions);
public record CalculatorOutput(string Output);
public sealed class CoreException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public record MnemonicRequest
{
    public int BitSize { get; init; } = 128;
    public int Count { get; init; } = 1;
    public string[] Coins { get; init; } = ["BTC", "ETH"];
    public string Index { get; init; } = "0";
    public string Op { get; init; } = "current";
    public string BtcType { get; init; } = "all";
    public string PathPreset { get; init; } = "receive";
    public long Account { get; init; }
    public long AddressStart { get; init; }
    public string Passphrase { get; init; } = "";
    public string CustomPath { get; init; } = "";
    public string? Pattern { get; init; }
    public string? Cursor { get; init; }
    public string? TargetAddress { get; init; }
    public string? TargetCoin { get; init; }
}

public record Puzzle(int Id, bool Solved, string Address)
{
    [JsonIgnore] public string LowerBound => (BigInteger.One << (Id - 1)).ToString("x", CultureInfo.InvariantCulture).TrimStart('0');
    [JsonIgnore] public string UpperBound => ((BigInteger.One << Id) - 1).ToString("x", CultureInfo.InvariantCulture).TrimStart('0');
    [JsonIgnore] public string State => Solved ? "已解" : "未解";
}
public record PuzzleCatalog(string SourceUrl, string CapturedAt, string SourceSha256, Puzzle[] Puzzles)
{
    public static PuzzleCatalog Load(string path)
    {
        var catalog = JsonSerializer.Deserialize<PuzzleCatalog>(File.ReadAllText(path), CoreJson.Options)
            ?? throw new InvalidDataException("未找到 Puzzle 数据");
        if (!catalog.Puzzles.Select(p => p.Id).SequenceEqual(Enumerable.Range(1, 160)) ||
            catalog.Puzzles.Select(p => p.Address).Distinct().Count() != 160 ||
            !DateTimeOffset.TryParse(catalog.CapturedAt, out _) || catalog.SourceSha256.Length != 64)
            throw new InvalidDataException("Puzzle 数据校验失败");
        return catalog;
    }
}
