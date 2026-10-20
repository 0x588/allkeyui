import AppKit
import SwiftUI

@MainActor
final class BIP39ViewModel: ObservableObject {
    @Published var bitSize = 128
    @Published var btcAddressType: BTCMnemonicAddressType = .all
    @Published var pathPreset: MnemonicPathPreset = .receive
    @Published private(set) var addressStart = 0
    @Published var count = 1
    @Published var selectedCoins: Set<Coin> = [.BTC, .ETH]
    @Published var searchText = "" {
        didSet { completionPosition = nil; inspectInput() }
    }
    @Published var autoDetectWordCount = true {
        didSet { inspectInput() }
    }
    @Published var accountText = "0"
    @Published var passphrase = ""
    @Published var entropyIndexText = "0"
    @Published var addressJumpText = "0"
    @Published var customPathEnabled = false
    @Published var customPath = "m/84'/0'/0'/0/{index}"
    @Published private(set) var appliedCustomPath = ""
    @Published var targetAddress = ""
    @Published var targetCoin: Coin = .BTC
    @Published var matchLimitText = "1000"
    @Published private(set) var matchedCandidates = 0
    @Published private(set) var isMatchingAddress = false
    @Published private(set) var inputInspection: MnemonicInputInspection?
    @Published private(set) var inputInspectionSource: String?
    @Published private(set) var inputSelectionRequest: MnemonicInputSelection?
    @Published private(set) var inspectionError: String?
    @Published private(set) var appliedAccount = 0
    @Published private(set) var appliedPassphraseEnabled = false
    private var lastPassphrase = ""
    private var completionPosition: Int?
    private var inspectionTask: Task<Void, Never>?

    var accountNumber: Int? {
        guard let number = Int(accountText), (0..<(1 << 31)).contains(number) else { return nil }
        return number
    }

    var requestedCustomPath: String { customPathEnabled ? customPath.trimmingCharacters(in: .whitespacesAndNewlines) : "" }
    var canApplyDerivation: Bool { (!customPathEnabled && accountNumber != nil) || (customPathEnabled && selectedCoins.count == 1 && !requestedCustomPath.isEmpty) }
    var lastAddressStart: Int { max(0, (1 << 31) - count - (!customPathEnabled && selectedCoins.contains(.SOL) ? (accountNumber ?? 0) : 0)) }

    var hasUnappliedDerivation: Bool {
        result != nil && ((customPathEnabled != !appliedCustomPath.isEmpty) || (!customPathEnabled && accountNumber != appliedAccount) || passphrase != lastPassphrase || requestedCustomPath != appliedCustomPath)
    }

    var derivationSummary: String {
        (appliedCustomPath.isEmpty ? "账户 \(appliedAccount)" : "自定义路径 \(appliedCustomPath)")
            + " · Passphrase \(appliedPassphraseEnabled ? "已启用" : "未启用")"
            + (hasUnappliedDerivation ? " · 参数待应用" : "")
    }

    func setWordCount(_ bits: Int) {
        task?.cancel()
        isLoading = false
        activePattern = nil
        patternBitSize = nil
        autoDetectWordCount = false
        bitSize = bits
        inspectInput()
        generate(.first, addressStart: 0, useAppliedDerivation: true)
    }

    func selectCompletionPosition(_ position: Int) {
        let tokens = MnemonicCompletionTarget.tokens(in: searchText)
        guard tokens.indices.contains(position) else { return }
        completionPosition = position
        inputSelectionRequest = MnemonicInputSelection(range: NSRange(location: NSMaxRange(tokens[position].range), length: 0))
        inspectInput()
    }

    func updateEditorInput(_ text: String, selection: NSRange) {
        if searchText != text { searchText = text }
        updateCompletionSelection(selection)
    }

    func updateCompletionSelection(_ selection: NSRange) {
        let position = MnemonicCompletionTarget.atSelection(selection, in: searchText)?.position ?? -1
        guard completionPosition != position else { return }
        completionPosition = position
        inspectInput()
    }

    func completeWord(_ word: String) {
        guard let inspection = inputInspection, inspection.suggestions.contains(word),
              let edit = MnemonicCompletionEdit.make(text: searchText, position: inspection.completionPosition, word: word) else { return }
        searchText = edit.text
        completionPosition = -1
        inputSelectionRequest = MnemonicInputSelection(range: edit.selection)
        inspectInput()
    }

    private func detectWordCount() {
        guard autoDetectWordCount else { return }
        let count = searchText.split(whereSeparator: \.isWhitespace).count
        if [12, 15, 18, 21, 24].contains(count) {
            let detected = count / 3 * 32
            if detected != bitSize { activePattern = nil; patternBitSize = nil; bitSize = detected }
        }
    }

