import AppKit
import Foundation

@MainActor
final class PrivateKeysViewModel: ObservableObject {
    @Published var index = "1"
    @Published var count = 1
    @Published var btcAddressType: BTCPrivateKeyAddressType = .all
    @Published var selectedCoins: Set<Coin> = [.BTC, .ETH]
    @Published private(set) var result: KeyResult?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var copiedValue: String?
    @Published private(set) var activePuzzle: BTCPuzzle?
    @Published private(set) var balances: [String: BalanceRecord] = [:]
    @Published private(set) var isBalanceLoading = false
    @Published var balanceError: String?

    private let balanceClient: BalanceClient
    private let autoRefreshEnabled: () -> Bool

    init(balanceClient: BalanceClient = .shared, autoRefreshEnabled: @escaping () -> Bool = { BalanceSettings.autoRefreshEnabled }) {
        self.balanceClient = balanceClient
        self.autoRefreshEnabled = autoRefreshEnabled
    }

    @Published private(set) var balancePending: Set<String> = []
    private var balanceRequestID = UUID()
    private var balanceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var clipboardClearTask: Task<Void, Never>?

    func generate(_ operation: CoreNavigation = .current) {
        generationTask?.cancel()
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isBalanceLoading = false
        isLoading = false
        guard !selectedCoins.isEmpty else { errorMessage = "请至少选择一个币种"; return }
        let requestedPuzzle = activePuzzle
        let requestedIndex = index
        let requestedCoins = selectedCoins
        let requestedCount = count
        let requestedBTCType: BTCPrivateKeyAddressType = requestedPuzzle == nil ? btcAddressType : .legacy

        isLoading = true
        errorMessage = nil
        generationTask = Task {
            do {
                let generated = try await AllKeyCoreClient.shared.createKeys(
                    index: requestedIndex,
                    coins: requestedCoins,
                    count: requestedCount,
                    operation: operation,
                    puzzleNumber: requestedPuzzle?.id,
                    btcType: requestedBTCType
                )
                guard !Task.isCancelled else { return }
                result = generated
                index = generated.index
                balances = [:]
                balanceError = nil
                if autoRefreshEnabled() {
                    fetchBalances(forceRefresh: true)
                }
            } catch is CancellationError {
                return
            } catch let error as CoreAPIError {
                guard !Task.isCancelled else { return }
                errorMessage = error.message
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }

    func enterPuzzle(_ puzzle: BTCPuzzle, operation: CoreNavigation = .first) {
        generationTask?.cancel()
        balanceTask?.cancel()
        activePuzzle = puzzle
        selectedCoins = [.BTC]
        count = 1
        index = puzzle.lowerBound
        result = nil
        generate(operation)
    }

    func exitPuzzle() {
        generationTask?.cancel()
        activePuzzle = nil
        isLoading = false
        errorMessage = nil
    }

    var matchesPuzzleTarget: Bool {
        guard let target = activePuzzle?.address else { return false }
        return result?.items.contains(where: { $0.coin == "BTC" && $0.address == target }) ?? false
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
                let records = try await balanceClient.fetch(items: requestedItems, forceRefresh: forceRefresh || onlyFailed) { [weak self] values in
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

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value

        clipboardClearTask?.cancel()
        clipboardClearTask = Task {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            if NSPasteboard.general.string(forType: .string) == value {
                NSPasteboard.general.clearContents()
            }
            if copiedValue == value {
                copiedValue = nil
            }
        }
    }

    func clearSensitiveData() {
        generationTask?.cancel()
        balanceTask?.cancel()
        balanceRequestID = UUID()
        balancePending = []
        isLoading = false
        isBalanceLoading = false
        result = nil
        index = activePuzzle?.lowerBound ?? "1"
        copiedValue = nil
        errorMessage = nil
        balances = [:]
        balanceError = nil
    }
}
