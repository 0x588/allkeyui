using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AllKey.Core;

public record BalanceRecord(bool Success, string? Balance = null, string? Transactions = null, string? Received = null,
    string? Error = null, string? Source = null, DateTimeOffset? QueriedAt = null, bool Cached = false)
{
    public static BalanceRecord Failed(string message) => new(false, Error: message);
    public bool Funded => Success && NonZero(Balance);
    public bool Activity => Success && (NonZero(Transactions) || NonZero(Received));
    public static bool NonZero(string? value)
    {
        var token = value?.Split(' ')[0].Replace(",", "") ?? "";
        if (!Regex.IsMatch(token, "^[+]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$")) return false;
        return token.Split('e', 'E')[0].Any(c => c is >= '1' and <= '9');
    }
}

// PublicAddress deliberately has no key, mnemonic, passphrase or derivation-path fields.
public record PublicAddress(string Coin, string Address, EvmNetwork? Network = null);

public sealed class BalanceClient : IDisposable
{
    private readonly SettingsStore _settings;
    private readonly HttpClient _http;
    private readonly bool _ownsHttp;
    private readonly SemaphoreSlim _slots = new(3, 3);
    private readonly ConcurrentDictionary<string, BalanceRecord> _cache = new();
    private readonly ConcurrentDictionary<string, Lazy<Task<BalanceRecord>>> _pending = new();
    private readonly Dictionary<string, DateTimeOffset> _next = [];
    private readonly Dictionary<string, DateTimeOffset> _cooldown = [];
    private readonly object _paceGate = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly TimeSpan _spacing;
    public BalanceClient(SettingsStore settings, HttpClient? http = null, TimeSpan? spacing = null)
    {
        _settings = settings;
        _ownsHttp = http == null;
        _http = http ?? new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = TimeSpan.FromSeconds(15) };
        _spacing = spacing ?? TimeSpan.FromMilliseconds(500);
    }
    public async Task<BalanceRecord> FetchAsync(PublicAddress address, bool force = false, CancellationToken cancellationToken = default)
    {
        var network = address.Network;
        if (network != null && !_settings.Current.EvmNetworks.Any(n => n == network && n.Enabled))
            return BalanceRecord.Failed("网络配置已变更或停用，请重新生成地址");
        var services = network != null ? new[] { new StoredService(new("evmRPC", network.RpcURL), network.ApiKey) } : _settings.Services(address.Coin);
        if (services.Length == 0) return BalanceRecord.Failed($"请先在设置中配置 {address.Coin} 余额服务");
        var signature = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { services, network }, CoreJson.Options))));
        var key = $"{network?.Id ?? address.Coin}|{address.Address}|{signature}";
        if (!force && _cache.TryGetValue(key, out var cached) && DateTimeOffset.UtcNow - cached.QueriedAt < TimeSpan.FromSeconds(60))
            return cached with { Cached = true };
        var lazy = _pending.GetOrAdd(key, _ => new(() => QueryAsync(address, services), LazyThreadSafetyMode.ExecutionAndPublication));
        var task = lazy.Value;
        try
        {
            var result = await task.WaitAsync(cancellationToken).ConfigureAwait(false);
            if (result.Success)
            {
                _cache[key] = result;
                if (_cache.Count > 2000)
                    foreach (var old in _cache.OrderBy(p => p.Value.QueriedAt).Take(_cache.Count - 2000)) _cache.TryRemove(old.Key, out _);
            }
            return result;
        }
        finally
        {
            if (task.IsCompleted) _pending.TryRemove(new KeyValuePair<string, Lazy<Task<BalanceRecord>>>(key, lazy));
            else _ = task.ContinueWith(_ => _pending.TryRemove(new KeyValuePair<string, Lazy<Task<BalanceRecord>>>(key, lazy)), TaskScheduler.Default);
        }
    }
    private async Task<BalanceRecord> QueryAsync(PublicAddress address, StoredService[] services)
    {
        var result = BalanceRecord.Failed("查询失败");
        foreach (var service in services)
        {
            try
            {
                if (!Providers.IsHttps(service.Endpoint.Url)) throw new InvalidDataException("请输入有效的 HTTPS 服务地址");
                Providers.ValidateKey(service.Endpoint.Provider, service.Endpoint.Url, service.ApiKey);
                if (address.Network is { } network)
                {
                    network.Validate();
                    var chain = await SendRpcAsync(service, "eth_chainId", Array.Empty<string>()).ConfigureAwait(false);
                    if (HexInteger(Value(chain.GetProperty("result"))) != network.ChainID)
                        return BalanceRecord.Failed("RPC 返回的链 ID 与配置不符，已停止查询");
                }
                var root = await RequestAsync(address, service).ConfigureAwait(false);
                result = Parse(root, address, service.Endpoint.Provider) with
                {
                    Source = Providers.Title(service.Endpoint.Provider) + " · " + new Uri(service.Endpoint.Url).Host,
                    QueriedAt = DateTimeOffset.UtcNow
                };
                return result;
            }
            catch (Exception error)
            {
                result = BalanceRecord.Failed(error switch
                {
                    InvalidDataException => error.Message,
                    BalanceHttpException => error.Message,
                    _ => "查询失败，请检查网络、额度或服务配置"
                }) with { QueriedAt = DateTimeOffset.UtcNow };
            }
        }
        return result;
    }
    private async Task<JsonElement> RequestAsync(PublicAddress item, StoredService service)
    {
        var address = Uri.EscapeDataString(item.Address);
        var url = service.Endpoint.Url.TrimEnd('/');
        var key = service.ApiKey;
        var provider = service.Endpoint.Provider;
        return provider switch
        {
            "blockchain" => await SendAsync(AddQuery(url, ("active", item.Address)), null, null),
            "blockcypher" => await SendAsync(AddQuery($"{url}/addrs/{address}/balance", ("token", key)), null, null),
            "blockchair" => await SendAsync(AddQuery($"{url}/{item.Coin switch { "BTC" => "bitcoin", "LTC" => "litecoin", "DOGE" => "dogecoin", _ => throw InvalidResponse() }}/dashboards/address/{address}", ("limit", "0"), ("key", key)), null, null),
            "etherscan" => await SendAsync(AddQuery(url, ("chainid", item.Coin == "BSC" ? "56" : "1"), ("module", "account"), ("action", "balance"), ("address", item.Address), ("tag", "latest"), ("apikey", key)), null, null),
            "evmRPC" => await SendRpcAsync(service, "eth_getBalance", new[] { item.Address, "latest" }),
            "tronGrid" => await SendAsync($"{url}/v1/accounts/{address}", null, new("TRON-PRO-API-KEY", key)),
            "solanaRPC" => await SendRpcAsync(service, "getBalance", new[] { item.Address }),
            "chainz" => await SendAsync(AddQuery(url, ("q", "getbalances"), ("key", key)), new[] { item.Address }, null),
            "okLink" => await SendAsync(AddQuery(url, ("chainShortName", item.Coin), ("address", item.Address)), null, new("Ok-Access-Key", key)),
            _ => throw InvalidResponse()
        };
    }
    private Task<JsonElement> SendRpcAsync(StoredService service, string method, object parameters)
    {
        var url = service.Endpoint.Url.Replace("{API_KEY}", Uri.EscapeDataString(service.ApiKey), StringComparison.OrdinalIgnoreCase)
            .Replace("%7BAPI_KEY%7D", Uri.EscapeDataString(service.ApiKey), StringComparison.OrdinalIgnoreCase);
        return SendAsync(url, new { jsonrpc = "2.0", id = 1, method, @params = parameters }, null);
    }
    private async Task<JsonElement> SendAsync(string url, object? body, KeyValuePair<string, string>? header)
    {
        var uri = new Uri(url);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(15));
            var token = timeout.Token;
            await _slots.WaitAsync(token).ConfigureAwait(false);
            HttpResponseMessage? response = null;
            try
            {
                DateTimeOffset start;
                lock (_paceGate)
                {
                    var now = DateTimeOffset.UtcNow;
                    if (_cooldown.GetValueOrDefault(uri.Host) > now) throw new BalanceHttpException(429);
                    start = _next.GetValueOrDefault(uri.Host) > now ? _next[uri.Host] : now;
                    _next[uri.Host] = start + _spacing;
                }
                var delay = start - DateTimeOffset.UtcNow;
                if (delay > TimeSpan.Zero) await Task.Delay(delay, token).ConfigureAwait(false);
                using var request = new HttpRequestMessage(body == null ? HttpMethod.Get : HttpMethod.Post, uri);
                if (body != null) request.Content = new StringContent(JsonSerializer.Serialize(body, CoreJson.Options), Encoding.UTF8, "application/json");
                if (header is { } h) request.Headers.Add(h.Key, h.Value);
                response = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
                if (!response.IsSuccessStatusCode)
                {
                    var status = (int)response.StatusCode;
                    if (attempt == 0 && (status == 429 || status >= 500))
                    {
                        var retry = response.Headers.RetryAfter?.Delta ??
                            (response.Headers.RetryAfter?.Date is { } date ? date - DateTimeOffset.UtcNow : TimeSpan.FromSeconds(1));
                        if (retry > TimeSpan.FromSeconds(3))
                        {
                            lock (_paceGate) _cooldown[uri.Host] = DateTimeOffset.UtcNow + retry;
                            throw new BalanceHttpException(status);
                        }
                        await Task.Delay(retry > TimeSpan.Zero ? retry : TimeSpan.FromMilliseconds(100), token).ConfigureAwait(false);
                        continue;
                    }
                    throw new BalanceHttpException(status);
                }
                if (response.Content.Headers.ContentLength > 2 * 1024 * 1024) throw InvalidResponse();
                await using var stream = await response.Content.ReadAsStreamAsync(token).ConfigureAwait(false);
                using var data = new MemoryStream();
                var buffer = new byte[8192];
                int read;
                while ((read = await stream.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
                {
                    if (data.Length + read > 2 * 1024 * 1024) throw InvalidResponse();
                    data.Write(buffer, 0, read);
                }
                using var document = JsonDocument.Parse(data.ToArray());
                var root = document.RootElement;
                if (root.TryGetProperty("error", out _)) throw InvalidResponse();
                return root.Clone();
            }
            catch (HttpRequestException) when (attempt == 0) { }
            finally { response?.Dispose(); _slots.Release(); }
        }
        throw InvalidResponse();
    }
    public static BalanceRecord Parse(JsonElement root, PublicAddress item, string provider)
    {
        string amount;
        string? tx = null, received = null;
        int? decimals;
        JsonElement account;
        switch (provider)
        {
            case "blockchain":
                account = root.GetProperty(item.Address); amount = Value(account.GetProperty("final_balance"));
                tx = Optional(account, "n_tx"); received = Optional(account, "total_received"); decimals = 8; break;
            case "blockcypher":
                if (Optional(root, "address") != item.Address || root.TryGetProperty("error", out _)) throw InvalidResponse();
                amount = Optional(root, "final_balance") ?? Value(root.GetProperty("balance"));
                tx = Optional(root, "n_tx"); received = Optional(root, "total_received"); decimals = 8; break;
            case "blockchair":
                if (Value(root.GetProperty("context").GetProperty("code")) != "200") throw InvalidResponse();
                account = root.GetProperty("data").GetProperty(item.Address).GetProperty("address");
                amount = Value(account.GetProperty("balance")); tx = Optional(account, "transaction_count"); received = Optional(account, "received"); decimals = 8; break;
            case "etherscan":
                if (Optional(root, "status") != "1") throw InvalidResponse();
                amount = Value(root.GetProperty("result")); decimals = 18; break;
            case "evmRPC":
                amount = HexInteger(Value(root.GetProperty("result"))); decimals = item.Network?.Decimals ?? 18; break;
            case "tronGrid":
                if (!root.GetProperty("success").GetBoolean()) throw InvalidResponse();
                var accounts = root.GetProperty("data");
                amount = accounts.GetArrayLength() == 0 ? "0" : Optional(accounts[0], "balance") ?? "0"; decimals = 6; break;
            case "solanaRPC": amount = Value(root.GetProperty("result").GetProperty("value")); decimals = 9; break;
            case "chainz": amount = Value(root.GetProperty(item.Address)); decimals = null; break;
            case "okLink":
                if (Optional(root, "code") != "0") throw InvalidResponse();
                account = root.GetProperty("data")[0]; amount = Value(account.GetProperty("balance"));
                tx = Optional(account, "transactionCount"); received = Optional(account, "receiveAmount"); decimals = null; break;
            default: throw InvalidResponse();
        }
        if (decimals is { } places)
        {
            amount = DecimalAmount(amount, places);
            if (received != null) received = DecimalAmount(received, places);
        }
        else if (!Regex.IsMatch(amount, "^[0-9]+(?:\\.[0-9]+)?$")) throw InvalidResponse();
        return new(true, amount + " " + (item.Network?.Symbol ?? (item.Coin == "BSC" ? "BNB" : item.Coin)), tx, received);
    }
    public static string DecimalAmount(string raw, int places)
    {
        if (places is < 0 or > 36 || raw.Length == 0 || !raw.All(char.IsAsciiDigit)) throw InvalidResponse();
        var padded = raw.PadLeft(places + 1, '0');
        var whole = padded[..(padded.Length - places)].TrimStart('0');
        var fraction = places == 0 ? "" : padded[^places..].TrimEnd('0');
        return (whole.Length == 0 ? "0" : whole) + (fraction.Length == 0 ? "" : "." + fraction);
    }
    public static string HexInteger(string hex)
    {
        if (!hex.StartsWith("0x", StringComparison.Ordinal) || hex.Length <= 2 || !hex[2..].All(Uri.IsHexDigit)) throw InvalidResponse();
        return BigInteger.Parse("0" + hex[2..], NumberStyles.HexNumber, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture);
    }
    private static string Value(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.String => element.GetString()!, JsonValueKind.Number => element.GetRawText(), _ => throw InvalidResponse()
    };
    private static string? Optional(JsonElement element, string key) => element.TryGetProperty(key, out var value) && value.ValueKind is JsonValueKind.String or JsonValueKind.Number ? Value(value) : null;
    private static string AddQuery(string url, params (string Key, string Value)[] items)
    {
        var builder = new UriBuilder(url);
        var query = string.Join('&', items.Where(i => i.Value.Length > 0).Select(i => Uri.EscapeDataString(i.Key) + "=" + Uri.EscapeDataString(i.Value)));
        builder.Query = (builder.Query.Length > 1 ? builder.Query[1..] + "&" : "") + query;
        return builder.Uri.AbsoluteUri;
    }
    private static InvalidDataException InvalidResponse() => new("服务未返回有效余额，请检查额度、凭据或响应格式");
    public void Dispose() { _lifetime.Cancel(); if (_ownsHttp) _http.Dispose(); _lifetime.Dispose(); }
    private sealed class BalanceHttpException(int status) : Exception(status == 429 ? "服务请求过于频繁或额度已用尽" : $"余额服务返回 HTTP {status}");
}