    private func inspectInput() {
        inspectionTask?.cancel()
        inputInspection = nil
        inputInspectionSource = nil
        inspectionError = nil
        detectWordCount()
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = searchText, bits = bitSize, position = completionPosition
        inspectionTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let inspection = try await AllKeyCoreClient.shared.inspectMnemonic(text: text, bitSize: bits, completionPosition: position)
                guard !Task.isCancelled, searchText == text, bitSize == bits else { return }
                inputInspectionSource = text
                inputInspection = inspection
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                inspectionError = "暂时无法校验输入，请重新输入后重试"
            }
        }
    }
    @Published private(set) var index = "0"
    @Published private(set) var result: MnemonicResult?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var copiedValue: String?
    @Published private(set) var balances: [String: BalanceRecord] = [:]
    @Published private(set) var isBalanceLoading = false
    @Published var balanceError: String?

    @Published private(set) var activePattern: String?
    @Published private(set) var searchedCandidates = 0
    private var patternBitSize: Int?

    private var task: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    @Published private(set) var balancePending: Set<String> = []
    private var balanceRequestID = UUID()
    private var balanceTask: Task<Void, Never>?

    func generate(_ operation: CoreNavigation = .current) {
        generate(operation, addressStart: 0)
    }

    /// Refresh common options without committing the advanced fields being edited.
    func refreshDerivation() {
        generate(result == nil ? .first : .current, addressStart: 0, useAppliedDerivation: true)
    }

    func jumpToEntropy() {
        generate(.jump, addressStart: 0, inputOverride: entropyIndexText)
    }

    func jumpToAddress() {
        guard result != nil else { return }
        guard let start = addressJumpNumber else { errorMessage = "地址起始索引须为 0–\(lastAddressStart) 的十进制整数"; return }
        generate(.current, addressStart: start)
    }

    private var addressJumpNumber: Int? {
        let text = addressJumpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), (0...lastAddressStart).contains(value) else { return nil }
        return value
    }

    func matchKnownAddress() {
        guard let start = addressJumpNumber else { errorMessage = "请填写有效的地址起始索引"; return }
        generate(.search, addressStart: start, matchTarget: true)
    }

    func navigateAddresses(_ direction: Int) {
        guard result != nil, !isLoading else { return }
        let start = min(max(0, addressStart + direction * count), lastAddressStart)
        guard start != addressStart else { return }
        generate(.current, addressStart: start)
    }

    private func generate(_ operation: CoreNavigation, addressStart requestedAddressStart: Int, inputOverride: String? = nil, matchTarget: Bool = false, useAppliedDerivation: Bool = false) {
        task?.cancel()
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isLoading = false
        isBalanceLoading = false
        isMatchingAddress = false
        if operation == .search { detectWordCount() }
        guard !selectedCoins.isEmpty else { errorMessage = "请至少选择一个币种"; return }
        let preserveApplied = useAppliedDerivation && result != nil
        let usesCustomPath = preserveApplied ? !appliedCustomPath.isEmpty : customPathEnabled
        guard let requestedAccount = preserveApplied ? appliedAccount : (usesCustomPath ? 0 : accountNumber) else {
            errorMessage = "账户编号必须在 0 到 2147483647 之间"; return
        }
        let requestedPath = preserveApplied ? appliedCustomPath : requestedCustomPath
        if usesCustomPath && (selectedCoins.count != 1 || requestedPath.isEmpty) {
            errorMessage = "自定义路径模式请仅选择一个币种，并填写路径"; return
        }
        let requestedPassphrase = preserveApplied ? lastPassphrase : passphrase
        let input = inputOverride ?? (operation == .search ? searchText : index)
        let requestPattern = operation == .jump ? nil : operation == .search
            ? (searchText.contains("?") ? searchText : nil)
            : (patternBitSize == bitSize ? activePattern : nil)
        let requestBitSize = bitSize, requestCount = count
        let requestCoins = selectedCoins
        let requestedBTCType = btcAddressType, requestedPreset = pathPreset
        let requestedTarget = targetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTargetCoin = targetCoin
        let limit = Int(matchLimitText) ?? 0
        if matchTarget {
            guard !requestedTarget.isEmpty, requestCoins.contains(requestedTargetCoin) else {
                errorMessage = "请填写目标公开地址，并在派生币种中选择该币种"; return
            }
            guard searchText.split(whereSeparator: \.isWhitespace).count == bitSize / 32 * 3 else {
                errorMessage = "地址匹配需填满所选词数，每个缺词使用 ?"; return
            }
            guard (1...10000).contains(limit) else { errorMessage = "候选上限须为 1–10000"; return }
        }
        isLoading = true
        isMatchingAddress = matchTarget
        searchedCandidates = 0
        matchedCandidates = 0
        errorMessage = nil

        task = Task {
            do {
                var cursor: String?
                var generated: MnemonicResult
                var candidateInput = input
                var candidateOperation = operation
                while true {
                    try Task.checkCancellation()
                    generated = try await AllKeyCoreClient.shared.createMnemonic(
                        bitSize: requestBitSize, count: requestCount, coins: requestCoins,
                        index: candidateInput, operation: candidateOperation, pattern: requestPattern, cursor: cursor,
                        addressStart: requestedAddressStart, btcType: requestedBTCType, pathPreset: requestedPreset,
                        account: requestedAccount, passphrase: requestedPassphrase, customPath: requestedPath,
                        targetAddress: matchTarget ? requestedTarget : nil, targetCoin: matchTarget ? requestedTargetCoin : nil
                    )
                    try Task.checkCancellation()
                    cursor = generated.searchCursor
                    if cursor != nil { searchedCandidates += 4096; continue }
                    if matchTarget {
                        matchedCandidates += 1
                        if generated.matchedItem != nil { break }
                        if requestPattern == nil { throw CoreAPIError(code: "no_match", message: "该助记词在所选地址范围内未匹配目标") }
                        if matchedCandidates >= limit { throw CoreAPIError(code: "search_limit", message: "已检查 \(limit) 个有效候选，未在所选地址范围内匹配；可调整上限、路径或范围后重试") }
                        candidateInput = generated.index
                        candidateOperation = .next
                        continue
                    }
                    break
                }
                guard !Task.isCancelled else { return }
                result = generated
                appliedAccount = requestedAccount
                appliedCustomPath = requestedPath
                appliedPassphraseEnabled = !requestedPassphrase.isEmpty
                lastPassphrase = requestedPassphrase
                index = generated.index
                entropyIndexText = generated.index
                addressStart = requestedAddressStart
                addressJumpText = String(requestedAddressStart)
                balances = [:]
                balanceError = nil
                if BalanceSettings.autoRefreshEnabled { fetchBalances(forceRefresh: true) }
                activePattern = requestPattern
                patternBitSize = requestPattern == nil ? nil : requestBitSize
                if (operation == .search && requestPattern == nil) || operation == .jump { searchText = "" }
            } catch is CancellationError { return }
            catch let error as CoreAPIError {
                guard !Task.isCancelled else { return }
                if matchTarget && ["已经是最后一个匹配结果", "该范围内没有符合校验和的匹配结果"].contains(error.message) {
                    errorMessage = "模板已遍历完毕，在所选路径及地址范围内未匹配目标"
                } else { errorMessage = error.message }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
            isMatchingAddress = false
        }
    }

    func suspendBalanceQuery() {
        balanceTask?.cancel(); balanceRequestID = UUID(); balancePending = []; isBalanceLoading = false
    }

    func cancelSearch() {
        task?.cancel()
        isMatchingAddress = false
        isLoading = false
    }

    func exitPatternSearch(clearInput: Bool = true) {
        cancelSearch()
        activePattern = nil
        patternBitSize = nil
        if clearInput { searchText = "" }
        errorMessage = nil
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        clipboardTask?.cancel()
        clipboardTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
            if copiedValue == value { copiedValue = nil }
        }
    }

    func fetchBalances(forceRefresh: Bool = false, onlyFailed: Bool = false) {
        guard let items = result?.items, !items.isEmpty else { return }
        let requestedItems = onlyFailed ? items.filter { balances[$0.id]?.status == .unavailable } : items
        guard !requestedItems.isEmpty else { return }
        balanceTask?.cancel()
        let requestID = UUID()
        balanceRequestID = requestID
        balancePending = Set(requestedItems.map(\.id))
        isBalanceLoading = true
        balanceError = nil
        balanceTask = Task { [self] in
            do {
                let records = try await BalanceClient.shared.fetch(items: requestedItems, forceRefresh: forceRefresh || onlyFailed) { [weak self] values in
                    Task { @MainActor in
                        guard let self, self.balanceRequestID == requestID else { return }
                        self.balances.merge(values) { _, new in new }
                        self.balancePending.subtract(values.keys)
                    }
                }
                guard !Task.isCancelled else { return }
                balances.merge(records) { _, new in new }
            } catch {
                guard !Task.isCancelled else { return }
                balanceError = error.localizedDescription
            }
            balancePending = []
            isBalanceLoading = false
        }
    }

    func clear() {
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isBalanceLoading = false
        exitPatternSearch()
        inspectionTask?.cancel()
        passphrase = ""
        lastPassphrase = ""
        targetAddress = ""
        matchedCandidates = 0
        appliedCustomPath = ""
        appliedAccount = 0
        appliedPassphraseEnabled = false
        index = "0"
        entropyIndexText = "0"
        addressStart = 0
        addressJumpText = "0"
        copiedValue = nil
        balanceError = nil
        inputInspection = nil
        inputInspectionSource = nil
        inputSelectionRequest = nil
        result = nil
        balances = [:]
    }
}

