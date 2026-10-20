import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case privateKeys
    case bip39
    case electrum
    case btcPuzzle
    case calculator
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .privateKeys: "私钥库"
        case .bip39: "BIP39 助记词"
        case .electrum: "Electrum"
        case .btcPuzzle: "BTC Puzzle"
        case .calculator: "Crypto Calculator"
        case .settings: "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .privateKeys: "从确定性索引派生地址"
        case .bip39: "12–24 词标准助记词"
        case .electrum: "Standard 与 SegWit 种子"
        case .btcPuzzle: "公开题目与范围浏览"
        case .calculator: "密钥、地址与密码学转换"
        case .settings: "外观与余额查询服务"
        }
    }

    var symbol: String {
        switch self {
        case .privateKeys: "key.horizontal"
        case .bip39: "text.book.closed"
        case .electrum: "bolt.horizontal.circle"
        case .btcPuzzle: "puzzlepiece.extension"
        case .calculator: "function"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @AppStorage(ThemeAppearance.storageKey) private var appearance: ThemeAppearance = .system
    @StateObject private var privateKeys = PrivateKeysViewModel()
    @State private var selection: AppSection? = .privateKeys

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                BrandHeader()
                List(AppSection.allCases, selection: $selection) { section in
                    NavigationLink(value: section) {
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title)
                                    .font(.system(size: 15, weight: .semibold))
                                Text(section.subtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: section.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 24)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.sidebar)

                PrivacyBadge()
                    .padding(16)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 330)
        } detail: {
            Group {
                switch selection ?? .privateKeys {
                case .privateKeys:
                    PrivateKeysView(model: privateKeys)
                case .bip39:
                    BIP39View()
                case .electrum:
                    ElectrumView()
                case .btcPuzzle:
                    BTCPuzzleView { puzzle, operation in
                        privateKeys.enterPuzzle(puzzle, operation: operation)
                        selection = .privateKeys
                    }
                case .calculator:
                    CryptoCalculatorView()
                case .settings:
                    BalanceSettingsView()
                }
            }
            .background(Theme.canvas)
        }
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme)
    }
}

private struct BrandHeader: View {
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.brand)
                Image(systemName: "key.radiowaves.forward.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black.opacity(0.82))
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text("ALLKEY")
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .tracking(1.6)
                Text("LOCAL KEYSPACE EXPLORER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .tracking(0.7)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct PrivacyBadge: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(Theme.positive)
            VStack(alignment: .leading, spacing: 1) {
                Text("本地计算")
                    .font(.callout.weight(.semibold))
                Text("钱包密钥不会离开此设备")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
