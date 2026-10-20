using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using AllKey.WindowsPoC;

Console.OutputEncoding = Encoding.UTF8;
try
{
    if (args.Length is < 1 or > 2 ||
        (args.Length == 2 && (!int.TryParse(args[1], out var count) || count < 1 || count > 100000)))
        throw new ArgumentException("Usage: AllKey.WindowsPoC <absolute-native-library-path> [iterations:1..100000]");

    var iterations = args.Length == 2 ? int.Parse(args[1]) : 2000;
    NativeMethods.Load(args[0]);
    var client = new CoreClient();
    var watch = Stopwatch.StartNew();
    Console.WriteLine($"Platform: {RuntimeInformation.OSDescription}; process: {RuntimeInformation.ProcessArchitecture}");
    using var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "vectors.json")));
    var passed = 0;
    foreach (var vector in fixtures.RootElement.EnumerateArray())
    {
        var request = vector.GetProperty("request");
        var raw = request.ValueKind == JsonValueKind.Null ? null :
            vector.TryGetProperty("raw", out var isRaw) && isRaw.GetBoolean() ? request.GetString() : request.GetRawText();
        var response = client.Call(vector.GetProperty("operation").GetString()!, raw);
        foreach (var check in vector.GetProperty("expect").EnumerateObject())
        {
            var actual = response;
            foreach (var part in check.Name.Split('.'))
                actual = actual.ValueKind == JsonValueKind.Array ? actual[int.Parse(part)] : actual.GetProperty(part);
            if (!JsonElement.DeepEquals(actual, check.Value))
                throw new InvalidOperationException($"Vector '{vector.GetProperty("name").GetString()}' failed at {check.Name}.");
        }
        passed++;
        Console.WriteLine($"PASS {vector.GetProperty("name").GetString()}");
    }

    const string stressRequest = "{\"operation\":\"ascii-to-hex\",\"input\":\" 中\\n\"}";
    for (var i = 0; i < iterations; i++)
    {
        var response = client.Call("calculate", stressRequest);
        if (!response.GetProperty("ok").GetBoolean() ||
            response.GetProperty("data").GetProperty("output").GetString() != "20e4b8ad0a")
            throw new InvalidOperationException("Repeated UTF-8 call failed.");
    }
    if (client.Allocations != client.Releases)
        throw new InvalidOperationException("Unbalanced response allocation/release calls.");

    var report = new
    {
        platform = RuntimeInformation.OSDescription,
        architecture = RuntimeInformation.ProcessArchitecture.ToString(),
        vectorsPassed = passed,
        repeatedCalls = iterations,
        responsesReceived = client.Allocations,
        responsesFreed = client.Releases,
        elapsedMs = watch.ElapsedMilliseconds,
        status = "passed"
    };
    Console.WriteLine(JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    return 0;
}
catch (Exception error)
{
    // Do not dump request/response material into failure logs.
    Console.Error.WriteLine($"FAIL {error.GetType().Name}: {error.Message}");
    return 1;
}