@MainActor
final class ElectrumViewModel: ObservableObject {
    @Published var count = 5
    @Published var addressType = "all"
    @Published var searchText = ""
    @Published private(set) var index = "0"
    @Published private(set) var result: MnemonicResult?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var copiedValue: String?
    @Published private(set) var balances: [String: BalanceRecord] = [:]
    @Published private(set) var isBalanceLoading = false
    @Published var balanceError: String?

    private var task: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    @Published private(set) var balancePending: Set<String> = []
    private var balanceRequestID = UUID()
    private var balanceTask: Task<Void, Never>?

    func refreshDerivation() {
        guard result != nil else { return }
        generate(.current)
    }

    func generate(_ operation: CoreNavigation = .current) {
        task?.cancel()
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isBalanceLoading = false
        let input = operation == .search ? searchText : index
        let requestCount = count
        let requestAddressType = addressType
        isLoading = true
        errorMessage = nil

        task = Task {
            do {
                let generated = try await AllKeyCoreClient.shared.createElectrum(
                    count: requestCount,
                    addressType: requestAddressType,
                    index: input,
                    operation: operation
                )
                guard !Task.isCancelled else { return }
                result = generated
                index = generated.index
                balances = [:]
                balanceError = nil
                if BalanceSettings.autoRefreshEnabled {
                    fetchBalances(forceRefresh: true)
                }
                if operation == .search { searchText = "" }
            } catch is CancellationError {
                return
            } catch let error as CoreAPIError {
                errorMessage = error.message
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        clipboardTask?.cancel()
        clipboardTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
            if copiedValue == value { copiedValue = nil }
        }
    }

    func fetchBalances(forceRefresh: Bool = false, onlyFailed: Bool = false) {
        guard let items = result?.items, !items.isEmpty else { return }
        let requestedItems = onlyFailed ? items.filter { balances[$0.id]?.status == .unavailable } : items
        guard !requestedItems.isEmpty else { return }
        balanceTask?.cancel()
        let requestID = UUID()
        balanceRequestID = requestID
        balancePending = Set(requestedItems.map(\.id))
        isBalanceLoading = true
        balanceError = nil
        balanceTask = Task { [self] in
            do {
                let records = try await BalanceClient.shared.fetch(items: requestedItems, forceRefresh: forceRefresh || onlyFailed) { [weak self] values in
                    Task { @MainActor in
                        guard let self, self.balanceRequestID == requestID else { return }
                        self.balances.merge(values) { _, new in new }
                        self.balancePending.subtract(values.keys)
                    }
                }
                guard !Task.isCancelled else { return }
                balances.merge(records) { _, new in new }
            } catch {
                guard !Task.isCancelled else { return }
                balanceError = error.localizedDescription
            }
            balancePending = []
            isBalanceLoading = false
        }
    }

    func clear() {
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isBalanceLoading = false
        task?.cancel()
        result = nil
        balances = [:]
    }
}

private enum MnemonicBrowseMode: String, CaseIterable, Identifiable {
    case single, directory, search
    var id: Self { self }
    var title: String {
        switch self {
        case .single: "单组派生"
        case .directory: "多组目录"
        case .search: "查找助记词"
        }
    }
    var description: String {
        switch self {
        case .single: "按熵索引浏览并派生地址"
        case .directory: "每页浏览多组助记词与余额"
        case .search: "完整助记词、前缀与缺词查询"
        }
    }
}

struct BIP39View: View {
    @StateObject private var model = BIP39ViewModel()
    @StateObject private var directory = MnemonicDirectoryViewModel()
    @State private var browseMode: MnemonicBrowseMode = .single
    @State private var showsHelp = false
    @State private var showsAdvancedSettings = false

    private var words: [Substring] { model.searchText.split(whereSeparator: \.isWhitespace) }
    private var expectedWords: Int { model.bitSize / 32 * 3 }
    private var missingCount: Int { words.filter { $0 == "?" }.count }
    private var canSearch: Bool {
        !words.isEmpty && !model.selectedCoins.isEmpty && !model.isLoading && model.canApplyDerivation
            && model.inputInspection?.invalidWords.isEmpty == true
            && model.inputInspection?.checksum != "invalid" && words.count <= expectedWords
            && (missingCount == 0 || words.count == expectedWords)
    }

