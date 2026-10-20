import AppKit
import SwiftUI

struct BTCPuzzleView: View {
    @StateObject private var model = BTCPuzzleViewModel()
    let browse: (BTCPuzzle, CoreNavigation) -> Void
    @State private var copiedAddress: String?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "BTC Puzzle", subtitle: "公开挑战 · 题目、区间与地址") {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 22))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                    if let catalog = model.catalog {
                        overview(catalog)
                        filters
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                puzzleList.frame(minWidth: 420)
                                detail.frame(width: 320)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                puzzleList
                                detail
                            }
                        }
                        HStack(spacing: 6) {
                            Text("状态快照 \(catalog.snapshotDate) · 不随余额变化自动判定已解状态")
                            Spacer()
                            Link("数据来源", destination: URL(string: "https://privatekeyfinder.io/bitcoin-puzzle")!)
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .pageContent()
            }
        }
        .navigationTitle("BTC Puzzle")
        .onChange(of: model.filter) { _ in model.reconcileSelection() }
        .onChange(of: model.searchText) { _ in model.reconcileSelection() }
        .onAppear { model.pageDidAppear() }
        .onDisappear { model.cancel() }
    }

    private func overview(_ catalog: BTCPuzzleCatalog) -> some View {
        HStack(spacing: 0) {
            metric("全部题目", value: catalog.puzzles.count, color: .primary)
            Divider().frame(height: 32)
            metric("未解 · 快照", value: catalog.puzzles.filter { !$0.solved }.count, color: Theme.accent)
            Divider().frame(height: 32)
            metric("已解 · 快照", value: catalog.puzzles.filter(\.solved).count, color: Theme.positive)
        }
        .panel()
    }

    private func metric(_ title: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(size: 25, weight: .semibold, design: .rounded)).foregroundStyle(color)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Picker("题目状态", selection: $model.filter) {
                ForEach(BTCPuzzleViewModel.Filter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            TextField("搜索编号或地址，例如 #71", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .accessibilityLabel("搜索 Puzzle 编号或地址")
        }
    }

    private var puzzleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeading(title: "题目列表")
                Spacer()
                Text("\(model.filteredPuzzles.count) 题").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if model.filteredPuzzles.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title2)
                    Text("没有匹配的题目")
                    Button("清除筛选") { model.searchText = ""; model.filter = .all }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                Table(model.filteredPuzzles, selection: $model.selectedID) {
                    TableColumn("编号") { puzzle in
                        Text("#\(puzzle.id)").font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    .width(44)
                    TableColumn("状态") { puzzle in
                        Text(puzzle.solved ? "已解" : "未解")
                            .font(.system(size: 12))
                            .foregroundStyle(puzzle.solved ? Theme.positive : Color.secondary)
                    }
                    .width(44)
                    TableColumn("目标地址") { puzzle in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(puzzle.address).font(.system(size: 12, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                            Text("\(puzzle.id) 位 · 2^\(puzzle.id - 1) 个候选")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .help(puzzle.address)
                    }
                    .width(min: 130, ideal: 190)
                    TableColumn("余额") { puzzle in
                        Text(model.fetchingIDs.contains(puzzle.id) ? "查询中…" : model.balances[puzzle.id].map { $0.status == .loaded ? ($0.balance ?? "—") : "不可用" } ?? "—")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(BalanceRecord.isNonZero(model.balances[puzzle.id]?.balance) ? Theme.positive : Color.secondary)
                            .fontWeight(BalanceRecord.isNonZero(model.balances[puzzle.id]?.balance) ? .semibold : .regular)
                            .lineLimit(1)
                            .help(model.balances[puzzle.id]?.balance ?? "进入页面后自动查询公开地址余额")
                    }
                    .width(min: 65, ideal: 95)
                }
                .frame(height: min(400, max(160, CGFloat(model.filteredPuzzles.count) * 40 + 32)))
            }
        }
        .panel()
    }

    @ViewBuilder
    private var detail: some View {
        if let puzzle = model.selectedPuzzle {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeading(title: "Puzzle #\(puzzle.id)")
                    Spacer()
                    Text(puzzle.solved ? "快照已解" : "快照未解")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(puzzle.solved ? Theme.positive : Theme.accent)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(title: "BTC 目标地址 · Legacy 压缩公钥")
                    Text(puzzle.address)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(puzzle.address, forType: .string)
                            copiedAddress = puzzle.address
                        } label: {
                            Label(copiedAddress == puzzle.address ? "已复制" : "复制地址", systemImage: "doc.on.doc")
                        }
                        Spacer()
                        Link(destination: Coin.BTC.explorerURL(for: puzzle.address)!) {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .help("在区块浏览器中查看公开地址")
                    }
                    .controlSize(.small)
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    FieldLabel(title: "私钥区间 · \(puzzle.id) 位")
                    bound("起点（含）", value: puzzle.lowerBound)
                    bound("终点（含）", value: puzzle.upperBound)
                    Text("范围内共 2^\(puzzle.id - 1) 个候选")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button { browse(puzzle, .first) } label: {
                        Label("浏览区间", systemImage: "key.horizontal").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { browse(puzzle, .random) } label: { Image(systemName: "shuffle") }
                        .help("在此题范围内安全随机浏览")
                        .accessibilityLabel("随机浏览此题区间")
                }
                .controlSize(.regular)
                Divider()
                balance(puzzle)
            }
            .panel()
        } else {
            Text("选择题目查看详情")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
                .panel()
        }
    }

    private func bound(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text("0x\(value)").font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func balance(_ puzzle: BTCPuzzle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                FieldLabel(title: "当前余额")
                Spacer()
                if model.fetchingIDs.contains(puzzle.id) { ProgressView().controlSize(.small) }
                Button { model.refreshBalance() } label: { Image(systemName: "arrow.clockwise") }
                    .help("仅查询此公开地址的余额")
                    .accessibilityLabel("刷新 Puzzle 目标地址余额")
                    .disabled(model.fetchingIDs.contains(puzzle.id))
            }
            if let record = model.balances[puzzle.id] {
                BalanceLine(balance: record)
            } else {
                Text("尚未查询").foregroundStyle(.secondary)
            }
            if let error = model.balanceErrors[puzzle.id] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
            }
        }
    }
}
