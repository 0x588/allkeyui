import Foundation
import Darwin

enum BalanceProvider: String, Codable, CaseIterable, Identifiable {
    case blockchain, blockcypher, blockchair, etherscan, evmRPC, tronGrid, solanaRPC, chainz, okLink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blockchain: "Blockchain.info"
        case .blockcypher: "BlockCypher"
        case .blockchair: "Blockchair"
        case .etherscan: "Etherscan V2"
        case .evmRPC: "EVM JSON-RPC"
        case .tronGrid: "TronGrid"
        case .solanaRPC: "Solana RPC"
        case .chainz: "Chainz CryptoID"
        case .okLink: "OKLink"
        }
    }

    var defaultURL: String {
        switch self {
        case .blockchain: "https://blockchain.info/balance"
        case .blockcypher: "https://api.blockcypher.com/v1/doge/main"
        case .blockchair: "https://api.blockchair.com"
        case .etherscan: "https://api.etherscan.io/v2/api"
        case .evmRPC: "https://bsc-dataseed.bnbchain.org"
        case .tronGrid: "https://api.trongrid.io"
        case .solanaRPC: "https://api.mainnet.solana.com"
        case .chainz: "https://chainz.cryptoid.info/ltc/api.dws"
        case .okLink: "https://www.oklink.com/api/v5/explorer/address/address-summary"
        }
    }

    func defaultURL(for coin: Coin) -> String {
        if self == .evmRPC, coin == .ETH { return "https://ethereum-rpc.publicnode.com" }
        return defaultURL
    }

    static func choices(for coin: Coin) -> [BalanceProvider] {
        switch coin {
        case .BTC: [.blockchain, .blockchair]
        case .LTC: [.blockchair, .chainz]
        case .DOGE: [.blockcypher, .blockchair, .okLink]
        case .ETH: [.evmRPC, .etherscan]
        case .BSC: [.evmRPC, .etherscan]
        case .TRX: [.tronGrid]
        case .SOL: [.solanaRPC]
        }
    }
}

enum BalanceServiceRole: String, CaseIterable, Identifiable {
    case primary, backup
    var id: Self { self }
    var title: String { self == .primary ? "主服务" : "备用服务" }
    var defaultsKey: String { self == .primary ? "balance.endpoints.v1" : "balance.backup-endpoints.v1" }
}

struct BalanceEndpoint: Codable {
    let provider: BalanceProvider
    let url: String
}

enum BalanceSettingsError: LocalizedError {
    case invalidURL, missingKey, invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTPS 服务地址"
        case .missingKey: "此平台需要 API Key"
        case .invalidConfiguration: "无法读取余额配置，请检查 JSON 格式、版本及文件权限"
        }
    }
}

struct StoredBalanceService: Codable {
    let endpoint: BalanceEndpoint
    let apiKey: String
}

struct BalanceFileConfiguration: Codable {
    var evmNetworks: [EVMNetwork]? = nil
    var version = 1
    var primary: [String: StoredBalanceService] = [:]
    var backup: [String: StoredBalanceService] = [:]

    subscript(coin: Coin, role: BalanceServiceRole) -> StoredBalanceService? {
        get { role == .primary ? primary[coin.rawValue] : backup[coin.rawValue] }
        set {
            if role == .primary { primary[coin.rawValue] = newValue }
            else { backup[coin.rawValue] = newValue }
        }
    }
}

/// Dedicated local JSON store. Atomic replacement preserves the previous file on write failure.
struct BalanceConfigurationStore {
    let fileURL: URL