    var body: some View {
        FeaturePage(
            title: "BIP39 助记词",
            subtitle: "查询、补全与浏览钱包地址",
            symbol: "text.book.closed"
        ) {
            MnemonicBrowseModeBar(selection: Binding(get: { browseMode }, set: selectMode))
            if browseMode == .directory {
                MnemonicDirectoryView(model: directory, copiedValue: model.copiedValue, copy: model.copy) { entry in
                    selectMode(.single)
                    model.exitPatternSearch()
                    model.bitSize = directory.bitSize
                    model.selectedCoins = directory.selectedCoins
                    model.btcAddressType = directory.btcType
                    model.count = 1; model.accountText = "0"; model.passphrase = ""
                    model.customPathEnabled = false; model.pathPreset = .receive
                    model.entropyIndexText = entry.index
                    model.jumpToEntropy()
                }
            } else {
            if browseMode == .search { search }
            settings
            if browseMode == .single { indexJumps }
            ResultState(
                isLoading: model.isLoading,
                error: model.selectedCoins.isEmpty ? nil : model.errorMessage,
                result: model.result,
                copiedValue: model.copiedValue,
                balances: model.balances,
                balancePending: model.balancePending,
                isBalanceLoading: model.isBalanceLoading,
                balanceError: model.balanceError,
                fetchBalances: { model.fetchBalances() },
                retryBalances: { model.fetchBalances(onlyFailed: true) },
                refreshBalances: { model.fetchBalances(forceRefresh: true) },
                copy: model.copy,
                activePattern: model.activePattern,
                navigation: model.generate,
                derivationSummary: model.derivationSummary,
                addressPagination: MnemonicAddressPagination(start: model.addressStart, count: model.count,
                    isLoading: model.isLoading, previous: { model.navigateAddresses(-1) }, next: { model.navigateAddresses(1) },
                    solAccountStart: model.selectedCoins.contains(.SOL) && model.appliedCustomPath.isEmpty ? model.appliedAccount : nil)
            )
            }
        }
        .onAppear { if model.result == nil { model.generate(.first) } }
        .onDisappear { model.clear(); directory.clear() }
        .onChange(of: model.count) { _ in refreshDerivation() }
        .onChange(of: model.btcAddressType) { _ in refreshDerivation() }
        .onChange(of: model.pathPreset) { _ in refreshDerivation() }
        .onChange(of: model.selectedCoins) { _ in refreshDerivation() }
    }

    private func selectMode(_ mode: MnemonicBrowseMode) {
        guard browseMode != mode else { return }
        model.cancelSearch()
        model.suspendBalanceQuery()
        directory.cancel()
        if mode == .single { model.exitPatternSearch(clearInput: false) }
        browseMode = mode
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            ParameterFlowLayout() {
                ParameterPicker(title: "助记词长度", width: 110, selection: Binding(get: { model.bitSize }, set: model.setWordCount)) {
                    ForEach([128, 160, 192, 224, 256], id: \.self) { bits in
                        Text("\(bits / 32 * 3) 词").tag(bits)
                    }
                }
                ParameterPicker(title: "每类地址 / 页", width: 130, selection: $model.count) {
                    ForEach([1, 2, 5, 10, 20], id: \.self) { Text("\($0) 个 / 页").tag($0) }
                }
                if model.selectedCoins.contains(.BTC) {
                    ParameterPicker(title: "BTC 地址类型", width: 210, selection: $model.btcAddressType) {
                        ForEach(BTCMnemonicAddressType.allCases) { Text($0.title).tag($0) }
                    }
                }
                ParameterPicker(title: "路径预设", width: 170, selection: $model.pathPreset) {
                    ForEach(MnemonicPathPreset.allCases) { Text($0.title).tag($0) }
                }
                .disabled(model.customPathEnabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("常用选项自动更新；高级参数点击应用后生效")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            coinSelection
            if model.selectedCoins.isEmpty { CoinSelectionWarning() }
            Divider()
            DisclosureGroup(isExpanded: $showsAdvancedSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    ParameterFlowLayout(horizontalSpacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(title: "账户编号 / SOL 起始账户")
                            TextField("0", text: $model.accountText)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospaced())
                                .frame(width: 180)
                                .accessibilityLabel("BIP39 账户编号")
                                .disabled(model.customPathEnabled)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(title: "BIP39 passphrase（可选）")
                            SecureField("留空使用无 passphrase 的钱包", text: $model.passphrase)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("BIP39 passphrase")
                                .frame(width: 300)
                        }
                    }
                    Text(model.customPathEnabled ? "自定义路径已启用；账户与路径预设不参与派生。" : model.accountNumber == nil
                         ? "账户编号范围为 0–2147483647。"
                         : "Passphrase 区分大小写和空格；修改后点击应用。")
                        .font(.caption)
                        .foregroundStyle(!model.customPathEnabled && model.accountNumber == nil ? Color.orange : Color.secondary)
                    Toggle("使用自定义路径（单币种）", isOn: $model.customPathEnabled)
                        .toggleStyle(.checkbox)
                    if model.customPathEnabled {
                        TextField("例如 m/84'/0'/0'/0/{index}", text: $model.customPath)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                            .onSubmit { model.generate(.current) }
                        Text("路径需包含一个 {index}；启用后忽略账户与路径预设。")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("硬化层使用 '。BTC 地址类型和 Passphrase 仍生效，SOL 每层都需硬化。修改后点击应用派生设置。")
                    }
                }
                .padding(.top, 8)
            } label: {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { FieldLabel(title: "高级派生设置"); advancedSummary }
                    VStack(alignment: .leading, spacing: 4) { FieldLabel(title: "高级派生设置"); advancedSummary }
                }
            }
            if showsAdvancedSettings || model.hasUnappliedDerivation {
                HStack(spacing: 10) {
                    if model.hasUnappliedDerivation {
                        Label("修改尚未应用", systemImage: "exclamationmark.circle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("点击应用以更新当前结果").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("应用派生设置") { model.generate(.current) }
                        .buttonStyle(.bordered)
                        .disabled(!model.canApplyDerivation || model.selectedCoins.isEmpty)
                }
            }
        }
        .disabled(model.isLoading)
        .panel()
    }

    private var advancedSummary: some View {
        Text(model.derivationSummary + (model.appliedCustomPath.isEmpty ? " · \(model.pathPreset.title)" : ""))
            .font(.caption)
            .foregroundStyle(model.hasUnappliedDerivation ? Color.orange : Color.secondary)
            .lineLimit(2)
            .help("显示当前结果使用的高级参数；修改后需点击应用派生设置。")
    }

