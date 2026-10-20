import Foundation
import Combine

struct BTCPuzzle: Codable, Identifiable, Hashable {
    let id: Int
    let solved: Bool
    let address: String

    var lowerBound: String {
        let exponent = id - 1
        return String(1 << (exponent % 4), radix: 16) + String(repeating: "0", count: exponent / 4)
    }

    var upperBound: String {
        let remainder = id % 4
        return (remainder == 0 ? "" : String((1 << remainder) - 1, radix: 16))
            + String(repeating: "f", count: id / 4)
    }

    var publicAddressItem: AddressItem {
        AddressItem(coin: "BTC", path: "", hexKey: "", keyTag: "", address: address,
                    addressTag: "Puzzle #\(id)", balance: "", transactionCount: "", received: "")
    }
}

struct BTCPuzzleCatalog: Codable {
    let sourceURL: String
    let capturedAt: String
    let sourceSHA256: String
    let puzzles: [BTCPuzzle]

    var snapshotDate: String { String(capturedAt.prefix(10)) }

    func validated() throws -> BTCPuzzleCatalog {
        guard puzzles.map(\.id) == Array(1...160),
              Set(puzzles.map(\.address)).count == 160,
              puzzles.allSatisfy({ $0.address.range(of: "^1[1-9A-HJ-NP-Za-km-z]{25,34}$", options: .regularExpression) != nil }),
              ISO8601DateFormatter().date(from: capturedAt) != nil,
              sourceSHA256.count == 64 else {
            throw CatalogError.invalid
        }
        return self
    }

    static func load(bundle: Bundle = .main) throws -> BTCPuzzleCatalog {
        guard let url = bundle.url(forResource: "btc-puzzles", withExtension: "json") else {
            throw CatalogError.missing
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)).validated()
    }

    enum CatalogError: LocalizedError {
        case missing, invalid
        var errorDescription: String? {
            switch self {
            case .missing: "未找到 BTC Puzzle 数据文件"
            case .invalid: "BTC Puzzle 数据格式无效"
            }
        }
    }
}

@MainActor
final class BTCPuzzleViewModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, unsolved, solved
        var id: Self { self }
        var title: String {
            switch self {
            case .all: "全部"
            case .unsolved: "未解"
            case .solved: "已解"
            }
        }
    }

    @Published private(set) var catalog: BTCPuzzleCatalog?
    @Published var filter: Filter = .unsolved
    @Published var searchText = ""
    @Published var selectedID: Int?
    @Published private(set) var errorMessage: String?
    @Published private(set) var balances: [Int: BalanceRecord] = [:]
    @Published private(set) var balanceDates: [Int: Date] = [:]
    @Published private(set) var balanceErrors: [Int: String] = [:]
    @Published private(set) var fetchingIDs: Set<Int> = []
    private var balanceTasks: [Task<Void, Never>] = []
    private var balanceGeneration = UUID()
    private let balanceClient: BalanceClient

    init(catalog: BTCPuzzleCatalog? = nil, balanceClient: BalanceClient = .shared) {
        self.balanceClient = balanceClient
        do {
            let loaded = try catalog?.validated() ?? BTCPuzzleCatalog.load()
            self.catalog = loaded
            selectedID = loaded.puzzles.first(where: { !$0.solved })?.id ?? loaded.puzzles.first?.id
        } catch { errorMessage = error.localizedDescription }
    }

    var filteredPuzzles: [BTCPuzzle] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = Int(query.hasPrefix("#") ? String(query.dropFirst()) : query)
        return (catalog?.puzzles ?? []).filter { puzzle in
            let matchesStatus = filter == .all || (filter == .solved ? puzzle.solved : !puzzle.solved)
            let matchesQuery = query.isEmpty || (number.map { $0 == puzzle.id } ?? puzzle.address.localizedCaseInsensitiveContains(query))
            return matchesStatus && matchesQuery
        }
    }

    var selectedPuzzle: BTCPuzzle? {
        filteredPuzzles.first { $0.id == selectedID }
    }

    func reconcileSelection() {
        if !filteredPuzzles.contains(where: { $0.id == selectedID }) {
            selectedID = filteredPuzzles.first?.id
        }
    }

    func refreshBalance() {
        guard let puzzle = selectedPuzzle, !fetchingIDs.contains(puzzle.id) else { return }
        refreshBalances([puzzle], forceRefresh: true)
    }

    func pageDidAppear() {
        cancel()
        refreshBalances(catalog?.puzzles ?? [], forceRefresh: false)
    }

    private func refreshBalances(_ puzzles: [BTCPuzzle], forceRefresh: Bool) {
        let generation = balanceGeneration
        fetchingIDs.formUnion(puzzles.map(\.id))
        for puzzle in puzzles { balanceErrors[puzzle.id] = nil }
        let items = puzzles.map(\.publicAddressItem)
        balanceTasks.append(Task {
            do {
                let records = try await balanceClient.fetch(items: items, forceRefresh: forceRefresh) { [weak self] values in
                    Task { @MainActor in
                        guard let self, self.balanceGeneration == generation else { return }
                        self.apply(values, puzzles: puzzles)
                    }
                }
                guard !Task.isCancelled, balanceGeneration == generation else { return }
                apply(records, puzzles: puzzles)
            } catch {
                guard !Task.isCancelled, balanceGeneration == generation else { return }
                for puzzle in puzzles where fetchingIDs.contains(puzzle.id) { balanceErrors[puzzle.id] = error.localizedDescription }
            }
            fetchingIDs.subtract(puzzles.map(\.id))
        })
    }

    private func apply(_ records: [String: BalanceRecord], puzzles: [BTCPuzzle]) {
        for puzzle in puzzles {
            guard let record = records[puzzle.publicAddressItem.id] else { continue }
            balances[puzzle.id] = record
            balanceDates[puzzle.id] = record.queriedAt
            fetchingIDs.remove(puzzle.id)
        }
    }

    func cancel() {
        balanceGeneration = UUID()
        for task in balanceTasks { task.cancel() }
        balanceTasks = []
        fetchingIDs = []
    }
}
