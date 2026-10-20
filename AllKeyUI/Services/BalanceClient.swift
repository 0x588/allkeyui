import Foundation
import CryptoKit

struct BalanceRecord: Equatable {
    enum Status: Equatable {
        case loaded
        case unavailable
    }

    let status: Status
    let balance: String?
    let transactionCount: String?
    let received: String?
    var source: String? = nil
    var queriedAt: Date? = nil
    var isCached = false
    var errorMessage: String? = nil

    var hasNonZeroData: Bool {
        status == .loaded && [balance, transactionCount, received].contains(where: Self.isNonZero)
    }

    /// Inspect the decimal mantissa without rounding tiny amounts to floating-point zero.
    static func isNonZero(_ formatted: String?) -> Bool {
        guard let token = formatted?.split(whereSeparator: \.isWhitespace).first else { return false }
        let number = token.replacingOccurrences(of: ",", with: "")
        guard number.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                           options: .regularExpression) != nil else { return false }
        let mantissa = number.split(whereSeparator: { $0 == "e" || $0 == "E" }).first ?? ""
        return mantissa.contains { ("1"..."9").contains($0) }
    }

    static func failed(_ message: String) -> Self {
        Self(status: .unavailable, balance: nil, transactionCount: nil, received: nil, errorMessage: message)
    }

    func stamped(source: String) -> Self {
        var value = self
        value.source = source
        value.queriedAt = Date()
        return value
    }

    func cached() -> Self {
        var value = self
        value.isCached = true
        return value
    }
}

struct BalanceService {
    let endpoint: BalanceEndpoint
    let apiKey: String
}

private struct BalanceHTTPError: LocalizedError {
    let status: Int
    var errorDescription: String? {
        status == 429 ? "服务请求额度已用尽或过于频繁，请稍后重试" : "余额服务返回 HTTP \(status)"
    }
}

enum BalanceClientError: LocalizedError {
    case invalidResponse
    case server(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "余额服务返回了无效数据"
        case .server(let message):
            message
        case .notConfigured:
            "请先在左侧设置中配置余额查询服务"
        }
    }
}