    private var coinSelection: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: "币种 · 已选 \(model.selectedCoins.count)")
            ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(Coin.allCases) { coin in coinChip(coin) }
            }
        }
    }

    private var indexJumps: some View {
        DisclosureGroup("按索引跳转") {
            ParameterFlowLayout() {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "助记词熵索引（十进制）")
                    HStack(spacing: 8) {
                        TextField("0", text: $model.entropyIndexText)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 240)
                            .onSubmit { model.jumpToEntropy() }
                        Button("跳转助记词") { model.jumpToEntropy() }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "地址起始索引")
                    HStack(spacing: 8) {
                        TextField("0", text: $model.addressJumpText)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced()).frame(width: 120)
                            .onSubmit { model.jumpToAddress() }
                        Button("跳转地址") { model.jumpToAddress() }.disabled(model.result == nil)
                    }
                }
            }.padding(.top, 8)
            Text("熵索引范围 0–\(model.result?.max ?? "2^\(model.bitSize)−1")，跳转后退出缺词查询。地址跳转保留当前助记词与模板，起始索引最大 \(model.lastAddressStart)。")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }
        .disabled(model.isLoading).panel()
    }

    private func refreshDerivation() {
        guard !model.isLoading else { return }
        model.refreshDerivation()
    }

    private func coinChip(_ coin: Coin) -> some View {
        let selected = model.selectedCoins.contains(coin)
        return CoinToggle(coin: coin, isSelected: selected) {
            if selected { model.selectedCoins.remove(coin) }
            else { model.selectedCoins.insert(coin) }
        }
    }

    @ViewBuilder
    private var inputFeedback: some View {
        if let check = model.inputInspection {
            HStack(spacing: 10) {
                Label(check.wordCount == expectedWords ? "词数：完整" : "词数：\(check.wordCount)/\(expectedWords)",
                      systemImage: check.wordCount == expectedWords ? "checkmark.circle" : "text.alignleft")
                    .foregroundStyle(check.wordCount > expectedWords ? Color.orange : Color.secondary)
                Label(check.invalidWords.isEmpty ? "词表：通过" : "词表：\(check.invalidWords.count) 处待修正",
                      systemImage: check.invalidWords.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(check.invalidWords.isEmpty ? Theme.positive : Color.orange)
                Label(checksumLabel(check.checksum), systemImage: check.checksum == "valid" ? "checkmark.seal" : "info.circle")
                    .foregroundStyle(check.checksum == "invalid" ? Color.orange : Color.secondary)
            }
            .font(.caption)
            if !check.invalidWords.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(check.invalidWords) { issue in
                            Button("第 \(issue.position + 1) 词：\(issue.word)") { model.selectCompletionPosition(issue.position) }
                                .buttonStyle(.bordered)
                                .tint(.orange)
                        }
                    }
                }
                .font(.caption)
            }
            if check.checksum == "invalid" {
                Text("单词都在词表中，但校验和不通过。请核对单词及顺序；系统不会自动替换原文。")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else if let error = model.inspectionError {
            Text(error).font(.caption).foregroundStyle(.orange)
        }
    }

    private func checksumLabel(_ state: String) -> String {
        switch state {
        case "valid": "校验和：通过"
        case "invalid": "校验和：不通过"
        case "missing": "校验和：缺词待补全"
        default: "校验和：待完整输入"
        }
    }

    private var addressMatcher: some View {
        DisclosureGroup("用已知公开地址匹配缺词候选") {
            VStack(alignment: .leading, spacing: 8) {
                ParameterFlowLayout(horizontalSpacing: 12) {
                    ParameterPicker(title: "目标币种", width: 120, selection: $model.targetCoin) {
                        ForEach(Coin.allCases) { Text($0.rawValue).tag($0) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        FieldLabel(title: "目标主网公开地址")
                        TextField("填写完整公开地址", text: $model.targetAddress)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    }.frame(minWidth: 240, idealWidth: 360, maxWidth: 360)
                }
                ParameterFlowLayout() {
                    HStack(spacing: 8) {
                        Text("有效候选上限").font(.caption)
                        TextField("1000", text: $model.matchLimitText)
                            .textFieldStyle(.roundedBorder).frame(width: 80)
                    }
                    HStack(spacing: 8) {
                        Text("地址起始索引").font(.caption)
                        TextField("0", text: $model.addressJumpText)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                    }
                    Button("匹配目标地址") { model.matchKnownAddress() }
                        .buttonStyle(.bordered)
                        .disabled(!canSearch || model.targetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("仅在本机比较当前所选币种、BTC 类型、路径及每页地址范围；目标币种需勾选。填满所选词数，缺词用 ?。上限 1–10000 个有效候选；未匹配仅表示当前范围内未找到。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6).disabled(model.isLoading)
        }
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "查找助记词")
                Spacer()
                Button { showsHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                    .interactiveButton(padding: 4)
                    .foregroundStyle(.secondary)
                    .help("缺词查询说明")
                    .accessibilityLabel("缺词查询说明")
                    .popover(isPresented: $showsHelp) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("如何查询").font(.headline)
                            Text("可以输入完整助记词或从第一个词开始的连续前缀。中间缺词时，每个缺失位置填写一个 ?，总词数需与所选长度一致。")
                            Text("前后导航按词表顺序遍历，右侧缺词优先变化，仅展示校验有效的结果。校验通过不代表一定是原来的钱包。")
                        }
                        .font(.system(size: 13))
                        .padding(20)
                        .frame(width: 320)
                    }
            }
            Toggle("自动识别完整词数", isOn: $model.autoDetectWordCount)
                .toggleStyle(.checkbox)
                .font(.callout)
                .help("识别 12、15、18、21、24 词；查找较长助记词的前缀时请关闭。手动选择长度会关闭自动识别。")
            ZStack(alignment: .topLeading) {
                if model.searchText.isEmpty {
                    Text("输入助记词，用 ? 代替缺失的单词")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.tertiary).padding(10)
                        .allowsHitTesting(false)
                }
                MnemonicTextEditor(text: $model.searchText, inspection: model.inputInspection,
                    inspectionText: model.inputInspectionSource, selectionRequest: model.inputSelectionRequest,
                    onChange: model.updateEditorInput, onSelection: model.updateCompletionSelection,
                    onSearch: { if canSearch { model.generate(.search) } })
                    .frame(height: 92)
                    .disabled(model.isLoading)
            }
            .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(Theme.hairline) }
            Text("输入字母显示词表候选 · ↑↓ 选择 · 回车 / Tab 补全 · Esc 关闭 · ⌘↵ 查找")
                .font(.caption).foregroundStyle(.secondary)
            inputFeedback
            addressMatcher
            HStack(spacing: 8) {
                Text("已输入 \(words.count) / \(expectedWords) 词")
                if missingCount > 0 { Text("· 缺失 \(missingCount) 词") }
                Spacer()
                Button { model.generate(.search) } label: {
                    Label("查找", systemImage: "magnifyingglass").padding(.horizontal, 12)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canSearch)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)

            if missingCount > 0 && words.count != expectedWords {
                Text("使用 ? 时，请填满 \(expectedWords) 个位置。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            } else if model.selectedCoins.isEmpty {
                Text("请至少选择一个币种。")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }

            if let match = model.result?.matchedItem {
                Label("当前结果已匹配 · \(match.coin) · \(match.path)", systemImage: "checkmark.seal.fill")
                    .font(.callout.monospaced()).foregroundStyle(Theme.positive).textSelection(.enabled)
                Text(match.address).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            HStack(spacing: 8) {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                    Text(model.isMatchingAddress ? "已检查 \(model.matchedCandidates) 个有效候选…" : model.searchedCandidates > 0 ? "已检查 \(model.searchedCandidates) 个组合…" : "正在本机查找并派生…")
                    Spacer()
                    Button("取消") { model.cancelSearch() }
                } else if let pattern = model.activePattern {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(Theme.accent)
                    Text("缺词查询中 · \(pattern.split(whereSeparator: \.isWhitespace).filter { $0 == "?" }.count) 个缺词")
                    Spacer()
                    Button("退出查询") { model.exitPatternSearch() }
                } else {
                    Image(systemName: "lock.shield")
                    Text("本机计算 · 支持完整、前缀与缺词查询")
                    Spacer()
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(minHeight: 24)
        }
        .panel()
    }
}

struct ElectrumView: View {
    @StateObject private var model = ElectrumViewModel()

    var body: some View {
        FeaturePage(
            title: "Electrum 助记词",
            subtitle: "浏览 Standard 与 SegWit 接收地址",
            symbol: "bolt.horizontal.circle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeading(title: "浏览参数", subtitle: "选择 Electrum 类型和需要生成的接收地址数量")

                ParameterFlowLayout() {
                    ParameterPicker(title: "地址类型", selection: $model.addressType) {
                        Text("All").tag("all")
                        Text("Standard").tag("standard")
                        Text("SegWit").tag("segwit")
                    }
                    ParameterPicker(title: "接收地址", selection: $model.count) {
                        ForEach([1, 2, 5], id: \.self) { Text("\($0)").tag($0) }
                    }
                }

                Text("选项修改后自动更新当前结果").font(.caption).foregroundStyle(.secondary)
                MnemonicSearchInput(
                    searchText: $model.searchText,
                    placeholder: "输入完整 Electrum 助记词",
                    action: model.generate
                )
            }
            .disabled(model.isLoading)
            .panel()

            MnemonicResultNavigation(action: model.generate, includesPrevious: false)
                .disabled(model.isLoading)
                .panel()

            ResultState(
                isLoading: model.isLoading,
                error: model.errorMessage,
                result: model.result,
                copiedValue: model.copiedValue,
                balances: model.balances,
                balancePending: model.balancePending,
                isBalanceLoading: model.isBalanceLoading,
                balanceError: model.balanceError,
                fetchBalances: { model.fetchBalances() },
                retryBalances: { model.fetchBalances(onlyFailed: true) },
                refreshBalances: { model.fetchBalances(forceRefresh: true) },
                copy: model.copy
            )
        }
        .onAppear { if model.result == nil { model.generate(.first) } }
        .onDisappear { model.clear() }
        .onChange(of: model.addressType) { _ in model.refreshDerivation() }
        .onChange(of: model.count) { _ in model.refreshDerivation() }
    }
}

