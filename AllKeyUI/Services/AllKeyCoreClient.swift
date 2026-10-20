import Foundation

actor AllKeyCoreClient {
    static let shared = AllKeyCoreClient()

    private struct Request: Encodable {
        let btcType: String
        let puzzleNumber: Int?
        let index: String
        let coins: [String]
        let count: Int
        let op: String
    }

    private struct MnemonicRequest: Encodable {
        let customPath: String
        let targetAddress: String?
        let targetCoin: String?
        let account: Int
        let passphrase: String
        let addressStart: Int
        let btcType: String
        let pathPreset: String
        let pattern: String?
        let cursor: String?
        let bitSize: Int
        let count: Int
        let coins: [String]
        let index: String
        let op: String
    }

    private struct ElectrumRequest: Encodable {
        let count: Int
        let addressType: String
        let index: String
        let op: String
    }

    func createKeys(
        index: String,
        coins: Set<Coin>,
        count: Int,
        operation: CoreNavigation = .current,
        puzzleNumber: Int? = nil,
        btcType: BTCPrivateKeyAddressType = .all
    ) throws -> KeyResult {
        try Task.checkCancellation()
        let request = Request(
            btcType: btcType.rawValue,
            puzzleNumber: puzzleNumber,
            index: index,
            coins: coins.map(\.rawValue).sorted(),
            count: count,
            op: operation.rawValue
        )
        let envelope: CoreEnvelope<KeyResult> = try call(request, function: AllKeyCreateKeys)
        if let result = envelope.data, envelope.ok {
            return KeyResult(inputFormat: result.inputFormat, wifCompressed: result.wifCompressed, index: result.index,
                             items: AddressProjection.addingNetworks(to: result.items, networks: BalanceSettings.evmNetworks))
        }
        throw envelope.error ?? CoreAPIError(code: "unknown_error", message: "未知核心错误")
    }

    func createMnemonic(
        bitSize: Int,
        count: Int,
        coins: Set<Coin>,
        index: String,
        operation: CoreNavigation,
        pattern: String? = nil,
        cursor: String? = nil,
        addressStart: Int = 0,
        btcType: BTCMnemonicAddressType = .all,
        pathPreset: MnemonicPathPreset = .receive,
        account: Int = 0,
        passphrase: String = "",
        customPath: String = "",
        targetAddress: String? = nil,
        targetCoin: Coin? = nil
    ) throws -> MnemonicResult {
        try Task.checkCancellation()
        let request = MnemonicRequest(
            customPath: customPath,
            targetAddress: targetAddress,
            targetCoin: targetCoin?.rawValue,
            account: account,
            passphrase: passphrase,
            addressStart: addressStart,
            btcType: btcType.rawValue,
            pathPreset: pathPreset.rawValue,
            pattern: pattern,
            cursor: cursor,
            bitSize: bitSize,
            count: count,
            coins: coins.map(\.rawValue).sorted(),
            index: index,
            op: operation.rawValue
        )
        let envelope: CoreEnvelope<MnemonicResult> = try call(request, function: AllKeyCreateMnemonic)
        if let result = envelope.data, envelope.ok {
            return MnemonicResult(matchedItem: result.matchedItem, searchCursor: result.searchCursor,
                                  mnemonic: result.mnemonic, index: result.index, max: result.max,
                                  items: AddressProjection.addingNetworks(to: result.items, networks: BalanceSettings.evmNetworks))
        }
        throw envelope.error ?? CoreAPIError(code: "unknown_error", message: "未知核心错误")
    }

    func createMnemonicPage(bitSize: Int, pageSize: Int, coins: Set<Coin>, index: String,
                            operation: CoreNavigation, btcType: BTCMnemonicAddressType = .all) throws -> MnemonicPageResult {
        struct Request: Encodable {
            let bitSize: Int
            let pageSize: Int
            let coins: [String]
            let index: String
            let op: String
            let btcType: String
        }
        try Task.checkCancellation()
        let request = Request(bitSize: bitSize, pageSize: pageSize, coins: coins.map(\.rawValue).sorted(), index: index, op: operation.rawValue, btcType: btcType.rawValue)
        let response: CoreEnvelope<MnemonicPageResult> = try call(request, function: AllKeyCreateMnemonicPage)
        guard response.ok, let page = response.data else { throw response.error ?? CoreAPIError(code: "directory_error", message: "目录生成失败") }
        let networks = BalanceSettings.evmNetworks
        return MnemonicPageResult(start: page.start, end: page.end, max: page.max, hasPrevious: page.hasPrevious, hasNext: page.hasNext,
            items: page.items.map { item in
                MnemonicResult(mnemonic: item.mnemonic, index: item.index, max: item.max,
                               items: AddressProjection.addingNetworks(to: item.items, networks: networks))
            })
    }

    func inspectMnemonic(text: String, bitSize: Int, completionPosition: Int? = nil) throws -> MnemonicInputInspection {
        struct Request: Encodable {
            let text: String
            let bitSize: Int
            let completionPosition: Int?
        }
        try Task.checkCancellation()
        let response: CoreEnvelope<MnemonicInputInspection> = try call(
            Request(text: text, bitSize: bitSize, completionPosition: completionPosition), function: AllKeyInspectMnemonic)
        if response.ok, let value = response.data { return value }
        throw response.error ?? CoreAPIError(code: "inspection_error", message: "无法校验输入")
    }

    func createElectrum(
        count: Int,
        addressType: String,
        index: String,
        operation: CoreNavigation
    ) throws -> MnemonicResult {
        let request = ElectrumRequest(
            count: count,
            addressType: addressType,
            index: index,
            op: operation.rawValue
        )
        let envelope: CoreEnvelope<MnemonicResult> = try call(request, function: AllKeyCreateElectrum)
        if let result = envelope.data, envelope.ok {
            return result
        }
        throw envelope.error ?? CoreAPIError(code: "unknown_error", message: "未知核心错误")
    }

    private func call<Request: Encodable, Response: Codable>(
        _ request: Request,
        function: (UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) throws -> CoreEnvelope<Response> {
        let requestData = try JSONEncoder().encode(request)
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw CoreAPIError(code: "encoding_error", message: "无法编码请求")
        }
        let responseJSON: String = requestJSON.withCString { requestPointer in
            guard let responsePointer = function(UnsafeMutablePointer(mutating: requestPointer)) else {
                return ""
            }
            defer { AllKeyFree(responsePointer) }
            return String(cString: responsePointer)
        }
        guard let responseData = responseJSON.data(using: .utf8) else {
            throw CoreAPIError(code: "bridge_error", message: "原生核心返回了无效数据")
        }
        return try JSONDecoder().decode(CoreEnvelope<Response>.self, from: responseData)
    }
}
