import AppKit
import SwiftUI

struct PrivateKeysView: View {
    @ObservedObject var model: PrivateKeysViewModel
    @State private var balanceFilter: BalanceResultFilter = .all

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let puzzle = model.activePuzzle { puzzleScope(puzzle) }
                    controls.disabled(model.isLoading)
                    status
                    navigation
                    results
                }
                .pageContent()
            }
        }
        .navigationTitle("私钥库")
        .onAppear {
            if model.activePuzzle != nil && model.result == nil && !model.isLoading { model.generate(.current) }
        }
        .onDisappear { model.clearSensitiveData() }
    }

    private var header: some View {
        FeatureHeader(
            title: "私钥库",
            subtitle: "按 secp256k1 索引在本机派生地址"
        ) {
            Label("OFFLINE CORE", systemImage: "checkmark.shield.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.positive)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Theme.positive.opacity(0.10), in: Capsule())
        }
    }

    private func puzzleScope(_ puzzle: BTCPuzzle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("BTC Puzzle #\(puzzle.id) · 范围浏览", systemImage: "puzzlepiece.extension")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button("退出范围") { model.exitPuzzle() }
            }
            Text("0x\(puzzle.lowerBound) … 0x\(puzzle.upperBound)（含首尾）")
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text("目标地址 \(puzzle.address)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if model.matchesPuzzleTarget {
                Label("当前结果已匹配目标地址", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.positive)
            }
        }
        .panel()
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading(title: "生成参数", subtitle: model.activePuzzle == nil ? "输入 HEX 或 Bitcoin 主网 WIF，选择需要派生的币种" : "首尾、翻页与随机均限定在此题范围内")

            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "HEX / WIF 私钥")
                TextField("HEX（如 1、0x01）或主网 WIF", text: $model.index)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .controlSize(.regular)
                    .onSubmit { model.generate(.current) }
            }
            ParameterFlowLayout(horizontalSpacing: 16) {
                ParameterPicker(title: "连续数量", width: 110, selection: $model.count) {
                    ForEach([1, 2, 4, 6], id: \.self) { Text("\($0)").tag($0) }
                }
                if model.activePuzzle == nil && model.selectedCoins.contains(.BTC) {
                    ParameterPicker(title: "BTC 地址类型", width: 220, selection: $model.btcAddressType) {
                        ForEach(BTCPrivateKeyAddressType.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: model.btcAddressType) { _ in
                        if model.result != nil { model.generate(.current) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "输入后点击生成")
                    Button { model.generate(.current) } label: {
                        Label("生成地址", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isLoading || model.selectedCoins.isEmpty)
                }
            }
            .help("输入与连续数量修改后点击生成；BTC 地址类型修改后会自动更新已有结果。自动识别 HEX / WIF，WIF 压缩标记显示在结果中。")

            if model.activePuzzle == nil {
                Divider()
    
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel(title: "币种 · 已选 \(model.selectedCoins.count)")
                    ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(Coin.allCases) { coin in
                            CoinToggle(
                                coin: coin,
                                isSelected: model.selectedCoins.contains(coin)
                            ) {
                                if model.selectedCoins.contains(coin) {
                                    model.selectedCoins.remove(coin)
                                } else {
                                    model.selectedCoins.insert(coin)
                                }
                            }
                        }
                    }
                    .disabled(model.activePuzzle != nil || model.isLoading)
                    if model.selectedCoins.isEmpty { CoinSelectionWarning() }
                }
            }

        }
        .panel()
    }

    private var navigation: some View {
        ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            KeyspaceNavigationButton(symbol: "backward.end.fill", title: "首页") { model.generate(.first) }
            KeyspaceNavigationButton(symbol: "chevron.left", title: "上一页") { model.generate(.previous) }
            KeyspaceNavigationButton(symbol: "shuffle", title: "随机") { model.generate(.random) }
            KeyspaceNavigationButton(symbol: "chevron.right", title: "下一页") { model.generate(.next) }
            KeyspaceNavigationButton(symbol: "forward.end.fill", title: "末页") { model.generate(.last) }
        }
        .disabled(model.isLoading || model.selectedCoins.isEmpty)
        .panel()
    }

    @ViewBuilder
    private var status: some View {
        if model.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在本机生成地址…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let error = model.errorMessage, !model.selectedCoins.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private var results: some View {
        if let result = model.result {
            VStack(alignment: .leading, spacing: 8) {
                ResponsiveToolbar {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("派生结果")
                            .font(.title3.weight(.semibold))
                        Text("起始索引 0x\(result.index) · \(result.items.count) 条地址")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let compressed = result.wifCompressed {
                            Text("已导入 WIF · \(compressed ? "压缩" : "未压缩") · 按所选类型派生地址")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } actions: {
                    if model.balances.values.contains(where: { $0.status == .unavailable }) {
                        Button("重试失败项") { model.fetchBalances(onlyFailed: true) }
                            .disabled(model.isBalanceLoading || model.isLoading)
                    }
                    if !model.balances.isEmpty {
                        Button("强制刷新") { model.fetchBalances(forceRefresh: true) }
                            .disabled(model.isBalanceLoading || model.isLoading)
                    }
                    Button { model.fetchBalances() } label: {
                        if model.isBalanceLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("查询公开地址余额", systemImage: "network")
                        }
                    }
                    .disabled(model.isBalanceLoading || model.isLoading)
                }

                BalanceResultControls(items: result.items, balances: model.balances, pending: model.balancePending,
                                      isLoading: model.isBalanceLoading, filter: $balanceFilter)
                LazyVStack(spacing: 6) {
                    ForEach(result.items.filter { balanceFilter.includes(model.balancePending.contains($0.id) ? nil : model.balances[$0.id]) }) { item in
                        AddressResultRow(
                            item: item,
                            copiedValue: model.copiedValue,
                            balance: model.balances[item.id],
                            balancePending: model.balancePending.contains(item.id),
                            onCopy: model.copy
                        )
                    }
                }
                if let balanceError = model.balanceError {
                    Label(balanceError, systemImage: "network.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if !model.isLoading {
            VStack(spacing: 8) {
                Image(systemName: "key.viewfinder")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("等待生成")
                    .font(.title3.weight(.semibold))
                Text("选择币种并输入索引。所有计算均在本机完成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }
}


struct AddressResultRow: View {
    let item: AddressItem
    let copiedValue: String?
    var balance: BalanceRecord? = nil
    var balancePending = false
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.displayCoin)
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    .help(item.displayNetwork)
                if item.evmNetwork != nil {
                    Text(item.displayNetwork).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if !item.addressTag.isEmpty {
                    Text(item.addressTag)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if !item.path.isEmpty {
                    Text(item.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(item.path)
                        .accessibilityLabel("派生路径 \(item.path)")
                }
                Spacer(minLength: 0)
            }

            ResultColumns(trailingWidth: 230, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    addressDetails
                    privateKey
                    if !item.keyTag.isEmpty { extendedKey }
                }
                balanceDetails
            }
        }
        .padding(10)
        .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(balance?.hasNonZeroData == true ? Theme.positive.opacity(0.55) : Theme.hairline, lineWidth: 1)
        }
    }

    private var addressDetails: some View {
        ValueLine(
            label: "公开地址", value: item.address, copied: copiedValue == item.address,
            copy: { onCopy(item.address) },
            open: {
                guard let url = item.explorerURL else { return }
                NSWorkspace.shared.open(url)
            }
        )
    }

    private var balanceDetails: some View {
        Group {
            if balancePending {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在查询…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let balance {
                BalanceLine(balance: balance)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "余额")
                    Text("尚未查询").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(balance?.hasNonZeroData == true ? Theme.positive.opacity(0.07) : Theme.accent.opacity(0.045),
                    in: RoundedRectangle(cornerRadius: 9))
    }

    private var privateKey: some View {
        ValueLine(label: item.privateKeyLabel, value: item.hexKey,
                  copied: copiedValue == item.hexKey, copy: { onCopy(item.hexKey) })
    }

    private var extendedKey: some View {
        ValueLine(label: item.alternateKeyLabel, value: item.keyTag,
                  copied: copiedValue == item.keyTag, copy: { onCopy(item.keyTag) })
    }

}

/// Choose columns by the available width, so long keys wrap within their column
/// instead of forcing ViewThatFits to reject an otherwise roomy horizontal layout.
private struct ResultColumns: Layout {
    var trailingWidth: CGFloat? = nil
    var spacing: CGFloat = 20

    private func widths(_ width: CGFloat, count: Int) -> [CGFloat] {
        guard count == 2, width >= 700 else { return Array(repeating: width, count: count) }
        let right = trailingWidth ?? (width - spacing) / 2
        return [width - spacing - right, right]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let columns = widths(width, count: subviews.count)
        let heights = zip(subviews, columns).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }
        let horizontal = subviews.count == 2 && width >= 700
        return CGSize(width: width, height: horizontal ? (heights.max() ?? 0)
                      : heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = widths(bounds.width, count: subviews.count)
        let horizontal = subviews.count == 2 && bounds.width >= 700
        var point = bounds.origin
        for (view, width) in zip(subviews, columns) {
            let proposal = ProposedViewSize(width: width, height: nil)
            view.place(at: point, anchor: .topLeading, proposal: proposal)
            if horizontal { point.x += width + spacing }
            else { point.y += view.sizeThatFits(proposal).height + spacing }
        }
    }
}

struct BalanceLine: View {
    let balance: BalanceRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("余额")
                    .fixedSize()
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if balance.status == .unavailable {
                    Label("查询失败", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(balance.balance ?? "—")
                        .foregroundStyle(BalanceRecord.isNonZero(balance.balance) ? Theme.positive : Color.primary)
                        .font(.callout.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                }
            }
            if let error = balance.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if balance.status == .loaded, balance.transactionCount != nil || balance.received != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        if let transactions = balance.transactionCount { inlineStatistic("交易", value: transactions) }
                        if let received = balance.received { inlineStatistic("收到", value: received) }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 3) {
                        if let transactions = balance.transactionCount { statistic("交易数", value: transactions) }
                        if let received = balance.received { statistic("累计收到", value: received) }
                    }
                }
                .padding(.top, 2)
            }
            if let source = balance.source, let date = balance.queriedAt {
                HStack(spacing: 6) {
                    Text(source.components(separatedBy: " · ").first ?? source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(source)
                    Text(date, style: .time).fixedSize()
                    if balance.isCached { Text("缓存").foregroundStyle(Theme.accent).fixedSize() }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
    }

    private func inlineStatistic(_ title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(BalanceRecord.isNonZero(value) ? Theme.positive : Color.secondary)
                .fontWeight(BalanceRecord.isNonZero(value) ? .semibold : .regular)
                .monospaced()
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private func statistic(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 0)
            Text(value)
                .foregroundStyle(BalanceRecord.isNonZero(value) ? Theme.positive : Color.secondary)
                .fontWeight(BalanceRecord.isNonZero(value) ? .semibold : .regular)
                .monospaced()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

}

private struct ValueLine: View {
    let label: String
    let value: String
    let copied: Bool
    let copy: () -> Void
    var open: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            HStack(spacing: 2) {
                if let open {
                    Button(action: open) {
                        Image(systemName: "arrow.up.right.square").frame(width: 24, height: 20)
                    }
                    .interactiveButton(padding: 2)
                    .foregroundStyle(.secondary)
                    .help("在区块浏览器中打开公开地址")
                    .accessibilityLabel("在区块浏览器中打开公开地址")
                }
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 24, height: 20)
                }
                .interactiveButton(padding: 2)
                .foregroundStyle(copied ? Theme.positive : .secondary)
                .help(copied ? "已复制；60 秒后自动清除" : "复制\(label)")
                .accessibilityLabel(copied ? "已复制\(label)" : "复制\(label)")
            }
            .fixedSize()
        }
    }
}


struct BalanceResultControls: View {
    let items: [AddressItem]
    let balances: [String: BalanceRecord]
    let pending: Set<String>
    let isLoading: Bool
    @Binding var filter: BalanceResultFilter

    private var values: [BalanceRecord] { items.filter { !pending.contains($0.id) }.compactMap { balances[$0.id] } }
    private var completed: Int { values.count }
    private var visible: Int { items.filter { filter.includes(pending.contains($0.id) ? nil : balances[$0.id]) }.count }

    private var resultPicker: some View {
        Picker("结果筛选", selection: $filter) {
            ForEach(BalanceResultFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).frame(maxWidth: 380)
    }

    private var visibleCount: some View {
        Text("匹配地址 \(visible) / \(items.count) 条").font(.caption).foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 4) {
                Text("已完成 \(completed)/\(items.count)")
                Text("成功 \(values.filter { $0.status == .loaded }.count)")
                Text("失败 \(values.filter { $0.status == .unavailable }.count)")
                Text("有余额 \(values.filter { $0.status == .loaded && BalanceRecord.isNonZero($0.balance) }.count)")
                    .foregroundStyle(Theme.positive)
            }.font(.caption).foregroundStyle(.secondary)
            if isLoading { ProgressView(value: Double(completed), total: Double(max(1, items.count))).progressViewStyle(.linear) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { resultPicker; visibleCount.fixedSize() }
                VStack(alignment: .leading, spacing: 6) { resultPicker; visibleCount }
            }
            if visible == 0 && filter != .all {
                Text(isLoading ? "当前筛选下暂无已完成结果，查询仍在继续。" : "当前筛选下没有结果；尚未查询的条目不会当作零余额。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