/// Keep the mode label outside the native segmented control so its width is
/// reserved for the mode choices. Let the description wrap as a whole on narrow windows.
private struct MnemonicBrowseModeBar: View {
    @Binding var selection: MnemonicBrowseMode

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                selector
                Spacer(minLength: 12)
                context.fixedSize()
            }
            VStack(alignment: .leading, spacing: 6) {
                selector
                context
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var selector: some View {
        HStack(spacing: 10) {
            FieldLabel(title: "浏览方式").fixedSize()
            Picker("浏览方式", selection: $selection) {
                ForEach(MnemonicBrowseMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("浏览方式")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var context: some View {
        Text(selection.description)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FeaturePage<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: title, subtitle: subtitle) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { content }
                    .pageContent()
            }
        }
    }
}

private struct MnemonicSearchInput: View {
    @Binding var searchText: String
    let placeholder: String
    let action: (CoreNavigation) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(title: "助记词定位")
            HStack(spacing: 10) {
                TextField(placeholder, text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .onSubmit { action(.search) }
                Button { action(.search) } label: {
                    Label("查找", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

        }
    }
}

private struct ResultState: View {
    let isLoading: Bool
    let error: String?
    let result: MnemonicResult?
    let copiedValue: String?
    let balances: [String: BalanceRecord]
    var balancePending: Set<String> = []
    @State private var balanceFilter: BalanceResultFilter = .all
    let isBalanceLoading: Bool
    let balanceError: String?
    let fetchBalances: () -> Void
    let retryBalances: () -> Void
    let refreshBalances: () -> Void
    let copy: (String) -> Void
    var activePattern: String? = nil
    var navigation: ((CoreNavigation) -> Void)? = nil
    var derivationSummary: String? = nil
    var addressPagination: MnemonicAddressPagination? = nil

    var body: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(result == nil ? "正在本机派生…" : "正在更新，以下为上次结果…")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        if !isLoading, let error {
            Label(error, systemImage: error.hasPrefix("已经是") ? "info.circle" : "exclamationmark.triangle.fill")
                .foregroundStyle(error.hasPrefix("已经是") ? Color.secondary : Color.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((error.hasPrefix("已经是") ? Color.secondary : Color.red).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        if let result {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SectionHeading(title: "助记词")
                        if navigation != nil {
                            Label("校验通过", systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.positive)
                        }
                        Spacer()
                        Button { copy(result.mnemonic) } label: {
                            Label(copiedValue == result.mnemonic ? "已复制" : "复制全部", systemImage: copiedValue == result.mnemonic ? "checkmark" : "doc.on.doc")
                        }
                        .controlSize(.small)
                    }
                    if let derivationSummary {
                        Text(derivationSummary).font(.caption).foregroundStyle(.secondary)
                    }
                    if let navigation {
                        Text("助记词导航 · 切换整组助记词")
                            .font(.caption).foregroundStyle(.secondary)
                        MnemonicResultNavigation(action: navigation)
                            .disabled(isLoading)
                    }
                    Divider()
                    MnemonicWordGrid(mnemonic: result.mnemonic, pattern: activePattern)
                    if activePattern != nil {
                        Label("高亮单词为补全位置", systemImage: "circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                    }
                    DisclosureGroup(navigation != nil ? "查看熵索引" : "查看索引") {
                        Text(result.index)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                .panel()

                ResponsiveToolbar {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("派生地址")
                            .font(.title3.weight(.semibold))
                        Text("共 \(result.items.count) 条公开地址")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } actions: {
                    if balances.values.contains(where: { $0.status == .unavailable }) {
                        Button("重试失败项", action: retryBalances).disabled(isBalanceLoading || isLoading)
                    }
                    if !balances.isEmpty {
                        Button("强制刷新", action: refreshBalances).disabled(isBalanceLoading || isLoading)
                    }
                    Button(action: fetchBalances) {
                        if isBalanceLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("查询公开地址余额", systemImage: "network")
                        }
                    }
                    .disabled(isBalanceLoading || isLoading)
                }

                if let addressPagination { addressPagination }
                BalanceResultControls(items: result.items, balances: balances, pending: balancePending,
                                      isLoading: isBalanceLoading, filter: $balanceFilter)
                LazyVStack(spacing: 6) {
                    ForEach(result.items.filter { balanceFilter.includes(balancePending.contains($0.id) ? nil : balances[$0.id]) }) { item in
                        AddressResultRow(
                            item: item,
                            copiedValue: copiedValue,
                            balance: balances[item.id],
                            balancePending: balancePending.contains(item.id),
                            onCopy: copy
                        )
                    }
                }
                if let balanceError {
                    Label(balanceError, systemImage: "network.slash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

private struct MnemonicWordGrid: View {
    let mnemonic: String
    let pattern: String?

    private var words: [Substring] { mnemonic.split(separator: " ") }
    private var missing: Set<Int> {
        Set((pattern ?? "").split(whereSeparator: \.isWhitespace).enumerated().compactMap { $0.element == "?" ? $0.offset : nil })
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid(columns: 6).frame(minWidth: 790)
            grid(columns: 4).frame(minWidth: 520)
            grid(columns: 3)
        }
    }

    private func grid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(words.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", index + 1))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(String(words[index]))
                        .font(.system(size: 16, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .foregroundStyle(missing.contains(index) ? Theme.accent : Color.primary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(missing.contains(index) ? Theme.accent.opacity(0.09) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct MnemonicResultNavigation: View {
    let action: (CoreNavigation) -> Void
    var includesPrevious = true

    var body: some View {
        ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            KeyspaceNavigationButton(symbol: "backward.end.fill", title: "第一个") { action(.first) }
            if includesPrevious {
                KeyspaceNavigationButton(symbol: "chevron.left", title: "上一组") { action(.previous) }
            }
            KeyspaceNavigationButton(symbol: "shuffle", title: "随机") { action(.random) }
            KeyspaceNavigationButton(symbol: "chevron.right", title: "下一组") { action(.next) }
            KeyspaceNavigationButton(symbol: "forward.end.fill", title: "最后一个") { action(.last) }
        }
    }
}

private struct MnemonicAddressPagination: View {
    let start: Int
    let count: Int
    let isLoading: Bool
    let previous: () -> Void
    let next: () -> Void
    var solAccountStart: Int? = nil

    var body: some View {
        ResponsiveToolbar {
            VStack(alignment: .leading, spacing: 3) {
                Text("同一助记词的地址分页").font(.callout.weight(.medium))
                Text(solAccountStart.map { "地址索引 \(start)–\(start + count - 1) · SOL 账户 \($0 + start)–\($0 + start + count - 1)" }
                     ?? "地址索引 \(start)–\(start + count - 1)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } actions: {
            KeyspaceNavigationButton(symbol: "chevron.left", title: "上一页地址", action: previous)
                .disabled(isLoading || start == 0)
            KeyspaceNavigationButton(symbol: "chevron.right", title: "下一页地址", action: next)
                .disabled(isLoading || start + count + (solAccountStart ?? 0) >= (1 << 31))
        }
        .padding(12)
        .background(Theme.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor
final class MnemonicDirectoryViewModel: ObservableObject {
    @Published var bitSize = 128
    @Published var pageSize = 10
    @Published var selectedCoins: Set<Coin> = [.BTC, .ETH]
    @Published var btcType: BTCMnemonicAddressType = .all
    @Published var jumpText = "0"
    @Published private(set) var result: MnemonicPageResult?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var balances: [String: BalanceRecord] = [:]
    @Published private(set) var balancePending: Set<String> = []
    @Published private(set) var isBalanceLoading = false
    @Published private(set) var balanceError: String?
    private var generation: Task<Void, Never>?
    private var balanceTask: Task<Void, Never>?
    private var queryID = UUID()
    private let balanceClient: BalanceClient
    private let autoRefresh: () -> Bool

    init(balanceClient: BalanceClient = .shared, autoRefresh: @escaping () -> Bool = { BalanceSettings.autoRefreshEnabled }) {
        self.balanceClient = balanceClient; self.autoRefresh = autoRefresh
    }

    func generate(_ operation: CoreNavigation) {
        generation?.cancel(); cancelBalances()
        isLoading = false
        guard !selectedCoins.isEmpty else { errorMessage = "请至少选择一个币种"; return }
        let bits = bitSize, size = pageSize, coins = selectedCoins, type = btcType
        let input = operation == .first ? "0" : operation == .jump ? jumpText : result?.start ?? "0"
        errorMessage = nil; isLoading = true
        generation = Task {
            do {
                let page = try await AllKeyCoreClient.shared.createMnemonicPage(bitSize: bits, pageSize: size, coins: coins, index: input, operation: operation, btcType: type)
                try Task.checkCancellation()
                result = page; jumpText = page.start
                balances = [:]; balanceError = nil
                if autoRefresh() { fetchBalances(forceRefresh: true) }
            } catch is CancellationError { return }
            catch let error as CoreAPIError {
                guard !Task.isCancelled else { return }; errorMessage = error.message
            } catch {
                guard !Task.isCancelled else { return }; errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func fetchBalances(forceRefresh: Bool = false, onlyFailed: Bool = false) {
        guard let all = result?.addresses else { return }
        let items = onlyFailed ? all.filter { balances[$0.id]?.status == .unavailable } : all
        guard !items.isEmpty else { return }
        cancelBalances()
        let id = UUID(); queryID = id
        balancePending = Set(items.map(\.id)); isBalanceLoading = true; balanceError = nil
        balanceTask = Task { [self] in
            do {
                let values = try await balanceClient.fetch(items: items, forceRefresh: forceRefresh || onlyFailed) { [weak self] values in
                    Task { @MainActor in
                        guard let self, self.queryID == id else { return }
                        self.balances.merge(values) { _, new in new }
                        self.balancePending.subtract(values.keys)
                    }
                }
                try Task.checkCancellation()
                balances.merge(values) { _, new in new }
            } catch {
                guard !Task.isCancelled else { return }; balanceError = error.localizedDescription
            }
            balancePending = []; isBalanceLoading = false
        }
    }

    private func cancelBalances() {
        queryID = UUID(); balanceTask?.cancel(); balancePending = []; isBalanceLoading = false
    }

    func cancel() { generation?.cancel(); isLoading = false; cancelBalances() }
    func clear() { cancel(); result = nil; balances = [:]; jumpText = "0"; errorMessage = nil; balanceError = nil }
}

private struct MnemonicDirectoryView: View {
    @ObservedObject var model: MnemonicDirectoryViewModel
    let copiedValue: String?
    let copy: (String) -> Void
    let open: (MnemonicResult) -> Void
    @State private var filter: BalanceResultFilter = .all

    private var visible: [MnemonicResult] {
        model.result?.items.filter { entry in
            filter == .all || entry.items.contains { filter.includes(model.balancePending.contains($0.id) ? nil : model.balances[$0.id]) }
        } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                ParameterFlowLayout() {
                    ParameterPicker(title: "助记词长度", width: 110, selection: $model.bitSize) {
                        ForEach([128,160,192,224,256], id: \.self) { Text("\($0 / 32 * 3) 词").tag($0) }
                    }
                    ParameterPicker(title: "每页助记词组数", width: 140, selection: $model.pageSize) {
                        Text("10 组").tag(10); Text("20 组").tag(20)
                    }
                    if model.selectedCoins.contains(.BTC) {
                        ParameterPicker(title: "BTC 地址类型", width: 210, selection: $model.btcType) {
                            ForEach(BTCMnemonicAddressType.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                FieldLabel(title: "币种 · 已选 \(model.selectedCoins.count)")
                ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(Coin.allCases) { coin in coinToggle(coin) }
                }
                if model.selectedCoins.isEmpty { CoinSelectionWarning() }
                Text("选项修改后自动更新 · 账户 0 · 标准收款路径")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("目录使用空 Passphrase，每组显示所选币种及地址类型的第一个地址。进入单组视图可调整派生参数。ETH 同时附加已启用的 EVM 网络。")
            }.disabled(model.isLoading).panel()

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(title: "起始熵索引（十进制）")
                HStack(spacing: 8) {
                    TextField("起始熵索引（十进制）", text: $model.jumpText)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        .onSubmit { model.generate(.jump) }
                    Button("跳转") { model.generate(.jump) }
                    Button("刷新目录") { model.generate(.current) }
                }
                ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                    KeyspaceNavigationButton(symbol: "backward.end.fill", title: "首页") { model.generate(.first) }
                    KeyspaceNavigationButton(symbol: "chevron.left", title: "上一页") { model.generate(.previous) }.disabled(model.result?.hasPrevious == false)
                    KeyspaceNavigationButton(symbol: "shuffle", title: "随机") { model.generate(.random) }
                    KeyspaceNavigationButton(symbol: "chevron.right", title: "下一页") { model.generate(.next) }.disabled(model.result?.hasNext == false)
                    KeyspaceNavigationButton(symbol: "forward.end.fill", title: "末页") { model.generate(.last) }
                }
            }.disabled(model.isLoading || model.selectedCoins.isEmpty).panel()

            if model.isLoading {
                HStack { ProgressView().controlSize(.small); Text("正在本机生成目录…"); Spacer(); Button("取消") { model.cancel() } }
            }
            if let error = model.errorMessage, !model.selectedCoins.isEmpty {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let page = model.result {
                ResponsiveToolbar {
                    Text("熵索引 \(page.start)–\(page.end) · \(page.items.count) 组")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                } actions: {
                    if model.balances.values.contains(where: { $0.status == .unavailable }) {
                        Button("重试失败项") { model.fetchBalances(onlyFailed: true) }.disabled(model.isBalanceLoading || model.isLoading)
                    }
                    Button(model.balances.isEmpty ? "查询本页余额" : "强制刷新") { model.fetchBalances(forceRefresh: !model.balances.isEmpty) }
                        .disabled(model.isBalanceLoading || model.isLoading)
                }
                Text("匹配助记词 \(visible.count) / \(page.items.count) 组")
                    .font(.caption).foregroundStyle(.secondary)
                BalanceResultControls(items: page.addresses, balances: model.balances, pending: model.balancePending, isLoading: model.isBalanceLoading, filter: $filter)
                LazyVStack(spacing: 6) {
                    ForEach(visible, id: \.index) { entry in
                        MnemonicDirectoryCard(entry: entry, balances: model.balances, pending: model.balancePending, filter: filter,
                                              copiedValue: copiedValue, copy: copy, open: { open(entry) })
                    }
                }
                if let error = model.balanceError { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .onAppear { if model.result == nil { model.generate(.first) } }
        .onChange(of: model.bitSize) { _ in model.generate(.first) }
        .onChange(of: model.pageSize) { _ in model.generate(.first) }
        .onChange(of: model.btcType) { _ in model.generate(.current) }
        .onChange(of: model.selectedCoins) { _ in model.generate(.current) }
    }

    private func coinToggle(_ coin: Coin) -> some View {
        CoinToggle(coin: coin, isSelected: model.selectedCoins.contains(coin)) {
            if model.selectedCoins.contains(coin) { model.selectedCoins.remove(coin) }
            else { model.selectedCoins.insert(coin) }
        }
    }
}

private struct MnemonicDirectoryCard: View {
    let entry: MnemonicResult
    let balances: [String: BalanceRecord]
    let pending: Set<String>
    let filter: BalanceResultFilter
    let copiedValue: String?
    let copy: (String) -> Void
    let open: () -> Void
    @State private var expanded = false

    private var items: [AddressItem] { entry.items.filter { filter.includes(pending.contains($0.id) ? nil : balances[$0.id]) } }
    private var funded: Bool { entry.items.contains { balances[$0.id]?.hasNonZeroData == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("熵索引 \(entry.index)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Button(copiedValue == entry.mnemonic ? "已复制" : "复制助记词") { copy(entry.mnemonic) }.controlSize(.small)
                Button("单组详情", action: open).controlSize(.small)
            }
            Text(entry.mnemonic).font(.system(size: 14, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("派生地址 · \(items.count) 条", isExpanded: $expanded) {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        AddressResultRow(item: item, copiedValue: copiedValue, balance: balances[item.id], balancePending: pending.contains(item.id), onCopy: copy)
                    }
                }.padding(.top, 6)
            }.font(.caption)
        }
        .padding(10).background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(funded ? Theme.positive.opacity(0.6) : Theme.hairline, lineWidth: 1) }
    }
}
