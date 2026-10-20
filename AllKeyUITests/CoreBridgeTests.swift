import XCTest
import AppKit
import SwiftUI
@testable import AllKeyUI

final class CoreBridgeTests: XCTestCase {
    func testPrivateKeyOneProducesKnownEthereumAddress() async throws {
        let result = try await AllKeyCoreClient.shared.createKeys(
            index: "1",
            coins: [.ETH],
            count: 1
        )

        XCTAssertEqual(result.index, "1")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.address, "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    }

    func testWIFInputNormalizesAndPreservesNavigationAndFilter() async throws {
        // Public scalar-one WIF, compressed mainnet.
        let wif = "KwDiBf89QgGbjEhKnhXJuH7LrciVrZi3qYjgd9M7rFU73sVHnoWn"
        let result = try await AllKeyCoreClient.shared.createKeys(index: wif, coins: [.BTC, .ETH], count: 1, btcType: .legacy)
        XCTAssertEqual(result.index, "1")
        XCTAssertEqual(result.wifCompressed, true)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.items.first?.address, "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
        let next = try await AllKeyCoreClient.shared.createKeys(index: result.index, coins: [.BTC], count: 1, operation: .next, btcType: .legacyUncompressed)
        XCTAssertEqual(next.index, "2")
        XCTAssertEqual(next.items.count, 1)
        XCTAssertEqual(next.items.first?.addressTag, "Legacy(u)")
    }

    func testPrivateKeyLabelsFollowCoreEncoding() async throws {
        let mnemonic = try await AllKeyCoreClient.shared.createMnemonic(bitSize: 128, count: 1, coins: [.BTC, .LTC, .DOGE, .SOL, .ETH], index: "0", operation: .current)
        for item in mnemonic.items {
            XCTAssertEqual(item.privateKeyLabel, item.coin == "SOL" ? "Base58 私钥" : item.coin == "ETH" ? "十六进制私钥" : "WIF 私钥")
        }
        let electrum = try await AllKeyCoreClient.shared.createElectrum(count: 1, addressType: "all", index: "0", operation: .current)
        XCTAssertTrue(electrum.items.allSatisfy { $0.privateKeyLabel == "WIF 私钥" })
        let direct = try await AllKeyCoreClient.shared.createKeys(index: "1", coins: [.BTC, .SOL], count: 1)
        XCTAssertEqual(direct.items.first?.alternateKeyLabel, "WIF 私钥")
        XCTAssertEqual(direct.items.last?.privateKeyLabel, "十六进制种子")
        XCTAssertEqual(direct.items.last?.alternateKeyLabel, "Base58 私钥")
    }

    @MainActor
    func testPrivateKeyNavigationAutoRefreshUsesOnlyCurrentFilteredAddresses() async throws {
        let session = BalanceStub.configure { request in
            let addresses = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "active" })?.value?.components(separatedBy: "|") ?? []
            let body = Dictionary(uniqueKeysWithValues: addresses.map { ($0, ["final_balance": 1, "n_tx": 1, "total_received": 1]) })
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self), [:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://auto.test/balance"), apiKey: "")]
        })
        var enabled = false
        let model = PrivateKeysViewModel(balanceClient: client, autoRefreshEnabled: { enabled })
        model.selectedCoins = [.BTC]
        model.btcAddressType = .segwit
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while (model.isLoading || model.isBalanceLoading) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isLoading || model.isBalanceLoading)
            XCTAssertNil(model.errorMessage)
            XCTAssertNil(model.balanceError)
        }
        model.generate()
        try await finish()
        XCTAssertTrue(BalanceStub.captured().isEmpty)
        enabled = true
        model.generate(.next)
        try await finish()
        XCTAssertEqual(model.index, "2")
        XCTAssertEqual(model.result?.items.count, 1)
        XCTAssertEqual(model.balances.count, 1)
        let previousID = try XCTUnwrap(model.result?.items.first?.id)
        XCTAssertEqual(model.balances[previousID]?.status, .loaded)
        model.generate(.previous)
        try await finish()
        XCTAssertNil(model.balances[previousID])
        XCTAssertEqual(model.balances.count, 1)
        XCTAssertEqual(BalanceStub.captured().count, 2)
        model.generate(.next)
        try await finish()
        XCTAssertEqual(BalanceStub.captured().count, 3, "Auto refresh must bypass cache")
        let puzzle = try XCTUnwrap(BTCPuzzleCatalog.load().puzzles.first)
        model.enterPuzzle(puzzle)
        try await finish()
        XCTAssertEqual(model.result?.items.count, 1)
        XCTAssertEqual(model.result?.items.first?.addressTag, "Legacy(c)")
        XCTAssertEqual(model.balances.count, 1)
        let request = try XCTUnwrap(BalanceStub.captured().last)
        let queried = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "active" })?.value
        XCTAssertEqual(queried, puzzle.address, "Puzzle balance queries must contain only the compressed Legacy address")
        model.clearSensitiveData()
    }

    func testMnemonicDirectoryBridgeNavigationAndBounds() async throws {
        let first = try await AllKeyCoreClient.shared.createMnemonicPage(bitSize: 128, pageSize: 10, coins: [.ETH], index: "0", operation: .first)
        XCTAssertEqual(first.items.count, 10)
        XCTAssertEqual(first.start, "0")
        XCTAssertEqual(first.end, "9")
        XCTAssertFalse(first.hasPrevious)
        let next = try await AllKeyCoreClient.shared.createMnemonicPage(bitSize: 128, pageSize: 10, coins: [.ETH], index: first.start, operation: .next)
        XCTAssertEqual(next.start, "10")
        XCTAssertEqual(next.items.first?.index, "10")
        let last = try await AllKeyCoreClient.shared.createMnemonicPage(bitSize: 128, pageSize: 20, coins: [.BTC], index: "0", operation: .last, btcType: .segwit)
        XCTAssertEqual(last.end, last.max)
        XCTAssertFalse(last.hasNext)
        XCTAssertTrue(last.items.allSatisfy { $0.items.count == 1 })
    }

    @MainActor
    func testMnemonicDirectoryModelKeepsPageOnInvalidJumpAndClears() async throws {
        let model = MnemonicDirectoryViewModel(autoRefresh: { false })
        model.selectedCoins = [.ETH]
        func finish() async throws {
            let deadline = Date().addingTimeInterval(10)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isLoading)
        }
        model.generate(.first)
        try await finish()
        XCTAssertEqual(model.result?.items.count, 10)
        model.generate(.next)
        try await finish()
        XCTAssertEqual(model.result?.start, "10")
        model.jumpText = "-1"
        model.generate(.jump)
        try await finish()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.result?.start, "10")
        model.bitSize = 256
        model.generate(.last)
        try await finish()
        model.bitSize = 128
        model.generate(.first)
        try await finish()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.result?.start, "0")
        model.clear()
        XCTAssertNil(model.result)
        XCTAssertEqual(model.jumpText, "0")
    }

    func testBIP39ZeroProducesCanonicalMnemonic() async throws {
        let result = try await AllKeyCoreClient.shared.createMnemonic(
            bitSize: 128,
            count: 1,
            coins: [.ETH],
            index: "0",
            operation: .current
        )

        XCTAssertEqual(
            result.mnemonic,
            "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        )
        XCTAssertEqual(result.items.count, 1)
    }

    @MainActor
    private func finishGeneration(_ model: BIP39ViewModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isLoading, "Generation timed out")
    }

    @MainActor
    func testBIP39WildcardNavigationKeepsTemplateAndBoundaries() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        let pattern = "? abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.searchText = pattern
        model.generate(.search)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.index, "0")
        XCTAssertEqual(model.searchText, pattern)
        XCTAssertEqual(model.activePattern, pattern)

        model.generate(.next)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.index, "1")
        XCTAssertEqual(model.result?.mnemonic.split(separator: " ").dropFirst().dropLast(), ArraySlice(Array(repeating: Substring("abandon"), count: 10)))

        model.generate(.previous)
        try await finishGeneration(model)
        XCTAssertEqual(model.index, "0")
        model.generate(.previous)
        try await finishGeneration(model)
        XCTAssertEqual(model.errorMessage, "已经是第一个匹配结果")
        XCTAssertEqual(model.index, "0")
        XCTAssertNotNil(model.result)

        model.exitPatternSearch()
        XCTAssertNil(model.activePattern)
        XCTAssertTrue(model.searchText.isEmpty)
        model.generate(.next)
        try await finishGeneration(model)
        XCTAssertEqual(model.index, "1")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLeavingSearchScopePreservesDraftAndRestoresNormalNavigation() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        let draft = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.searchText = draft
        model.generate(.search)
        try await finishGeneration(model)
        model.generate(.last)
        try await finishGeneration(model)
        XCTAssertEqual(model.index, "127")
        model.exitPatternSearch(clearInput: false)
        XCTAssertEqual(model.searchText, draft)
        XCTAssertNil(model.activePattern)
        model.generate(.next)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.index, "128")
        model.clear()
    }

    @MainActor
    func testBIP39AddressPagesKeepMnemonicAndWildcardTemplate() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.BTC]
        model.btcAddressType = .segwit
        model.count = 2
        model.searchText = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.generate(.search)
        try await finishGeneration(model)
        let phrase = model.result?.mnemonic
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertEqual(model.result?.items.first?.address, "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu")
        model.navigateAddresses(1)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.addressStart, 2)
        XCTAssertEqual(model.result?.mnemonic, phrase)
        XCTAssertNotNil(model.activePattern)
        XCTAssertEqual(model.result?.items.first?.path, "m/84'/0'/0'/0/2")
        model.navigateAddresses(-1)
        try await finishGeneration(model)
        XCTAssertEqual(model.addressStart, 0)
        XCTAssertEqual(model.result?.mnemonic, phrase)
        model.navigateAddresses(1)
        try await finishGeneration(model)
        model.generate(.next)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.addressStart, 0)
        XCTAssertNotEqual(model.result?.mnemonic, phrase)
        model.clear()
    }

    func testMnemonicBridgeSupportsPresetAndFinalAddressIndex() async throws {
        let result = try await AllKeyCoreClient.shared.createMnemonic(bitSize: 128, count: 1, coins: [.BTC], index: "0",
            operation: .current, btcType: .segwit, pathPreset: .change)
        XCTAssertEqual(result.items.first?.path, "m/84'/0'/0'/1/0")
        XCTAssertEqual(result.items.first?.address, "bc1q8c6fshw2dlwun7ekn9qwf37cu2rn755upcp6el")
        let last = try await AllKeyCoreClient.shared.createMnemonic(bitSize: 128, count: 1, coins: [.SOL], index: "0",
            operation: .current, addressStart: 2147483647)
        XCTAssertEqual(last.items.first?.path, "m/44'/501'/2147483647'/0'")
    }

    @MainActor
    func testEntropyAndAddressJumpsPreserveExpectedScope() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.BTC]
        model.btcAddressType = .segwit
        model.count = 2
        model.searchText = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.generate(.search)
        try await finishGeneration(model)
        let phrase = model.result?.mnemonic
        model.addressJumpText = "5"
        model.jumpToAddress()
        try await finishGeneration(model)
        XCTAssertEqual(model.addressStart, 5)
        XCTAssertEqual(model.result?.mnemonic, phrase)
        XCTAssertNotNil(model.activePattern)
        XCTAssertEqual(model.result?.items.first?.path, "m/84'/0'/0'/0/5")
        model.addressJumpText = "2147483647"
        model.jumpToAddress()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.addressStart, 5)
        model.entropyIndexText = "42"
        model.jumpToEntropy()
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.index, "42")
        XCTAssertEqual(model.addressStart, 0)
        XCTAssertNil(model.activePattern)
        XCTAssertTrue(model.searchText.isEmpty)
        model.entropyIndexText = "340282366920938463463374607431768211456"
        model.jumpToEntropy()
        try await finishGeneration(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.index, "42")
        model.clear()
    }

    @MainActor
    func testCustomPathApplyAndPagingUseExactTemplate() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        model.generate(.first)
        try await finishGeneration(model)
        let original = model.result?.items.first?.address
        model.customPathEnabled = true
        model.customPath = "m/44'/60'/0'/0/{index}"
        model.accountText = "invalid but ignored for custom path"
        XCTAssertTrue(model.hasUnappliedDerivation)
        model.generate(.current)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.result?.items.first?.address, original)
        XCTAssertEqual(model.appliedCustomPath, model.customPath)
        XCTAssertFalse(model.hasUnappliedDerivation)
        model.addressJumpText = "7"
        model.jumpToAddress()
        try await finishGeneration(model)
        XCTAssertEqual(model.result?.items.first?.path, "m/44'/60'/0'/0/7")
        model.customPath = "m/not-a-valid-path/{index}"
        model.generate(.current)
        try await finishGeneration(model)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.result?.items.first?.path, "m/44'/60'/0'/0/7")
        model.clear()
    }

    @MainActor
    func testKnownAddressMatcherChecksCandidatesAndHonorsLimit() async throws {
        let target = try await AllKeyCoreClient.shared.createMnemonic(bitSize: 128, count: 1, coins: [.BTC], index: "1", operation: .current, btcType: .segwit)
        let model = BIP39ViewModel()
        model.selectedCoins = [.BTC]
        model.btcAddressType = .segwit
        model.targetCoin = .BTC
        model.targetAddress = try XCTUnwrap(target.items.first?.address)
        model.searchText = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.matchLimitText = "1"
        model.matchKnownAddress()
        try await finishGeneration(model)
        XCTAssertEqual(model.matchedCandidates, 1)
        XCTAssertTrue(model.errorMessage?.contains("未在所选地址范围内匹配") == true)
        XCTAssertNil(model.result)
        model.matchLimitText = "2"
        model.matchKnownAddress()
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.matchedCandidates, 2)
        XCTAssertEqual(model.index, "1")
        XCTAssertEqual(model.result?.matchedItem?.address, model.targetAddress)
        XCTAssertEqual(model.result?.matchedItem?.path, "m/84'/0'/0'/0/0")
        XCTAssertNotNil(model.activePattern)
        model.navigateAddresses(1)
        try await finishGeneration(model)
        XCTAssertEqual(model.index, "1")
        XCTAssertNil(model.result?.matchedItem)
        model.clear()
        XCTAssertTrue(model.targetAddress.isEmpty)
        XCTAssertEqual(model.index, "0")
        XCTAssertEqual(model.entropyIndexText, "0")
    }

    @MainActor
    func testAddressMatchingCanCancelWithoutReplacingResult() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.BTC]
        model.btcAddressType = .segwit
        model.generate(.first)
        try await finishGeneration(model)
        let original = model.result?.mnemonic
        model.targetAddress = "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"
        model.searchText = "? abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.matchKnownAddress()
        let deadline = Date().addingTimeInterval(5)
        while model.matchedCandidates == 0 && model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(model.matchedCandidates, 0)
        model.cancelSearch()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isMatchingAddress)
        XCTAssertEqual(model.result?.mnemonic, original)
        XCTAssertNil(model.result?.matchedItem)
        model.clear()
    }

    @MainActor
    private func finishInspection(_ model: BIP39ViewModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while model.inputInspection == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(model.inputInspection)
    }

    @MainActor
    func testMnemonicInputCompletionAndAutomaticWordCount() async throws {
        let phrase = try await AllKeyCoreClient.shared.createMnemonic(bitSize: 160, count: 1, coins: [.ETH], index: "0", operation: .current)
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        model.searchText = phrase.mnemonic.uppercased()
        XCTAssertEqual(model.bitSize, 160)
        try await finishInspection(model)
        XCTAssertEqual(model.inputInspection?.checksum, "valid")
        model.setWordCount(256)
        try await finishGeneration(model)
        model.searchText = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        try await finishInspection(model)
        XCTAssertFalse(model.autoDetectWordCount)
        XCTAssertEqual(model.bitSize, 256)
        XCTAssertEqual(model.inputInspection?.checksum, "pending")
        model.searchText = "abndon about"
        model.selectCompletionPosition(0)
        try await finishInspection(model)
        XCTAssertEqual(model.inputInspection?.invalidWords.first?.position, 0)
        XCTAssertTrue(model.inputInspection?.suggestions.contains("abandon") == true)
        model.completeWord("abandon")
        try await finishInspection(model)
        XCTAssertEqual(model.searchText, "abandon about")
        XCTAssertEqual(model.inputInspection?.invalidWords.count, 0)
        model.clear()
    }

    func testCompletionTokenRangesAndReplacementPreserveOtherWords() throws {
        let text = "  abandon\tABND\n? about  "
        let wordRange = (text as NSString).range(of: "ABND")
        let target = try XCTUnwrap(MnemonicCompletionTarget.atSelection(NSRange(location: wordRange.location + 2, length: 0), in: text))
        XCTAssertEqual(target.position, 1)
        let edit = try XCTUnwrap(MnemonicCompletionEdit.make(text: text, position: target.position, word: "abandon"))
        XCTAssertEqual(edit.text, "  abandon\tabandon\n? about  ")
        XCTAssertEqual(edit.selection.location, (edit.text as NSString).range(of: "?").location)
        XCTAssertNil(MnemonicCompletionTarget.atSelection(NSRange(location: 0, length: 0), in: text))
        XCTAssertNil(MnemonicCompletionTarget.atSelection(NSRange(location: (text as NSString).length, length: 0), in: text))
        XCTAssertNil(MnemonicCompletionTarget.atSelection(NSRange(location: (text as NSString).range(of: "?").location, length: 0), in: text))
        XCTAssertNil(MnemonicCompletionTarget.atSelection(NSRange(location: 2, length: 15), in: text))
        XCTAssertNil(MnemonicCompletionEdit.make(text: text, position: 2, word: "abandon"))
        XCTAssertEqual(MnemonicCompletionEdit.make(text: "ab", position: 0, word: "abandon")?.text, "abandon ")
        let unicode = "😀\nab"
        XCTAssertEqual(MnemonicCompletionTarget.atSelection(NSRange(location: (unicode as NSString).length, length: 0), in: unicode)?.position, 1)
        XCTAssertEqual(MnemonicCompletionEdit.make(text: unicode, position: 1, word: "abandon")?.text, "😀\nabandon ")
    }

    @MainActor
    func testCaretCompletionTargetsMiddleWordAndIgnoresOutdatedInspection() async throws {
        let model = BIP39ViewModel()
        model.searchText = "abnd about ?"
        model.updateCompletionSelection(NSRange(location: 2, length: 0))
        try await finishInspection(model)
        XCTAssertEqual(model.inputInspection?.completionPosition, 0)
        XCTAssertEqual(model.inputInspectionSource, model.searchText)
        XCTAssertTrue(model.inputInspection?.suggestions.contains("abandon") == true)
        model.completeWord("abandon")
        try await finishInspection(model)
        XCTAssertEqual(model.searchText, "abandon about ?")
        XCTAssertTrue(model.inputInspection?.suggestions.isEmpty == true)
        XCTAssertEqual(model.inputSelectionRequest?.range.location, 8)
        model.updateEditorInput("ab a", selection: NSRange(location: 2, length: 0))
        model.updateEditorInput("act a", selection: NSRange(location: 3, length: 0))
        model.updateCompletionSelection(NSRange(location: 5, length: 0))
        try await finishInspection(model)
        XCTAssertEqual(model.inputInspectionSource, "act a")
        XCTAssertEqual(model.inputInspection?.completionPosition, 1)
        XCTAssertTrue(model.inputInspection?.suggestions.allSatisfy { $0.hasPrefix("a") } == true)
        model.updateCompletionSelection(NSRange(location: 4, length: 1))
        model.completeWord("not-in-candidates")
        XCTAssertEqual(model.searchText, "act a")
        model.clear()
        XCTAssertNil(model.inputInspectionSource)
        XCTAssertNil(model.inputSelectionRequest)
    }

    @MainActor
    func testNativeInputDefersAndCoalescesUpdatesWithoutLosingTyping() async throws {
        var modelText = "ab"
        var changes = 0
        var selections = 0
        let input = MnemonicTextEditor(text: Binding(get: { modelText }, set: { modelText = $0 }), inspection: nil,
            inspectionText: nil, selectionRequest: nil,
            onChange: { text, _ in modelText = text; changes += 1 }, onSelection: { _ in selections += 1 }, onSearch: {})
        let coordinator = input.makeCoordinator()
        let editor = MnemonicNativeTextView(frame: NSRect(x: 0, y: 0, width: 550, height: 92))
        editor.string = "ab"
        editor.delegate = coordinator; editor.coordinator = coordinator; coordinator.editor = editor
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = editor
        defer { coordinator.invalidate(); window.close() }
        coordinator.applyParentState(isEnabled: true)
        editor.insertText("a", replacementRange: NSRange(location: 2, length: 0))
        editor.insertText("n", replacementRange: NSRange(location: 3, length: 0))
        XCTAssertEqual(modelText, "ab", "Native callbacks must not publish synchronously")
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(selections, 0)
        coordinator.applyParentState(isEnabled: true)
        XCTAssertEqual(editor.string, "aban", "An unrelated SwiftUI render must preserve unflushed typing")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(modelText, "aban")
        XCTAssertEqual(changes, 1, "One run-loop turn should publish only the latest edit")
        editor.insertText("d", replacementRange: NSRange(location: 4, length: 0))
        modelText = ""
        coordinator.applyParentState(isEnabled: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(modelText, "", "An old input callback must not undo a programmatic clear")
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(changes, 1)
        editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        coordinator.invalidate()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(modelText, "", "Unmounted editors must discard queued input")
        XCTAssertEqual(changes, 1)
    }

    @MainActor
    func testNativeMnemonicPopupKeyboardCompletionEscapeAndUndo() async throws {
        let inspection = try await AllKeyCoreClient.shared.inspectMnemonic(text: "ab", bitSize: 128)
        var latestText = "ab"
        var searches = 0
        let input = MnemonicTextEditor(text: Binding(get: { latestText }, set: { latestText = $0 }), inspection: inspection, inspectionText: "ab", selectionRequest: nil,
            onChange: { text, _ in latestText = text }, onSelection: { _ in }, onSearch: { searches += 1 })
        let coordinator = input.makeCoordinator()
        let editor = MnemonicNativeTextView(frame: NSRect(x: 0, y: 0, width: 550, height: 100))
        editor.string = "ab"
        editor.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        editor.allowsUndo = true
        editor.delegate = coordinator
        editor.coordinator = coordinator
        coordinator.editor = editor
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 550, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { coordinator.invalidate(); window.close() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        try await Task.sleep(for: .milliseconds(30))
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        let keyWindowBefore = NSApp.keyWindow
        coordinator.updateCandidates()
        XCTAssertTrue(NSApp.keyWindow === keyWindowBefore, "Popup must not take over the keyboard window")
        XCTAssertTrue(window.firstResponder === editor, "Popup must keep keyboard focus in the input")
        XCTAssertTrue(coordinator.handle(try key(125)), "Down must select an open popup candidate")
        editor.keyDown(with: try key(36))
        XCTAssertEqual(editor.string, "ability ")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(latestText, "ability ")
        XCTAssertTrue(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "ab")
        let undoDeadline = Date().addingTimeInterval(1)
        while latestText != "ab" && Date() < undoDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(latestText, "ab", "Undo must reach the model through the deferred callback")
        editor.undoManager?.redo()
        XCTAssertEqual(editor.string, "ability ")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(latestText, "ability ", "Redo must also synchronize the model")
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(latestText, "ab")
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.updateCandidates()
        XCTAssertTrue(coordinator.handle(try key(53)), "Escape must close the popup")
        coordinator.updateCandidates()
        XCTAssertFalse(coordinator.handle(try key(125)), "Dismissal must survive unrelated view updates")
        editor.insertText("a", replacementRange: NSRange(location: 2, length: 0))
        let nextInspection = try await AllKeyCoreClient.shared.inspectMnemonic(text: "aba", bitSize: 128)
        coordinator.parent = MnemonicTextEditor(text: Binding(get: { latestText }, set: { latestText = $0 }), inspection: nextInspection, inspectionText: "aba", selectionRequest: nil,
            onChange: { text, _ in latestText = text }, onSelection: { _ in }, onSearch: { searches += 1 })
        coordinator.updateCandidates()
        XCTAssertTrue(coordinator.handle(try key(48)), "Typing after dismissal must allow Tab completion again")
        XCTAssertEqual(editor.string, "abandon ")
        XCTAssertTrue(coordinator.handle(try key(36, modifiers: .command)))
        XCTAssertEqual(searches, 1)
    }

    @MainActor
    func testCommonOptionsPreserveUnappliedAdvancedFields() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        model.accountText = "2"
        model.passphrase = "TREZOR"
        model.generate(.first)
        try await finishGeneration(model)
        let original = model.result?.items.first?.address

        model.accountText = "invalid"
        model.passphrase = "pending passphrase"
        model.customPathEnabled = true
        model.customPath = "invalid pending path"
        model.count = 2
        model.refreshDerivation()
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertEqual(model.result?.items.first?.address, original)
        XCTAssertEqual(model.appliedAccount, 2)
        XCTAssertEqual(model.appliedCustomPath, "")
        XCTAssertTrue(model.appliedPassphraseEnabled)
        XCTAssertTrue(model.hasUnappliedDerivation)
        XCTAssertEqual(model.passphrase, "pending passphrase")
        XCTAssertEqual(model.customPath, "invalid pending path")

        model.customPathEnabled = false
        model.setWordCount(256)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage, "Word count changes must also preserve the applied advanced fields")
        XCTAssertEqual(model.appliedAccount, 2)
        XCTAssertEqual(model.result?.mnemonic.split(separator: " ").count, 24)
        XCTAssertTrue(model.hasUnappliedDerivation)

        model.accountText = "3"
        model.generate(.current)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.appliedAccount, 3)
        XCTAssertFalse(model.hasUnappliedDerivation)
    }

    @MainActor
    func testCommonOptionsKeepAppliedCustomPathWhenDraftDisablesIt() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        model.customPathEnabled = true
        model.customPath = "m/44'/60'/5'/0/{index}"
        model.generate(.first)
        try await finishGeneration(model)
        let original = model.result?.items.first?.address
        model.customPathEnabled = false
        model.accountText = "invalid"
        model.count = 2
        model.refreshDerivation()
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.appliedCustomPath, "m/44'/60'/5'/0/{index}")
        XCTAssertEqual(model.result?.items.first?.address, original)
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertTrue(model.hasUnappliedDerivation)
    }

    @MainActor
    func testGenerationRejectsEmptyCoinSelectionBeforeStarting() async throws {
        let keys = PrivateKeysViewModel(autoRefreshEnabled: { false })
        keys.selectedCoins = []
        keys.generate(.first)
        XCTAssertFalse(keys.isLoading)
        XCTAssertNil(keys.result)
        XCTAssertEqual(keys.errorMessage, "请至少选择一个币种")
        let mnemonic = BIP39ViewModel()
        mnemonic.selectedCoins = []
        mnemonic.generate(.first)
        XCTAssertFalse(mnemonic.isLoading)
        XCTAssertNil(mnemonic.result)
        XCTAssertEqual(mnemonic.errorMessage, "请至少选择一个币种")
        let directory = MnemonicDirectoryViewModel(autoRefresh: { false })
        directory.selectedCoins = []
        directory.generate(.first)
        XCTAssertFalse(directory.isLoading)
        XCTAssertNil(directory.result)
        XCTAssertEqual(directory.errorMessage, "请至少选择一个币种")
        mnemonic.selectedCoins = [.ETH]
        mnemonic.refreshDerivation()
        try await finishGeneration(mnemonic)
        XCTAssertNil(mnemonic.errorMessage)
        XCTAssertNotNil(mnemonic.result, "Selecting a coin after the initial empty state must recover")
    }

    @MainActor
    func testElectrumRefreshAppliesAddressTypeAndCount() async throws {
        let model = ElectrumViewModel()
        func finish() async throws {
            let deadline = Date().addingTimeInterval(15)
            while model.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.errorMessage)
        }
        model.addressType = "standard"
        model.count = 1
        model.generate(.first)
        try await finish()
        XCTAssertEqual(model.result?.items.count, 1)
        XCTAssertTrue(model.result?.items.first?.address.hasPrefix("1") == true)
        model.addressType = "segwit"
        model.count = 2
        model.refreshDerivation()
        try await finish()
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertTrue(model.result?.items.allSatisfy { $0.address.hasPrefix("bc1") } == true)
    }

    @MainActor
    func testMnemonicAccountPassphraseApplicationAndClear() async throws {
        let model = BIP39ViewModel()
        model.selectedCoins = [.ETH]
        model.accountText = "2"
        model.passphrase = "TREZOR"
        model.generate(.first)
        try await finishGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.appliedAccount, 2)
        XCTAssertTrue(model.appliedPassphraseEnabled)
        XCTAssertEqual(model.result?.items.first?.path, "m/44'/60'/2'/0/0")
        let firstAddress = model.result?.items.first?.address
        let mnemonic = model.result?.mnemonic
        model.passphrase = ""
        XCTAssertTrue(model.hasUnappliedDerivation)
        XCTAssertEqual(model.result?.items.first?.address, firstAddress)
        model.generate(.current)
        try await finishGeneration(model)
        XCTAssertFalse(model.appliedPassphraseEnabled)
        XCTAssertEqual(model.result?.mnemonic, mnemonic)
        XCTAssertNotEqual(model.result?.items.first?.address, firstAddress)
        model.passphrase = "temporary"
        model.clear()
        XCTAssertEqual(model.passphrase, "")
    }

    @MainActor
    func testBIP39CancelDoesNotPublishStaleResults() async throws {
        let model = BIP39ViewModel()
        model.searchText = "? abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon ?"
        model.generate(.search)
        model.cancelSearch()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.result)
        XCTAssertNil(model.activePattern)
    }

    func testPuzzleCatalogAndPublicAddressItem() throws {
        let catalog = try BTCPuzzleCatalog.load()
        XCTAssertEqual(catalog.puzzles.count, 160)
        XCTAssertEqual(catalog.puzzles.first?.lowerBound, "1")
        XCTAssertEqual(catalog.puzzles.first?.upperBound, "1")
        XCTAssertEqual(catalog.puzzles.last?.lowerBound, "8" + String(repeating: "0", count: 39))
        XCTAssertEqual(catalog.puzzles.last?.upperBound, String(repeating: "f", count: 40))
        let item = catalog.puzzles[70].publicAddressItem
        XCTAssertEqual(item.coin, "BTC")
        XCTAssertEqual(item.address, catalog.puzzles[70].address)
        XCTAssertTrue(item.hexKey.isEmpty)
        XCTAssertTrue(item.keyTag.isEmpty)
        XCTAssertTrue(item.path.isEmpty)
    }

    @MainActor
    func testPuzzlePageAutomaticallyLoadsBalancesAndReusesCache() async throws {
        let catalog = try BTCPuzzleCatalog.load()
        let session = BalanceStub.configure { request in
            let active = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "active" })?.value ?? ""
            let values = Dictionary(uniqueKeysWithValues: active.components(separatedBy: "|").map { ($0, ["final_balance": 1]) })
            return (200, String(decoding: try! JSONSerialization.data(withJSONObject: values), as: UTF8.self), [:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://puzzle.test"), apiKey: "")]
        })
        let model = BTCPuzzleViewModel(catalog: catalog, balanceClient: client)
        model.pageDidAppear()
        model.selectedID = catalog.puzzles.last?.id
        let deadline = Date().addingTimeInterval(5)
        while !model.fetchingIDs.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.balances.count, 160)
        XCTAssertTrue(model.balances.values.allSatisfy { $0.status == .loaded })
        let requests = BalanceStub.captured().count
        XCTAssertGreaterThan(requests, 0)
        model.cancel()
        model.pageDidAppear()
        while !model.fetchingIDs.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(BalanceStub.captured().count, requests)
        model.filter = .all
        model.selectedID = 1
        model.refreshBalance()
        while !model.fetchingIDs.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(BalanceStub.captured().count, requests)
        model.cancel()
    }

    @MainActor
    func testPuzzleLeavingPageRejectsLateBalances() async throws {
        let session = BalanceStub.configure(delay: { _ in 0.2 }) { _ in (200, "{}", [:]) }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://puzzle.test"), apiKey: "")]
        })
        let model = BTCPuzzleViewModel(balanceClient: client)
        model.pageDidAppear()
        try await Task.sleep(for: .milliseconds(30))
        model.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(model.fetchingIDs.isEmpty)
        XCTAssertTrue(model.balances.isEmpty)
    }

    @MainActor
    func testPuzzleFilteringAndSelection() throws {
        let catalog = try BTCPuzzleCatalog.load()
        let model = BTCPuzzleViewModel(catalog: catalog)
        XCTAssertTrue(model.filteredPuzzles.allSatisfy { !$0.solved })
        XCTAssertNotNil(model.selectedPuzzle)
        model.filter = .all
        model.searchText = "#71"
        model.reconcileSelection()
        XCTAssertEqual(model.filteredPuzzles.map(\.id), [71])
        XCTAssertEqual(model.selectedID, 71)
        model.searchText = "71"
        XCTAssertEqual(model.filteredPuzzles.map(\.id), [71])
        model.searchText = "no-address-match"
        model.reconcileSelection()
        XCTAssertTrue(model.filteredPuzzles.isEmpty)
        XCTAssertNil(model.selectedPuzzle)
        model.filter = .solved
        model.searchText = catalog.puzzles[0].address
        model.reconcileSelection()
        XCTAssertEqual(model.selectedPuzzle?.id, 1)
    }

    @MainActor
    private func finishPrivateGeneration(_ model: PrivateKeysViewModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isLoading, "Generation timed out")
    }

    @MainActor
    func testPuzzleRangeHandoffExitAndTargetMatch() async throws {
        let catalog = try BTCPuzzleCatalog.load()
        let model = PrivateKeysViewModel()
        model.btcAddressType = .segwit
        model.enterPuzzle(catalog.puzzles[0])
        try await finishPrivateGeneration(model)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activePuzzle?.id, 1)
        XCTAssertEqual(model.selectedCoins, [.BTC])
        XCTAssertEqual(model.index, "1")
        XCTAssertTrue(model.matchesPuzzleTarget)
        XCTAssertEqual(model.result?.items.count, 1)
        XCTAssertEqual(model.result?.items.first?.addressTag, "Legacy(c)")
        model.generate(.next)
        try await finishPrivateGeneration(model)
        XCTAssertEqual(model.index, "1")
        model.exitPuzzle()
        model.generate(.next)
        try await finishPrivateGeneration(model)
        XCTAssertNil(model.activePuzzle)
        XCTAssertEqual(model.index, "2")
        XCTAssertEqual(model.btcAddressType, .segwit)
        XCTAssertEqual(model.result?.items.first?.addressTag, "SegWit(c)")

        model.enterPuzzle(catalog.puzzles[2], operation: .random)
        try await finishPrivateGeneration(model)
        let value = try XCTUnwrap(Int(model.index, radix: 16))
        XCTAssertTrue((4...7).contains(value))
        model.count = 2
        model.generate(.first)
        try await finishPrivateGeneration(model)
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertTrue(model.result?.items.allSatisfy { $0.coin == "BTC" && $0.addressTag == "Legacy(c)" } == true)
        model.generate(.next)
        try await finishPrivateGeneration(model)
        XCTAssertEqual(model.index, "6")
        XCTAssertEqual(model.result?.items.count, 2)
        XCTAssertTrue(model.result?.items.allSatisfy { $0.addressTag == "Legacy(c)" } == true)
        model.index = "8"
        model.generate(.current)
        try await finishPrivateGeneration(model)
        XCTAssertEqual(model.errorMessage, "索引超出当前 Puzzle 范围")
        model.clearSensitiveData()
        XCTAssertEqual(model.index, "4")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.result)
    }

    func testElectrumStandardProducesAddress() async throws {
        let result = try await AllKeyCoreClient.shared.createElectrum(
            count: 1,
            addressType: "standard",
            index: "0",
            operation: .current
        )

        XCTAssertFalse(result.mnemonic.isEmpty)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertTrue(result.items[0].address.hasPrefix("1"))
    }

    func testInvalidPrivateKeyReturnsStructuredError() async {
        do {
            _ = try await AllKeyCoreClient.shared.createKeys(
                index: "not-hex",
                coins: [.BTC],
                count: 1
            )
            XCTFail("Expected the native core to reject the index")
        } catch let error as CoreAPIError {
            XCTAssertEqual(error.code, "invalid_request")
            XCTAssertTrue(error.message.contains("十六进制"))
            XCTAssertTrue(error.message.contains("WIF"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBalanceRequestContainsOnlyPublicAddresses() async throws {
        let item = AddressItem(coin: "BTC", path: "DO_NOT_SEND_PATH", hexKey: "DO_NOT_SEND_PRIVATE_KEY",
            keyTag: "DO_NOT_SEND_WIF", address: "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH", addressTag: "Legacy(c)",
            balance: "", transactionCount: "", received: "")
        let session = BalanceStub.configure { request in
            let text = request.url!.absoluteString
            XCTAssertTrue(text.contains(item.address))
            XCTAssertFalse(text.contains(item.hexKey))
            XCTAssertFalse(text.contains(item.keyTag))
            XCTAssertFalse(text.contains(item.path))
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.httpBodyStream)
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["cors", "active"])
            return (200, #"{"1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH":{"final_balance":0}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://public.test/balance"), apiKey: "")]
        })
        let values = try await client.fetch(items: [item])
        XCTAssertEqual(values[item.id]?.status, .loaded)
        XCTAssertEqual(BalanceStub.captured().count, 1)
    }

    func testDirectBalanceResponsesUseNativeCoinUnits() async throws {
        let cases: [(Coin, BalanceProvider, String, String, String)] = [
            (.BTC, .blockchain, "btc-address", #"{"btc-address":{"final_balance":"123456789","n_tx":2,"total_received":"200000000"}}"#, "1.23456789 BTC"),
            (.DOGE, .blockcypher, "doge-address", #"{"address":"doge-address","final_balance":123456789,"n_tx":2}"#, "1.23456789 DOGE"),
            (.ETH, .evmRPC, "eth-address", #"{"jsonrpc":"2.0","result":"0x112210f47de98115","id":1}"#, "1.234567890123456789 ETH"),
            (.BTC, .blockchair, "btc-address", #"{"context":{"code":200},"data":{"btc-address":{"address":{"balance":123456789,"transaction_count":2,"received":200000000}}}}"#, "1.23456789 BTC"),
            (.ETH, .etherscan, "eth-address", #"{"status":"1","result":"1234567890123456789"}"#, "1.234567890123456789 ETH"),
            (.BSC, .etherscan, "bsc-address", #"{"status":"1","result":"0"}"#, "0 BNB"),
            (.BSC, .evmRPC, "bsc-address", #"{"jsonrpc":"2.0","result":"0xde0b6b3a7640000","id":1}"#, "1 BNB"),
            (.TRX, .tronGrid, "trx-address", #"{"success":true,"data":[{"balance":1234567}]}"#, "1.234567 TRX"),
            (.SOL, .solanaRPC, "sol-address", #"{"jsonrpc":"2.0","result":{"value":1234567890},"id":1}"#, "1.23456789 SOL"),
            (.LTC, .chainz, "ltc-address", #"{"ltc-address":"2.75"}"#, "2.75 LTC"),
            (.DOGE, .okLink, "doge-address", #"{"code":"0","data":[{"balance":"42.5","receiveAmount":"50","transactionCount":"3"}]}"#, "42.5 DOGE")
        ]

        for (coin, provider, address, json, expected) in cases {
            let record = try await BalanceClient.shared.parseDirect(
                data: Data(json.utf8), address: address, coin: coin, provider: provider
            )
            XCTAssertEqual(record.status, .loaded)
            XCTAssertEqual(record.balance, expected)
        }
    }
}

/// Deterministic transport: these tests never contact public chains or use stored credentials.
private final class BalanceStub: URLProtocol {
    typealias Reply = (Int, String, [String: String])
    static let lock = NSLock()
    static var handler: ((URLRequest) -> Reply)?
    static var requests: [URLRequest] = []
    static var active = 0
    static var maximumActive = 0
    static var delay: (URLRequest) -> TimeInterval = { _ in 0.03 }

    static func configure(delay: @escaping (URLRequest) -> TimeInterval = { _ in 0.03 }, _ handler: @escaping (URLRequest) -> Reply) -> URLSession {
        lock.lock()
        self.handler = handler
        self.delay = delay
        requests = []
        active = 0
        maximumActive = 0
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BalanceStub.self]
        return URLSession(configuration: configuration)
    }

    static func captured() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.active += 1
        Self.maximumActive = max(Self.maximumActive, Self.active)
        let reply = Self.handler?(request) ?? (500, "{}", [:])
        let delay = Self.delay(request)
        Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            Self.lock.lock(); Self.active -= 1; Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: reply.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class BalanceQueryTests: XCTestCase {
    private func item(_ address: String, coin: String = "BTC", tag: String = "") -> AddressItem {
        AddressItem(coin: coin, path: "SECRET_PATH", hexKey: "SECRET_PRIVATE_KEY", keyTag: "SECRET_WIF",
                    address: address, addressTag: tag, balance: "", transactionCount: "", received: "")
    }

    private func service(_ provider: BalanceProvider, _ host: String) -> BalanceService {
        BalanceService(endpoint: BalanceEndpoint(provider: provider, url: "https://\(host)"), apiKey: "")
    }

    func testNonZeroHighlightPreservesTinyValuesAndDistinguishesZero() {
        for value in ["0", "0.00000000 BTC", "-0", "0e10", "0.0E-18 SOL", "—", "不可用", "BTC20"] {
            XCTAssertFalse(BalanceRecord.isNonZero(value), value)
        }
        for value in ["0.000000000000000001 ETH", "1", "1e-1000", "1,234.50 BTC", "-0.01"] {
            XCTAssertTrue(BalanceRecord.isNonZero(value), value)
        }
        XCTAssertFalse(BalanceRecord.isNonZero(nil))
        XCTAssertTrue(BalanceRecord(status: .loaded, balance: "0 BTC", transactionCount: "1", received: nil).hasNonZeroData)
        XCTAssertTrue(BalanceRecord(status: .loaded, balance: "0 BTC", transactionCount: "0", received: "0.00000001").hasNonZeroData)
        XCTAssertFalse(BalanceRecord(status: .unavailable, balance: "1 BTC", transactionCount: "1", received: nil).hasNonZeroData)
    }

    func testPartialBatchFallbackCacheAndForceRefresh() async throws {
        let session = BalanceStub.configure { request in
            if request.url!.host == "primary.test" {
                return (200, #"{"a":{"final_balance":123456789,"n_tx":2,"total_received":200000000}}"#, [:])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/b"), "Only the missing address should reach backup")
            return (200, #"{"context":{"code":200},"data":{"b":{"address":{"balance":0}}}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchain, "primary.test"), service(.blockchair, "backup.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let a = item("a"), duplicate = item("a", tag: "second"), b = item("b")
        let first = try await client.fetch(items: [a, duplicate, b])
        XCTAssertEqual(first[a.id]?.balance, "1.23456789 BTC")
        XCTAssertEqual(first[duplicate.id]?.balance, first[a.id]?.balance)
        XCTAssertEqual(first[b.id]?.balance, "0 BTC")
        XCTAssertTrue(first[b.id]?.source?.contains("backup.test") == true)
        XCTAssertEqual(BalanceStub.captured().count, 2)
        let cached = try await client.fetch(items: [a, b])
        XCTAssertEqual(BalanceStub.captured().count, 2)
        XCTAssertEqual(cached[a.id]?.isCached, true)
        XCTAssertEqual(cached[a.id]?.queriedAt, first[a.id]?.queriedAt)
        _ = try await client.fetch(items: [a, b], forceRefresh: true)
        XCTAssertEqual(BalanceStub.captured().count, 4)
        let requestText = BalanceStub.captured().map { $0.url!.absoluteString + String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined()
        XCTAssertFalse(requestText.contains("SECRET_"))
    }

    func testFailureDoesNotDiscardSuccessAndIsNeverCachedAsZero() async throws {
        let session = BalanceStub.configure { request in
            let address = request.url!.lastPathComponent
            if address == "bad" { return (200, "{}", [:]) }
            return (200, #"{"context":{"code":200},"data":{"good":{"address":{"balance":1}}}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchair, "provider.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let good = item("good"), bad = item("bad")
        let first = try await client.fetch(items: [bad, good])
        XCTAssertEqual(first[good.id]?.balance, "0.00000001 BTC")
        XCTAssertEqual(first[bad.id]?.status, .unavailable)
        XCTAssertNil(first[bad.id]?.balance)
        XCTAssertNotNil(first[bad.id]?.errorMessage)
        _ = try await client.fetch(items: [bad, good])
        XCTAssertEqual(BalanceStub.captured().filter { $0.url!.lastPathComponent == "good" }.count, 1)
        XCTAssertEqual(BalanceStub.captured().filter { $0.url!.lastPathComponent == "bad" }.count, 2)
    }

    func testConcurrentWaitersShareRequestAndCancellationDoesNotPoisonResult() async throws {
        let session = BalanceStub.configure { _ in (200, #"{"a":{"final_balance":1}}"#, [:]) }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchain, "provider.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let a = item("a")
        let cancelled = Task { try await client.fetch(items: [a]) }
        async let retained = client.fetch(items: [a])
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let values = try await retained
        XCTAssertEqual(values[a.id]?.balance, "0.00000001 BTC")
        do { _ = try await cancelled.value; XCTFail("Expected cancelled waiter") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(BalanceStub.captured().count, 1)
        let cached = try await client.fetch(items: [a])
        XCTAssertEqual(cached[a.id]?.isCached, true)
    }

    func testRateLimitWithLongRetryAfterImmediatelyUsesBackup() async throws {
        let session = BalanceStub.configure { request in
            if request.url!.host == "limited.test" { return (429, "{}", ["Retry-After": "60"]) }
            return (200, #"{"a":{"final_balance":0}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchain, "limited.test"), service(.blockchain, "backup.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let a = item("a")
        let values = try await client.fetch(items: [a])
        XCTAssertEqual(values[a.id]?.balance, "0 BTC")
        XCTAssertTrue(values[a.id]?.source?.contains("backup.test") == true)
        _ = try await client.fetch(items: [a], forceRefresh: true)
        XCTAssertEqual(BalanceStub.captured().filter { $0.url!.host == "limited.test" }.count, 1)
    }

    func testSolanaBatchesAndNullAccountsWhileMissingFieldsFail() async throws {
        let session = BalanceStub.configure { request in
            // URLSession can supply bodies as streams; read either representation.
            let root = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            XCTAssertEqual(root["method"] as? String, "getMultipleAccounts")
            let params = root["params"] as! [Any]
            let addresses = params[0] as! [String]
            XCTAssertLessThanOrEqual(addresses.count, 100)
            let values: [Any] = addresses.map { $0 == "invalid" ? ([:] as [String: Any]) as Any : NSNull() as Any }
            let data = try! JSONSerialization.data(withJSONObject: ["result": ["value": values]])
            return (200, String(decoding: data, as: UTF8.self), [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.solanaRPC, "solana.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let items = (0..<100).map { item("address\($0)", coin: "SOL") } + [item("invalid", coin: "SOL")]
        let values = try await client.fetch(items: items)
        XCTAssertEqual(values[items[0].id]?.balance, "0 SOL")
        XCTAssertEqual(values[items[100].id]?.status, .unavailable)
        XCTAssertEqual(BalanceStub.captured().count, 2)
    }

    func testBoundedConcurrencyForDirectQueries() async throws {
        let session = BalanceStub.configure { request in
            let address = request.url!.pathComponents.dropLast().last!
            return (200, "{\"address\":\"\(address)\",\"final_balance\":100000000,\"n_tx\":2}", [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockcypher, "doge.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let items = (0..<8).map { item("address\($0)", coin: "DOGE") }
        let values = try await client.fetch(items: items)
        XCTAssertTrue(values.values.allSatisfy { $0.balance == "1 DOGE" })
        XCTAssertEqual(values.count, 8)
        XCTAssertLessThanOrEqual(BalanceStub.maximumActive, 3)
        XCTAssertGreaterThan(BalanceStub.maximumActive, 1)
    }

    func testTransientHTTPFailureRetriesOnce() async throws {
        var attempts = 0
        let session = BalanceStub.configure { _ in
            attempts += 1
            return attempts == 1 ? (503, "{}", ["Retry-After": "0"]) : (200, #"{"a":{"final_balance":0}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchain, "provider.test")]
        let client = BalanceClient(session: session, requestSpacing: 0, services: { _ in providers })
        let a = item("a")
        let values = try await client.fetch(items: [a])
        XCTAssertEqual(values[a.id]?.balance, "0 BTC")
        XCTAssertEqual(BalanceStub.captured().count, 2)
    }

    func testMalformedDirectBalanceFallsBackInsteadOfCachingMissingAmount() async throws {
        let session = BalanceStub.configure { request in
            if request.url!.host == "malformed.test" {
                return (200, #"{"a":{}}"#, [:])
            }
            return (200, #"{"a":{"final_balance":1}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = [service(.blockchain, "malformed.test"), service(.blockchain, "backup.test")]
        let client = BalanceClient(session: session, cacheTTL: 0, requestSpacing: 0, services: { _ in providers })
        let a = item("a")
        let values = try await client.fetch(items: [a])
        XCTAssertEqual(values[a.id]?.balance, "0.00000001 BTC")
        _ = try await client.fetch(items: [a])
        XCTAssertEqual(BalanceStub.captured().count, 4, "Expired results must be queried again")
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

final class BalanceConfigurationTests: XCTestCase {
    func testConfigurationFileRoundTripPermissionsAndSeparateRoles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AllKeyUI-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceConfigurationStore(fileURL: directory.appendingPathComponent("balance-settings.json"))
        XCTAssertNil(try store.load()[.ETH, .primary])
        var config = BalanceFileConfiguration()
        config[.ETH, .primary] = StoredBalanceService(
            endpoint: BalanceEndpoint(provider: .etherscan, url: "https://example.test/api"), apiKey: "TEST_PRIMARY_TOKEN")
        config[.ETH, .backup] = StoredBalanceService(
            endpoint: BalanceEndpoint(provider: .evmRPC, url: "https://backup.test/{API_KEY}"), apiKey: "TEST_BACKUP_TOKEN")
        try store.save(config)
        let restored = try store.load()
        XCTAssertEqual(restored[.ETH, .primary]?.apiKey, "TEST_PRIMARY_TOKEN")
        XCTAssertEqual(restored[.ETH, .backup]?.apiKey, "TEST_BACKUP_TOKEN")
        XCTAssertEqual(restored[.ETH, .backup]?.endpoint.provider, .evmRPC)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(directoryPermissions?.intValue, 0o700)
        var changed = restored
        changed[.ETH, .primary] = nil
        try store.save(changed)
        let updated = try store.load()
        XCTAssertNil(updated[.ETH, .primary])
        XCTAssertEqual(updated[.ETH, .backup]?.apiKey, "TEST_BACKUP_TOKEN")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["balance-settings.json"])
    }

    func testRetiredProviderIsRemovedWithoutLosingOtherServicesOrNetworks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AllKeyUI-retired-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceConfigurationStore(fileURL: directory.appendingPathComponent("balance-settings.json"))
        var config = BalanceFileConfiguration()
        config[.ETH, .primary] = StoredBalanceService(endpoint: BalanceEndpoint(provider: .evmRPC, url: "https://rpc.test"), apiKey: "KEEP_TEST_KEY")
        config[.BTC, .backup] = StoredBalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://btc.test"), apiKey: "")
        config.evmNetworks = [EVMNetwork(name: "Test", chainID: "123", symbol: "TEST", rpcURL: "https://network.test")]
        let encoded = try JSONEncoder().encode(config)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let retired: [String: Any] = ["endpoint": ["provider": "allKey", "url": "https://retired.test/api"], "apiKey": "REMOVE_TEST_KEY"]
        var primary = try XCTUnwrap(root["primary"] as? [String: Any])
        var backup = try XCTUnwrap(root["backup"] as? [String: Any])
        primary["BTC"] = retired; backup["SOL"] = retired
        root["primary"] = primary; root["backup"] = backup
        try store.prepareDirectory()
        try JSONSerialization.data(withJSONObject: root).write(to: store.fileURL)
        let migrated = try store.load()
        XCTAssertNil(migrated[.BTC, .primary])
        XCTAssertNil(migrated[.SOL, .backup])
        XCTAssertEqual(migrated[.ETH, .primary]?.apiKey, "KEEP_TEST_KEY")
        XCTAssertEqual(migrated[.BTC, .backup]?.endpoint.provider, .blockchain)
        XCTAssertEqual(migrated.evmNetworks, config.evmNetworks)
        let persisted = try String(contentsOf: store.fileURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("allKey"))
        XCTAssertFalse(persisted.contains("REMOVE_TEST_KEY"))
        XCTAssertEqual(try store.load()[.ETH, .primary]?.apiKey, "KEEP_TEST_KEY")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testProviderChoicesContainOnlySupportedServices() {
        XCTAssertNil(BalanceProvider(rawValue: "allKey"))
        for coin in Coin.allCases {
            XCTAssertFalse(BalanceProvider.choices(for: coin).isEmpty)
            XCTAssertTrue(BalanceProvider.choices(for: coin).allSatisfy { BalanceProvider.allCases.contains($0) })
        }
    }

    func testInvalidConfigurationFailsWithoutReplacingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AllKeyUI-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceConfigurationStore(fileURL: directory.appendingPathComponent("balance-settings.json"))
        try store.prepareDirectory()
        for text in ["invalid JSON", #"{"version":99,"primary":{},"backup":{}}"#,
                     #"{"version":99,"primary":{"BTC":{"endpoint":{"provider":"allKey","url":"https://retired.test"},"apiKey":"TEST"}},"backup":{}}"#] {
            let bytes = Data(text.utf8)
            try bytes.write(to: store.fileURL)
            XCTAssertThrowsError(try store.load())
            XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        }
    }
}


private final class BalanceUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: BalanceRecord] = [:]
    private var batches: [[String: BalanceRecord]] = []
    func append(_ delta: [String: BalanceRecord]) {
        lock.lock(); defer { lock.unlock() }
        values.merge(delta) { _, new in new }; batches.append(delta)
    }
    func snapshot() -> [String: BalanceRecord] { lock.lock(); defer { lock.unlock() }; return values }
    func deliveries() -> [[String: BalanceRecord]] { lock.lock(); defer { lock.unlock() }; return batches }
}

final class RemainingFeaturesTests: XCTestCase {
    private func item(_ address: String, coin: String = "ETH") -> AddressItem {
        AddressItem(coin: coin, path: "PRIVATE_PATH", hexKey: "PRIVATE_HEX", keyTag: "PRIVATE_WIF", address: address, addressTag: "", balance: "", transactionCount: "", received: "")
    }
    private func network(_ chain: String, host: String, decimals: Int = 18, symbol: String = "ETH") -> EVMNetwork {
        EVMNetwork(name: "Network " + chain, chainID: chain, symbol: symbol, decimals: decimals, rpcURL: "https://" + host, explorerURL: "https://explorer.test")
    }

    private static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    func testProgressArrivesBeforeSlowAddressAndFiltersDoNotTreatUnknownAsZero() async throws {
        let fast = item("fast", coin: "DOGE"), slow = item("slow", coin: "DOGE")
        let session = BalanceStub.configure(delay: { $0.url!.path.contains("slow") ? 0.4 : 0.01 }) { request in
            let address = request.url!.path.contains("slow") ? "slow" : "fast"
            return (200, "{\"address\":\"" + address + "\",\"final_balance\":1,\"n_tx\":2,\"total_received\":1}", [:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, networks: { [] }, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockcypher, url: "https://progress.test"), apiKey: "")]
        })
        let recorder = BalanceUpdateRecorder()
        let first = expectation(description: "First address delivered")
        let work = Task {
            try await client.fetch(items: [fast, slow]) { values in
                recorder.append(values)
                if values[fast.id] != nil { first.fulfill() }
            }
        }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(recorder.snapshot()[fast.id]?.status, .loaded)
        XCTAssertNil(recorder.snapshot()[slow.id])
        let final = try await work.value
        XCTAssertEqual(final.count, 2)
        XCTAssertEqual(recorder.snapshot(), final)
        XCTAssertFalse(BalanceResultFilter.funded.includes(nil))
        XCTAssertFalse(BalanceResultFilter.activity.includes(nil))
        XCTAssertFalse(BalanceResultFilter.funded.includes(.failed("unavailable")))
        XCTAssertTrue(BalanceResultFilter.failed.includes(.failed("unavailable")))
        XCTAssertTrue(BalanceResultFilter.activity.includes(BalanceRecord(status: .loaded, balance: "0 DOGE", transactionCount: "1", received: nil)))
    }

    @MainActor
    func testLateBalanceProgressCannotOverwriteNewPrivateKeyPage() async throws {
        let oldPage = try await AllKeyCoreClient.shared.createKeys(index: "1", coins: [.BTC], count: 1, btcType: .segwit)
        let oldAddress = try XCTUnwrap(oldPage.items.first?.address)
        let session = BalanceStub.configure(delay: { request in
            request.url!.absoluteString.contains(oldAddress) ? 0.35 : 0.01
        }) { request in
            let active = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "active" })?.value ?? ""
            let values = Dictionary(uniqueKeysWithValues: active.components(separatedBy: "|").map { ($0,["final_balance":1]) })
            return (200,String(decoding: try! JSONSerialization.data(withJSONObject: values),as: UTF8.self),[:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, networks: { [] }, services: { _ in
            [BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://pages.test"), apiKey: "")]
        })
        let model = PrivateKeysViewModel(balanceClient: client, autoRefreshEnabled: { true })
        model.selectedCoins = [.BTC]; model.btcAddressType = .segwit
        model.generate(.first)
        let deadline = Date().addingTimeInterval(5)
        while BalanceStub.captured().isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(BalanceStub.captured().isEmpty)
        model.generate(.next)
        while (model.isLoading || model.isBalanceLoading) && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.index,"2")
        let currentIDs = Set(model.result?.items.map(\.id) ?? [])
        XCTAssertEqual(Set(model.balances.keys),currentIDs)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(Set(model.balances.keys),currentIDs)
        XCTAssertTrue(model.balancePending.isEmpty)
        model.clearSensitiveData()
    }

    func testProgressDoesNotPublishPrimaryFailureWhileBackupIsPending() async throws {
        let address = item("a", coin: "BTC")
        let session = BalanceStub.configure { request in
            if request.url!.host == "primary.test" { return (200, "{}", [:]) }
            return (200, #"{"a":{"final_balance":1}}"#, [:])
        }
        defer { session.invalidateAndCancel() }
        let providers = ["primary.test", "backup.test"].map { BalanceService(endpoint: BalanceEndpoint(provider: .blockchain, url: "https://" + $0), apiKey: "") }
        let client = BalanceClient(session: session, requestSpacing: 0, networks: { [] }, services: { _ in providers })
        let recorder = BalanceUpdateRecorder()
        let values = try await client.fetch(items: [address], onUpdate: { values in recorder.append(values) })
        XCTAssertEqual(values[address.id]?.status, .loaded)
        XCTAssertEqual(recorder.deliveries().count, 1)
        XCTAssertTrue(recorder.snapshot().values.allSatisfy { $0.status == .loaded })
    }

    func testCustomEVMNetworksSeparateCachesUnitsExplorerAndVerifyChain() async throws {
        let first = network("100", host: "first.test", decimals: 6, symbol: "ONE")
        let second = network("200", host: "second.test", symbol: "TWO")
        let address = item("0x0000000000000000000000000000000000000001")
        let projected = AddressProjection.addingNetworks(to: [address], networks: [first, second])
        XCTAssertEqual(Set(projected.map(\.id)).count, 3)
        XCTAssertEqual(projected[1].explorerURL?.absoluteString, "https://explorer.test/address/" + address.address)
        let session = BalanceStub.configure { request in
            let payload = Self.body(request)
            XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("PRIVATE_"))
            let body = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let chain = request.url!.host == "first.test" ? "0x64" : "0xc8"
            return (200, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"" + (body?["method"] as? String == "eth_chainId" ? chain : "0xf4240") + "\"}", [:])
        }
        defer { session.invalidateAndCancel() }
        let client = BalanceClient(session: session, requestSpacing: 0, networks: { [first, second] }, services: { _ in [] })
        let values = try await client.fetch(items: Array(projected.dropFirst()))
        XCTAssertEqual(values[projected[1].id]?.balance, "1 ONE")
        XCTAssertEqual(values[projected[2].id]?.balance, "0.000000000001 TWO")
        XCTAssertEqual(BalanceStub.captured().count, 4)
        _ = try await client.fetch(items: Array(projected.dropFirst()))
        XCTAssertEqual(BalanceStub.captured().count, 4)
        let bodyText = BalanceStub.captured().map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined()
        XCTAssertFalse(bodyText.contains("PRIVATE_"))
        var changedDraft = first; changedDraft.chainID = "101"
        let changed = changedDraft
        let wrongItems = AddressProjection.addingNetworks(to: [address], networks: [changed])
        let wrongClient = BalanceClient(session: session, requestSpacing: 0, networks: { [changed] }, services: { _ in [] })
        let wrong = try await wrongClient.fetch(items: [wrongItems[1]])
        XCTAssertEqual(wrong[wrongItems[1].id]?.status, .unavailable)
        XCTAssertTrue(wrong[wrongItems[1].id]?.errorMessage?.contains("链 ID") == true)
        XCTAssertEqual(BalanceStub.captured().count, 5, "Wrong chain must prevent eth_getBalance")
        let removedClient = BalanceClient(session: session, requestSpacing: 0, networks: { [] }, services: { _ in [] })
        let removed = try await removedClient.fetch(items: [projected[1]])
        XCTAssertEqual(removed[projected[1].id]?.status, .unavailable)
        XCTAssertEqual(BalanceStub.captured().count, 5, "Deleted network must not fall back to ETH")
    }

    func testEVMConfigurationValidationAndOldFileCompatibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BalanceConfigurationStore(fileURL: directory.appendingPathComponent("settings.json"))
        try store.prepareDirectory()
        try Data(#"{"version":1,"primary":{},"backup":{}}"#.utf8).write(to: store.fileURL)
        XCTAssertNil(try store.load().evmNetworks)
        let valid = network("100", host: "rpc.test")
        var configuration = try store.load(); configuration.evmNetworks = [valid]
        try store.save(configuration)
        XCTAssertEqual(try store.load().evmNetworks, [valid])
        XCTAssertThrowsError(try EVMNetwork.validateList([valid, valid]))
        let mutations: [(inout EVMNetwork) -> Void] = [
            { $0.rpcURL = "http://rpc.test" }, { $0.chainID = "0" }, { $0.chainID = "001" },
            { $0.decimals = 37 }, { $0.symbol = "BAD SYMBOL" }, { $0.explorerURL = "javascript:bad" }
        ]
        for mutate in mutations {
            var invalid = valid; mutate(&invalid)
            XCTAssertThrowsError(try invalid.validate())
        }
    }
}

final class CalculatorTests: XCTestCase {
    @MainActor
    private func finish(_ model: CalculatorViewModel) async throws {
        let deadline = Date().addingTimeInterval(15)
        while model.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isRunning, "Calculator timed out")
    }

    func testCalculatorBridgeAndPublishedBIP38Vector() async throws {
        let core = CalculatorCoreClient.shared
        let address = try await core.calculate(operation: "priv-to-addr-c", input: "1")
        XCTAssertEqual(address, "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH")
        let cipher = try await core.calculate(operation: "bip38-encrypt",
            input: "5KN7MzqK5wt2TP1fQCYyHBtDrXdJuXbUzm4A9rKAteGu3Qi5CVR", passphrase: "TestingOneTwoThree")
        XCTAssertEqual(cipher, "6PRVWUbkzzsbcVac2qwfssoUJAN1Xhrg6bNk8J7Nzm5H7kxEbn2Nh2ZoGg")
        let decoded = try await core.calculate(operation: "bip38-decrypt", input: cipher, passphrase: "TestingOneTwoThree")
        XCTAssertTrue(decoded.contains("5KN7MzqK5wt2TP1fQCYyHBtDrXdJuXbUzm4A9rKAteGu3Qi5CVR"))
        do {
            _ = try await core.calculate(operation: "hash160-to-addr", input: String(repeating: "g", count: 40))
            XCTFail("Invalid hex must fail through the bridge")
        } catch { XCTAssertTrue(error.localizedDescription.contains("十六进制")) }
    }

    @MainActor
    func testCalculatorBatchKeepsPerLineErrorsAndInvalidatesOldResults() async throws {
        let model = CalculatorViewModel()
        model.batch = true
        model.input = "255\nbad\n\n16"
        model.run()
        try await finish(model)
        XCTAssertEqual(model.rows.map(\.line), [1, 2, 4])
        XCTAssertEqual(model.rows.map(\.output), ["ff", nil, "10"])
        XCTAssertNotNil(model.rows[1].error)
        XCTAssertEqual(model.successes, 2)
        XCTAssertEqual(model.outputText, "ff\n10")
        model.input = "17"
        XCTAssertTrue(model.rows.isEmpty)
        model.run()
        try await finish(model)
        XCTAssertEqual(model.outputText, "11")
        model.category = .privateKey
        XCTAssertEqual(model.operation.id, "priv-to-all")
        XCTAssertTrue(model.rows.isEmpty)
    }

    @MainActor
    func testCalculatorPreservesWholeTextAndGeneratesWithEmptyInput() async throws {
        let model = CalculatorViewModel()
        model.category = .hash
        model.operation = try XCTUnwrap(CalculatorOperation.all.first { $0.id == "sha256-text" })
        model.batch = true
        model.input = " 中\n"
        XCTAssertFalse(model.usesBatch)
        model.run()
        try await finish(model)
        let expected = try await CalculatorCoreClient.shared.calculate(operation: "sha256", input: "20e4b8ad0a")
        XCTAssertEqual(model.outputText, expected)
        model.category = .utility
        model.operation = try XCTUnwrap(CalculatorOperation.all.first { $0.isRandom })
        model.input = ""
        XCTAssertTrue(model.canRun)
        model.run()
        try await finish(model)
        XCTAssertEqual(model.rows.count, 1)
        XCTAssertEqual(model.outputText.count, 64)
    }

    @MainActor
    func testCalculatorClearDropsInFlightResultsAndSensitiveFields() async throws {
        let model = CalculatorViewModel()
        model.category = .bip38
        model.input = "1"
        model.passphrase = "temporary test passphrase"
        model.run()
        XCTAssertTrue(model.isRunning)
        model.clear()
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.input, "")
        XCTAssertEqual(model.passphrase, "")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(model.rows.isEmpty)
        model.category = .basic
        model.input = "255"
        model.run()
        try await finish(model)
        XCTAssertEqual(model.outputText, "ff")
    }

    @MainActor
    func testCalculatorBatchLimitAndMetadataCoverage() async throws {
        let model = CalculatorViewModel()
        model.batch = true
        model.input = Array(repeating: "1", count: 201).joined(separator: "\n")
        model.run()
        XCTAssertFalse(model.isRunning)
        XCTAssertNotNil(model.message)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(Set(CalculatorOperation.all.map(\.id)).count, 46)
        XCTAssertTrue(CalculatorCategory.allCases.allSatisfy { !$0.operations.isEmpty })
        XCTAssertTrue(AppSection.allCases.contains(.calculator))
    }
}