actor BalanceClient {
    static let shared = BalanceClient()

    private let session: URLSession
    private let services: @Sendable (Coin) -> [BalanceService]
    private let cacheTTL: TimeInterval
    private let requestSpacing: TimeInterval
    private var cache: [String: BalanceRecord] = [:]
    private struct Pending {
        let id: UUID
        let task: Task<[String: BalanceRecord], Error>
    }
    private var pending: [String: Pending] = [:]
    private var observers: [String: [UUID: @Sendable (BalanceRecord) -> Void]] = [:]
    private var partial: [String: BalanceRecord] = [:]
    private let networks: @Sendable () -> [EVMNetwork]
    private var activeRequests = 0
    private var nextRequest: [String: Date] = [:]
    private var cooldown: [String: (until: Date, status: Int)] = [:]

    init(session: URLSession = .shared, cacheTTL: TimeInterval = 60, requestSpacing: TimeInterval = 0.5,
         networks: @escaping @Sendable () -> [EVMNetwork] = { BalanceSettings.evmNetworks },
         services: @escaping @Sendable (Coin) -> [BalanceService] = { coin in
             BalanceServiceRole.allCases.compactMap { role in
                 guard let endpoint = BalanceSettings.endpoint(for: coin, role: role) else { return nil }
                 return BalanceService(endpoint: endpoint, apiKey: BalanceSettings.apiKey(for: coin, role: role) ?? "")
             }
         }) {
        self.session = session
        self.cacheTTL = cacheTTL
        self.requestSpacing = requestSpacing
        self.services = services
        self.networks = networks
    }

    /// Cache and shared work are keyed by network, exact address and the complete service configuration.
    /// Only successful results are cached; a refresh bypasses cache but joins an existing live request.
    func fetch(items: [AddressItem], forceRefresh: Bool = false,
               onUpdate: (@Sendable ([String: BalanceRecord]) -> Void)? = nil) async throws -> [String: BalanceRecord] {
        try Task.checkCancellation()
        guard !items.isEmpty else { return [:] }
        let groups = Dictionary(grouping: items, by: \.balanceGroupKey)
        var records: [String: BalanceRecord] = [:]
        for (groupKey, coinItems) in groups {
            let coinName = coinItems[0].coin
            guard let coin = Coin(rawValue: coinName) else { continue }
            let network: EVMNetwork?
            if let identity = coinItems[0].evmNetwork {
                guard let saved = networks().first(where: { $0.id == identity.id && $0.enabled }), saved.info == identity else {
                    let values = Dictionary(coinItems.map { ($0.id, BalanceRecord.failed("网络配置已变更或停用，请重新生成地址")) }, uniquingKeysWith: { _, new in new })
                    records.merge(values) { _, new in new }; onUpdate?(values); continue
                }
                network = saved
            } else { network = nil }
            let configured = network.map { [BalanceService(endpoint: BalanceEndpoint(provider: .evmRPC, url: $0.rpcURL), apiKey: $0.apiKey)] } ?? services(coin)
            guard !configured.isEmpty else {
                for item in coinItems { records[item.id] = .failed("请先在设置中配置 \(coinName) 余额服务") }
                onUpdate?(Dictionary(coinItems.map { ($0.id, records[$0.id]!) }, uniquingKeysWith: { _, new in new }))
                continue
            }
            let signature = SHA256.hash(data: Data(configured.map {
                $0.endpoint.provider.rawValue + "|" + $0.endpoint.url + "|" + $0.apiKey
            }.joined(separator: "\n").appending(network.map { "|\($0.chainID)|\($0.decimals)|\($0.symbol)" } ?? "").utf8)).map { String(format: "%02x", $0) }.joined()
            let unique = Dictionary(grouping: coinItems, by: \.address).compactMap { $0.value.first }
            func queryKey(_ address: String) -> String { "\(groupKey)|\(address)|\(signature)" }
            let observerID = UUID()
            let observedKeys = unique.map { queryKey($0.address) }
            defer {
                for key in observedKeys {
                    observers[key]?[observerID] = nil
                    if observers[key]?.isEmpty == true { observers[key] = nil }
                }
            }
            if let onUpdate {
                for item in unique {
                    let duplicates = coinItems.filter { $0.address == item.address }
                    observers[queryKey(item.address), default: [:]][observerID] = { value in
                        onUpdate(Dictionary(duplicates.map { ($0.id, value) }, uniquingKeysWith: { _, new in new }))
                    }
                }
            }
            var remaining: [AddressItem] = []
            for item in unique {
                let key = queryKey(item.address)
                if !forceRefresh, let value = cache[key], let date = value.queriedAt,
                   Date().timeIntervalSince(date) < cacheTTL {
                    for duplicate in coinItems where duplicate.address == item.address {
                        records[duplicate.id] = value.cached()
                    }
                    observers[key]?[observerID]?(value.cached())
                } else if pending[key] == nil { remaining.append(item) }
                else if let value = partial[key] { observers[key]?[observerID]?(value) }
            }
            if !remaining.isEmpty {
                let taskItems = remaining
                let workID = UUID()
                let work = Pending(id: workID, task: Task {
                    let values = try await self.resolve(taskItems, coin: coin, services: configured, network: network) { values in
                        self.publish(values, groupKey: groupKey, signature: signature)
                    }
                    self.complete(values, items: taskItems, coin: groupKey, signature: signature, workID: workID)
                    return values
                })
                for item in remaining { pending[queryKey(item.address)] = work }
            }
            let waiting = Dictionary(uniqueKeysWithValues: unique.compactMap { item in
                pending[queryKey(item.address)].map { (item.address, $0) }
            })
            for item in unique where records[item.id] == nil {
                try Task.checkCancellation()
                guard let work = waiting[item.address] else { continue }
                // Work is shared across views: cancelling one waiter must not cancel another's request.
                let values = try await work.task.value
                try Task.checkCancellation()
                let record = values[item.address] ?? .failed("服务未返回此地址的结果")
                for duplicate in coinItems where duplicate.address == item.address { records[duplicate.id] = record }
            }
        }
        return records
    }

    private func complete(_ values: [String: BalanceRecord], items: [AddressItem], coin: String, signature: String, workID: UUID) {
        for item in items {
            let key = "\(coin)|\(item.address)|\(signature)"
            if pending[key]?.id == workID { pending[key] = nil; partial[key] = nil }
            if let value = values[item.address], value.status == .loaded { cache[key] = value }
        }
        if cache.count > 2000 {
            cache = Dictionary(uniqueKeysWithValues: cache.sorted {
                ($0.value.queriedAt ?? .distantPast) > ($1.value.queriedAt ?? .distantPast)
            }.prefix(2000).map { ($0.key, $0.value) })
        }
    }

    private func publish(_ values: [String: BalanceRecord], groupKey: String, signature: String) {
        for (address, value) in values {
            let key = "\(groupKey)|\(address)|\(signature)"
            partial[key] = value
            for callback in observers[key]?.values ?? Dictionary<UUID, @Sendable (BalanceRecord) -> Void>().values { callback(value) }
        }
    }

    private func resolve(_ items: [AddressItem], coin: Coin, services: [BalanceService], network: EVMNetwork?,
                         update: ([String: BalanceRecord]) -> Void) async throws -> [String: BalanceRecord] {
        if let network {
            do { try await verifyNetwork(network) }
            catch {
                let message = (error as? EVMNetworkError)?.localizedDescription ?? safeMessage(error)
                let failed = Dictionary(uniqueKeysWithValues: items.map { ($0.address, BalanceRecord.failed(message)) })
                update(failed); return failed
            }
        }
        var results: [String: BalanceRecord] = [:]
        var remaining = items
        for (serviceIndex, service) in services.enumerated() {
            guard !remaining.isEmpty else { break }
            let size: Int
            switch service.endpoint.provider {
            case .blockchain, .solanaRPC: size = 100
            case .chainz: size = 50
            default: size = 1
            }
            let chunks = stride(from: 0, to: remaining.count, by: size).map {
                Array(remaining[$0..<min($0 + size, remaining.count)])
            }
            await withTaskGroup(of: [String: BalanceRecord].self) { group in
                var iterator = chunks.makeIterator()
                func enqueue(_ chunk: [AddressItem]) {
                    group.addTask { await self.fetchChunk(chunk, coin: coin, service: service, network: network) }
                }
                for _ in 0..<3 { if let chunk = iterator.next() { enqueue(chunk) } }
                while let values = await group.next() {
                    results.merge(values) { _, new in new }
                    // A primary failure remains pending until its backup finishes.
                    update(values.filter { $0.value.status == .loaded || serviceIndex == services.count - 1 })
                    if let chunk = iterator.next() { enqueue(chunk) }
                }
            }
            remaining = remaining.filter { results[$0.address]?.status != .loaded }
        }
        return results
    }

    private func fetchChunk(_ items: [AddressItem], coin: Coin, service: BalanceService, network: EVMNetwork?) async -> [String: BalanceRecord] {
        do {
            guard let url = URL(string: service.endpoint.url), url.scheme?.lowercased() == "https",
                  url.host != nil, url.user == nil, url.password == nil else { throw BalanceSettingsError.invalidURL }
            if [.etherscan, .tronGrid, .chainz, .okLink].contains(service.endpoint.provider), service.apiKey.isEmpty {
                throw BalanceSettingsError.missingKey
            }
            let values: [String: BalanceRecord]
            if let network {
                values = [items[0].id: try await fetchEVM(address: items[0].address, network: network)]
            } else { switch service.endpoint.provider {
            case .chainz: values = try await fetchChainz(items, url: url, key: service.apiKey)
            case .blockchain: values = try await fetchBlockchain(items, url: url)
            case .solanaRPC: values = try await fetchSolana(items, url: url, key: service.apiKey)
            default:
                let item = items[0]
                values = [item.id: try await fetchDirect(address: item.address, coin: coin, provider: service.endpoint.provider,
                                                        baseURL: url, key: service.apiKey)]
            } }
            var result: [String: BalanceRecord] = [:]
            for item in items {
                let value = values[item.id] ?? .failed("服务未返回此地址的结果")
                result[item.address] = value.stamped(source: service.endpoint.provider.title + " · " + (URL(string: service.endpoint.url)?.host ?? ""))
            }
            return result
        } catch {
            // Never include raw URLs, response text or API keys in errors shown to the user.
            return Dictionary(uniqueKeysWithValues: items.map {
                ($0.address, BalanceRecord.failed(safeMessage(error)).stamped(source: service.endpoint.provider.title + " · " + (URL(string: service.endpoint.url)?.host ?? "")))
            })
        }
    }

    private func networkRPC(_ network: EVMNetwork, method: String, params: [String]) async throws -> String {
        try network.validate()
        let base = URL(string: network.rpcURL)!
        var request = URLRequest(url: try resolvedRPCURL(base, key: network.apiKey))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
        let data = try await perform(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let value = root["result"] as? String, value.hasPrefix("0x"), value.count > 2 else { throw BalanceClientError.invalidResponse }
        return value
    }

    private func verifyNetwork(_ network: EVMNetwork) async throws {
        let value = try await networkRPC(network, method: "eth_chainId", params: [])
        guard decimalInteger(hex: value) == network.chainID else { throw EVMNetworkError.wrongChain }
    }

    private func fetchEVM(address: String, network: EVMNetwork) async throws -> BalanceRecord {
        let value = try await networkRPC(network, method: "eth_getBalance", params: [address, "latest"])
        guard let integer = decimalInteger(hex: value),
              let amount = decimalAmount(integer, places: network.decimals) else { throw BalanceClientError.invalidResponse }
        return BalanceRecord(status: .loaded, balance: amount + " " + network.symbol, transactionCount: nil, received: nil)
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? BalanceHTTPError { return error.localizedDescription }
        if let error = error as? BalanceSettingsError { return error.localizedDescription }
        if let error = error as? BalanceClientError {
            if case .server = error { return "服务返回错误，请检查额度、凭据或服务状态" }
            return error.localizedDescription
        }
        if let error = error as? URLError, error.code == .timedOut { return "查询超时，请重试" }
        return "查询失败，请检查网络或服务配置"
    }

    private var unavailable: BalanceRecord { .failed("服务未返回有效余额") }

    private func fetchBlockchain(_ items: [AddressItem], url: URL) async throws -> [String: BalanceRecord] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "cors", value: "true"),
                                 URLQueryItem(name: "active", value: items.map(\.address).joined(separator: "|"))]
        let data = try await perform(URLRequest(url: components.url!))
        return Dictionary(uniqueKeysWithValues: items.map { item in
            (item.id, (try? parseDirect(data: data, address: item.address, coin: .BTC, provider: .blockchain)) ?? unavailable)
        })
    }

    private func resolvedRPCURL(_ url: URL, key: String) throws -> URL {
        if endpointContainsKeyPlaceholder(url), key.isEmpty { throw BalanceSettingsError.missingKey }
        let escaped = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        guard let resolved = URL(string: url.absoluteString.replacingOccurrences(of: "%7BAPI_KEY%7D", with: escaped)) else {
            throw BalanceSettingsError.invalidURL
        }
        return resolved
    }

    private func fetchSolana(_ items: [AddressItem], url: URL, key: String) async throws -> [String: BalanceRecord] {
        let resolved = try resolvedRPCURL(url, key: key)
        var request = URLRequest(url: resolved)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "getMultipleAccounts",
            "params": [items.map(\.address), ["encoding": "base64", "commitment": "confirmed", "dataSlice": ["offset": 0, "length": 0]]] as [Any]
        ])
        let data = try await perform(request)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
              let result = root["result"] as? [String: Any], let values = result["value"] as? [Any], values.count == items.count else {
            throw BalanceClientError.invalidResponse
        }
        var records: [String: BalanceRecord] = [:]
        for (item, value) in zip(items, values) {
            let raw = value is NSNull ? "0" : stringValue((value as? [String: Any])?["lamports"])
            if let raw, let amount = decimalAmount(raw, places: 9) {
                records[item.id] = BalanceRecord(status: .loaded, balance: "\(amount) SOL", transactionCount: nil, received: nil)
            } else { records[item.id] = unavailable }
        }
        return records
    }

    private func fetchChainz(_ items: [AddressItem], url: URL, key: String) async throws -> [String: BalanceRecord] {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: "getbalances"), URLQueryItem(name: "key", value: key)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Array(Set(items.map(\.address))).sorted())
        let data = try await perform(request)
        var records: [String: BalanceRecord] = [:]
        for item in items {
            records[item.id] = (try? parseDirect(data: data, address: item.address, coin: .LTC, provider: .chainz)) ?? unavailable
        }
        return records
    }

    private func fetchDirect(address: String, coin: Coin, provider: BalanceProvider, baseURL: URL, key: String) async throws -> BalanceRecord {
        var request: URLRequest
        switch provider {
        case .blockcypher:
            var components = URLComponents(url: baseURL.appendingPathComponent("addrs").appendingPathComponent(address).appendingPathComponent("balance"), resolvingAgainstBaseURL: false)!
            if !key.isEmpty { components.queryItems = [URLQueryItem(name: "token", value: key)] }
            request = URLRequest(url: components.url!)
        case .blockchain:
            throw BalanceClientError.invalidResponse
        case .blockchair:
            let chain: String
            switch coin {
            case .BTC: chain = "bitcoin"
            case .LTC: chain = "litecoin"
            case .DOGE: chain = "dogecoin"
            default: throw BalanceClientError.invalidResponse
            }
            let url = baseURL.appendingPathComponent(chain).appendingPathComponent("dashboards/address").appendingPathComponent(address)
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "limit", value: "0")]
            if !key.isEmpty { components.queryItems?.append(URLQueryItem(name: "key", value: key)) }
            request = URLRequest(url: components.url!)
        case .etherscan:
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "chainid", value: coin == .BSC ? "56" : "1"),
                URLQueryItem(name: "module", value: "account"),
                URLQueryItem(name: "action", value: "balance"),
                URLQueryItem(name: "address", value: address),
                URLQueryItem(name: "tag", value: "latest"),
                URLQueryItem(name: "apikey", value: key)
            ]
            request = URLRequest(url: components.url!)
        case .evmRPC:
            request = URLRequest(url: try resolvedRPCURL(baseURL, key: key))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "eth_getBalance", "params": [address, "latest"]
            ])
        case .tronGrid:
            request = URLRequest(url: baseURL.appendingPathComponent("v1/accounts").appendingPathComponent(address))
            request.setValue(key, forHTTPHeaderField: "TRON-PRO-API-KEY")
        case .solanaRPC:
            if endpointContainsKeyPlaceholder(baseURL), key.isEmpty { throw BalanceSettingsError.missingKey }
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
            let resolved = baseURL.absoluteString.replacingOccurrences(of: "%7BAPI_KEY%7D", with: escapedKey)
            guard let url = URL(string: resolved) else { throw BalanceSettingsError.invalidURL }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": 1, "method": "getBalance", "params": [address]
            ])
        case .chainz:
            throw BalanceClientError.invalidResponse
        case .okLink:
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "chainShortName", value: coin.rawValue), URLQueryItem(name: "address", value: address)]
            request = URLRequest(url: components.url!)
            request.setValue(key, forHTTPHeaderField: "Ok-Access-Key")
        }

        let data = try await perform(request)
        return try parseDirect(data: data, address: address, coin: coin, provider: provider)
    }

    func parseDirect(data: Data, address: String, coin: Coin, provider: BalanceProvider) throws -> BalanceRecord {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BalanceClientError.invalidResponse
        }
        let amount: String
        var transactions: String?
        var received: String?
        let decimals: Int?
        switch provider {
        case .blockchain:
            guard let account = root[address] as? [String: Any], let value = stringValue(account["final_balance"]) else {
                throw BalanceClientError.invalidResponse
            }
            amount = value
            transactions = stringValue(account["n_tx"])
            received = stringValue(account["total_received"])
            decimals = 8
        case .blockcypher:
            guard root["error"] == nil, root["address"] as? String == address,
                  let value = stringValue(root["final_balance"] ?? root["balance"]) else { throw BalanceClientError.invalidResponse }
            amount = value
            transactions = stringValue(root["n_tx"])
            received = stringValue(root["total_received"])
            decimals = 8
        case .blockchair:
            guard let context = root["context"] as? [String: Any],
                  (context["code"] as? NSNumber)?.intValue == 200,
                  let payload = root["data"] as? [String: Any],
                  let details = payload[address] as? [String: Any],
                  let account = details["address"] as? [String: Any],
                  let value = stringValue(account["balance"])
            else { throw BalanceClientError.invalidResponse }
            amount = value
            transactions = stringValue(account["transaction_count"])
            received = stringValue(account["received"])
            decimals = 8
        case .etherscan:
            guard stringValue(root["status"]) == "1", let value = stringValue(root["result"]) else {
                throw BalanceClientError.server(root["result"] as? String ?? root["message"] as? String ?? "Etherscan 查询失败")
            }
            amount = value
            decimals = 18
        case .evmRPC:
            guard root["error"] == nil,
                  let value = root["result"] as? String,
                  let integer = decimalInteger(hex: value)
            else { throw BalanceClientError.invalidResponse }
            amount = integer
            decimals = 18
        case .tronGrid:
            guard root["success"] as? Bool == true, let accounts = root["data"] as? [[String: Any]] else {
                throw BalanceClientError.invalidResponse
            }
            amount = stringValue(accounts.first?["balance"]) ?? "0"
            decimals = 6
        case .solanaRPC:
            guard root["error"] == nil,
                  let result = root["result"] as? [String: Any],
                  let value = stringValue(result["value"])
            else { throw BalanceClientError.invalidResponse }
            amount = value
            decimals = 9
        case .chainz:
            guard let value = stringValue(root[address]) else { throw BalanceClientError.invalidResponse }
            amount = value
            decimals = nil
        case .okLink:
            guard stringValue(root["code"]) == "0",
                  let data = root["data"] as? [[String: Any]],
                  let account = data.first,
                  let value = stringValue(account["balance"])
            else { throw BalanceClientError.invalidResponse }
            amount = value
            transactions = stringValue(account["transactionCount"])
            received = stringValue(account["receiveAmount"])
            decimals = nil
        }
        let balance: String
        if let decimals {
            guard let converted = decimalAmount(amount, places: decimals) else { throw BalanceClientError.invalidResponse }
            balance = converted
            if let rawReceived = received { received = decimalAmount(rawReceived, places: decimals) }
        } else {
            balance = amount
        }
        return BalanceRecord(status: .loaded, balance: "\(balance) \(coin.rawValue == "BSC" ? "BNB" : coin.rawValue)", transactionCount: transactions, received: received)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for attempt in 0..<2 {
            do {
                let (data, response) = try await send(request)
                guard let response = response as? HTTPURLResponse else { throw BalanceClientError.invalidResponse }
                guard (200...299).contains(response.statusCode) else {
                    if attempt == 0, response.statusCode == 429 || response.statusCode >= 500 {
                        let host = request.url?.host ?? ""
                        let delay = retryDelay(response.value(forHTTPHeaderField: "Retry-After")) ?? 1
                        nextRequest[host] = max(nextRequest[host] ?? .distantPast, Date().addingTimeInterval(delay))
                        if delay > 3 { cooldown[host] = (Date().addingTimeInterval(delay), response.statusCode) }
                        if delay <= 3 {
                            try await Task.sleep(for: .seconds(delay))
                            continue
                        }
                    }
                    throw BalanceHTTPError(status: response.statusCode)
                }
                return data
            } catch {
                if attempt == 0, let network = error as? URLError,
                   [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code) { continue }
                throw error
            }
        }
        throw BalanceClientError.invalidResponse
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        while activeRequests >= 3 { try await Task.sleep(for: .milliseconds(25)) }
        try Task.checkCancellation()
        activeRequests += 1
        defer { activeRequests -= 1 }
        let host = request.url?.host ?? ""
        if let state = cooldown[host], state.until > Date() { throw BalanceHTTPError(status: state.status) }
        let start = max(Date(), nextRequest[host] ?? .distantPast)
        // Host-wide pacing applies across coins and concurrent views.
        nextRequest[host] = start.addingTimeInterval(requestSpacing)
        let delay = start.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        return try await session.data(for: request)
    }

    private func retryDelay(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private func endpointContainsKeyPlaceholder(_ url: URL) -> Bool {
        url.absoluteString.contains("%7BAPI_KEY%7D")
    }

    private func decimalAmount(_ raw: String, places: Int) -> String? {
        guard !raw.isEmpty, raw.allSatisfy(\.isNumber) else { return nil }
        let padded = String(repeating: "0", count: max(0, places + 1 - raw.count)) + raw
        let split = padded.index(padded.endIndex, offsetBy: -places)
        let whole = String(padded[..<split]).drop(while: { $0 == "0" })
        let fraction = String(padded[split...]).reversed().drop(while: { $0 == "0" }).reversed()
        return (whole.isEmpty ? "0" : String(whole)) + (fraction.isEmpty ? "" : "." + String(fraction))
    }

    private func decimalInteger(hex: String) -> String? {
        guard hex.hasPrefix("0x"), !hex.dropFirst(2).isEmpty else { return nil }
        var digits = [0]
        for character in hex.dropFirst(2) {
            guard let value = character.hexDigitValue else { return nil }
            var carry = value
            for index in digits.indices {
                let next = digits[index] * 16 + carry
                digits[index] = next % 10
                carry = next / 10
            }
            while carry > 0 {
                digits.append(carry % 10)
                carry /= 10
            }
        }
        return digits.reversed().map(String.init).joined()
    }

    private func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}


enum BalanceResultFilter: String, CaseIterable, Identifiable {
    case all, funded, activity, failed
    var id: Self { self }
    var title: String {
        switch self { case .all: "全部"; case .funded: "有余额"; case .activity: "有交易记录"; case .failed: "失败" }
    }
    func includes(_ value: BalanceRecord?) -> Bool {
        switch self {
        case .all: true
        case .funded: value?.status == .loaded && BalanceRecord.isNonZero(value?.balance)
        case .activity: value?.status == .loaded && (BalanceRecord.isNonZero(value?.transactionCount) || BalanceRecord.isNonZero(value?.received))
        case .failed: value?.status == .unavailable
        }
    }
}
