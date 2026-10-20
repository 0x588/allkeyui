import Foundation

enum Coin: String, CaseIterable, Codable, Identifiable {
    case BTC, ETH, BSC, LTC, DOGE, TRX, SOL

    var id: String { rawValue }

    var name: String {
        switch self {
        case .BTC: "Bitcoin"
        case .ETH: "Ethereum"
        case .BSC: "BNB Smart Chain"
        case .LTC: "Litecoin"
        case .DOGE: "Dogecoin"
        case .TRX: "Tron"
        case .SOL: "Solana"
        }
    }

    func explorerURL(for address: String) -> URL? {
        let prefix: String
        switch self {
        case .BTC: prefix = "https://www.blockchain.com/explorer/addresses/btc/"
        case .ETH: prefix = "https://etherscan.io/address/"
        case .BSC: prefix = "https://bscscan.com/address/"
        case .LTC: prefix = "https://www.oklink.com/zh-hans/ltc/address/"
        case .DOGE: prefix = "https://www.oklink.com/zh-hans/doge/address/"
        case .TRX: prefix = "https://tronscan.org/#/address/"
        case .SOL: prefix = "https://solscan.io/account/"
        }
        return URL(string: prefix + address)
    }
}

struct AddressItem: Codable, Identifiable, Hashable {
    let coin: String
    let path: String
    let hexKey: String
    let keyTag: String
    let address: String
    let addressTag: String
    let balance: String
    let transactionCount: String
    let received: String

    var keyFormat: String? = nil
    var evmNetwork: EVMNetworkInfo? = nil

    var privateKeyLabel: String {
        switch keyFormat {
        case "wif": return "WIF 私钥"
        case "base58": return "Base58 私钥"
        default: return coin == "SOL" && path.isEmpty ? "十六进制种子" : "十六进制私钥"
        }
    }

    var alternateKeyLabel: String {
        coin == "BTC" ? "WIF 私钥" : coin == "SOL" ? "Base58 私钥" : "扩展格式"
    }

    var id: String {
        [balanceGroupKey, address, addressTag, path].joined(separator: ":")
    }

    var balanceGroupKey: String { evmNetwork.map { "EVM:" + $0.id.uuidString } ?? coin }
    var displayCoin: String { evmNetwork?.symbol ?? coin }
    var displayNetwork: String { evmNetwork?.name ?? Coin(rawValue: coin)?.name ?? coin }
    var explorerURL: URL? {
        if let network = evmNetwork {
            guard let base = URL(string: network.explorerURL), !network.explorerURL.isEmpty else { return nil }
            return base.appendingPathComponent("address").appendingPathComponent(address)
        }
        return Coin(rawValue: coin)?.explorerURL(for: address)
    }

    enum CodingKeys: String, CodingKey {
        case evmNetwork
        case coin, path, balance, received
        case keyFormat = "key_format"
        case hexKey = "hex_key"
        case keyTag = "key_tag"
        case address = "addr"
        case addressTag = "addr_tag"
        case transactionCount = "tx"
    }
}

enum BTCPrivateKeyAddressType: String, CaseIterable, Identifiable {
    case all, legacy, legacyUncompressed, segwit, nested, taproot
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部类型"
        case .legacy: "Legacy · 压缩"
        case .legacyUncompressed: "Legacy · 未压缩"
        case .segwit: "Native SegWit"
        case .nested: "Nested SegWit"
        case .taproot: "Taproot"
        }
    }
}

struct KeyResult: Codable {
    var inputFormat: String? = nil
    var wifCompressed: Bool? = nil
    let index: String
    let items: [AddressItem]
}

enum BTCMnemonicAddressType: String, CaseIterable, Identifiable {
    case all, legacy, segwit, nested, taproot
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部类型"
        case .legacy: "Legacy · BIP44"
        case .segwit: "SegWit · BIP84"
        case .nested: "Nested SegWit · BIP49"
        case .taproot: "Taproot · BIP86"
        }
    }
}

enum MnemonicPathPreset: String, CaseIterable, Identifiable {
    case receive, change
    var id: Self { self }
    var title: String { self == .receive ? "标准收款路径" : "UTXO 找零路径" }
}

struct MnemonicWordIssue: Codable, Identifiable {
    let position: Int
    let word: String
    var id: Int { position }
}

struct MnemonicInputInspection: Codable {
    let wordCount: Int
    let detectedBitSize: Int
    let missingCount: Int
    let invalidWords: [MnemonicWordIssue]
    let checksum: String
    let completionPosition: Int
    let suggestions: [String]
}

struct MnemonicResult: Codable {
    var matchedItem: AddressItem? = nil
    var searchCursor: String? = nil
    let mnemonic: String
    let index: String
    let max: String
    let items: [AddressItem]
}

enum CoreNavigation: String {
    case current
    case first
    case previous
    case random
    case next
    case last
    case search
    case jump
}

struct CoreAPIError: Codable, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct CoreEnvelope<Value: Codable>: Codable {
    let ok: Bool
    let data: Value?
    let error: CoreAPIError?
}


struct EVMNetworkInfo: Codable, Hashable {
    let id: UUID
    let name: String
    let chainID: String
    let symbol: String
    let decimals: Int
    let explorerURL: String
}

enum AddressProjection {
    static func addingNetworks(to items: [AddressItem], networks: [EVMNetwork]) -> [AddressItem] {
        items.flatMap { item -> [AddressItem] in
            guard item.coin == "ETH", item.evmNetwork == nil else { return [item] }
            return [item] + networks.filter(\.enabled).map { network in
                var copy = item
                copy.evmNetwork = network.info
                return copy
            }
        }
    }
}


struct MnemonicPageResult: Codable {
    let start: String
    let end: String
    let max: String
    let hasPrevious: Bool
    let hasNext: Bool
    let items: [MnemonicResult]
    var addresses: [AddressItem] { items.flatMap(\.items) }
}