    func load() throws -> BalanceFileConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return BalanceFileConfiguration() }
        do {
            let data = try Data(contentsOf: fileURL)
            let cleaned = try Self.removingRetiredServices(data)
            let config = try JSONDecoder().decode(BalanceFileConfiguration.self, from: cleaned.data)
            guard config.version == 1 else { throw BalanceSettingsError.invalidConfiguration }
            try EVMNetwork.validateList(config.evmNetworks ?? [])
            if cleaned.changed { try save(config) }
            return config
        } catch { throw BalanceSettingsError.invalidConfiguration }
    }

    private static func removingRetiredServices(_ data: Data) throws -> (data: Data, changed: Bool) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BalanceSettingsError.invalidConfiguration
        }
        var changed = false
        for role in ["primary", "backup"] {
            guard var services = root[role] as? [String: Any] else { continue }
            for (coin, raw) in services {
                let service = raw as? [String: Any]
                let endpoint = service?["endpoint"] as? [String: Any]
                if endpoint?["provider"] as? String == "allKey" {
                    services.removeValue(forKey: coin)
                    changed = true
                }
            }
            root[role] = services
        }
        return (changed ? try JSONSerialization.data(withJSONObject: root) : data, changed)
    }

    func prepareDirectory() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    func save(_ configuration: BalanceFileConfiguration) throws {
        try prepareDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".balance-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

enum BalanceSettings {
    static let autoRefreshStorageKey = "balance.auto-refresh-on-navigation.v1"

    static var autoRefreshEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoRefreshStorageKey)
    }

    static var configurationURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AllKeyUI", isDirectory: true)
            .appendingPathComponent("balance-settings.json")
    }

    private static var store: BalanceConfigurationStore { BalanceConfigurationStore(fileURL: configurationURL) }

    static var configurationError: String? {
        do { _ = try configuration(); return nil }
        catch { return error.localizedDescription }
    }

    static func prepareConfigurationDirectory() throws { try store.prepareDirectory() }

    private static func configuration() throws -> BalanceFileConfiguration {
        if FileManager.default.fileExists(atPath: configurationURL.path) { return try store.load() }
        // Retain old public endpoints without touching the old Keychain items.
        var config = BalanceFileConfiguration()
        for role in BalanceServiceRole.allCases {
            guard let data = UserDefaults.standard.data(forKey: role.defaultsKey),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            for (name, value) in raw {
                guard let endpointData = try? JSONSerialization.data(withJSONObject: value),
                      let endpoint = try? JSONDecoder().decode(BalanceEndpoint.self, from: endpointData) else { continue }
                guard let coin = Coin(rawValue: name) else { continue }
                config[coin, role] = StoredBalanceService(endpoint: endpoint, apiKey: "")
            }
        }
        return config
    }

    static var evmNetworks: [EVMNetwork] { (try? configuration())?.evmNetworks ?? [] }

    static func saveEVMNetworks(_ networks: [EVMNetwork]) throws {
        try EVMNetwork.validateList(networks)
        var config = try configuration()
        config.evmNetworks = networks
        try store.save(config)
    }

    static func endpoint(for coin: Coin, role: BalanceServiceRole = .primary) -> BalanceEndpoint? {
        (try? configuration())?[coin, role]?.endpoint
    }

    static func apiKey(for coin: Coin, role: BalanceServiceRole = .primary) -> String? {
        (try? configuration())?[coin, role]?.apiKey
    }

    static func save(_ endpoint: BalanceEndpoint, apiKey: String, for coin: Coin, role: BalanceServiceRole = .primary) throws {
        guard BalanceProvider.choices(for: coin).contains(endpoint.provider),
              let url = URL(string: endpoint.url),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil
        else { throw BalanceSettingsError.invalidURL }

        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if [.etherscan, .tronGrid, .chainz, .okLink].contains(endpoint.provider), key.isEmpty {
            throw BalanceSettingsError.missingKey
        }
        if [.solanaRPC, .evmRPC].contains(endpoint.provider),
           url.absoluteString.contains("%7BAPI_KEY%7D"), key.isEmpty {
            throw BalanceSettingsError.missingKey
        }

        var config = try configuration()
        config[coin, role] = StoredBalanceService(endpoint: endpoint, apiKey: key)
        try store.save(config)
    }

    static func remove(for coin: Coin, role: BalanceServiceRole = .primary) throws {
        var config = try configuration()
        config[coin, role] = nil
        try store.save(config)
    }


}


enum EVMNetworkError: LocalizedError {
    case invalidFields, duplicate, wrongChain
    var errorDescription: String? {
        switch self {
        case .invalidFields: "请填写网络名称、正整数链 ID、主币符号、0–36 位精度和有效 HTTPS RPC；浏览器地址可留空"
        case .duplicate: "网络 ID 或链 ID 重复，请编辑已有网络"
        case .wrongChain: "RPC 返回的链 ID 与配置不符，已停止查询"
        }
    }
}

struct EVMNetwork: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var chainID = ""
    var symbol = "ETH"
    var decimals = 18
    var rpcURL = ""
    var explorerURL = ""
    var apiKey = ""
    var enabled = true

    var info: EVMNetworkInfo { EVMNetworkInfo(id: id, name: name, chainID: chainID, symbol: symbol, decimals: decimals, explorerURL: explorerURL) }

    func validate() throws {
        func https(_ value: String) -> Bool {
            guard let url = URL(string: value) else { return false }
            return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 60,
              let number = UInt64(chainID), number > 0, String(number) == chainID,
              symbol.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$", options: .regularExpression) != nil,
              (0...36).contains(decimals), https(rpcURL), (explorerURL.isEmpty || https(explorerURL)) else { throw EVMNetworkError.invalidFields }
        if rpcURL.contains("{API_KEY}") || rpcURL.contains("%7BAPI_KEY%7D"), apiKey.isEmpty { throw BalanceSettingsError.missingKey }
    }

    static func validateList(_ networks: [Self]) throws {
        for network in networks { try network.validate() }
        guard Set(networks.map(\.id)).count == networks.count, Set(networks.map(\.chainID)).count == networks.count else { throw EVMNetworkError.duplicate }
    }
}
