import AppKit
import SwiftUI

struct CalculatorOperation: Identifiable, Hashable {
    let id: String
    let category: CalculatorCategory
    let title: String
    let detail: String
    var isText: Bool { ["ascii-to-hex", "sha256-text"].contains(id) }
    var isRandom: Bool { id == "random-key" }
    var permitsEmpty: Bool { isText || ["sha256", "ripemd160", "hash160", "keccak256", "double-sha256", "base58-enc", "base58check-enc"].contains(id) }
    var needsPassphrase: Bool { category == .bip38 }
    var placeholder: String {
        if isRandom { return "无需输入，点击生成即可" }
        if isText { return "输入完整文本，空白和换行将原样参与计算" }
        if id.hasPrefix("wif-") { return "Bitcoin 主网 WIF（5 / K / L 开头）" }
        switch category {
        case .privateKey, .wif: return "HEX 私钥（例如 1）或 Bitcoin 主网 WIF"
        case .publicKey: return "02 / 03 开头的压缩公钥，或 04 开头的未压缩公钥"
        case .bip38: return id == "bip38-decrypt" ? "6P 开头的 BIP38 密文" : "HEX 私钥或 Bitcoin 主网 WIF"
        case .address: return id.hasPrefix("hash160-") ? "20 字节 Hash160（40 位 HEX）" : "BTC 主网地址或 EVM 地址（仅校验）"
        case .base58: return id.hasSuffix("-dec") ? "Base58 / Base58Check 字符串" : "十六进制字节"
        case .bech32: return id.hasSuffix("-dec") ? "BTC 主网 bc1 地址" : "20 或 32 字节 HEX 载荷"
        case .basic: return "输入数字、HEX 字节或文本"
        default: return "输入十六进制字节；EIP-55 操作接受 20 字节地址"
        }
    }
    static let all: [Self] = [
        .init(id: "dec-to-hex", category: .basic, title: "十进制 → HEX", detail: "非负整数转换为十六进制；支持大整数。"),
        .init(id: "hex-to-dec", category: .basic, title: "HEX → 十进制", detail: "整数转换；支持 0x 前缀与奇数位 HEX。"),
        .init(id: "bin-to-hex", category: .basic, title: "二进制 → HEX", detail: "只接受 0 和 1，保留数值。"),
        .init(id: "hex-to-bin", category: .basic, title: "HEX → 二进制", detail: "每个 HEX 字符展开为 4 位，保留前导零。"),
        .init(id: "ascii-to-hex", category: .basic, title: "UTF-8 文本 → HEX", detail: "按 UTF-8 编码，保留空格、换行与中文。"),
        .init(id: "hex-to-ascii", category: .basic, title: "HEX → UTF-8 文本", detail: "严格检查 UTF-8 字节，不以乱码替代非法输入。"),
        .init(id: "priv-to-all", category: .privateKey, title: "私钥 → 全部格式", detail: "一次查看 HEX、两种 WIF、公钥、BTC 五种地址与 EVM 地址。"),
        .init(id: "priv-to-pub-c", category: .privateKey, title: "私钥 → 压缩公钥", detail: "返回 33 字节 secp256k1 公钥。"),
        .init(id: "priv-to-pub-u", category: .privateKey, title: "私钥 → 未压缩公钥", detail: "返回 65 字节 secp256k1 公钥。"),
        .init(id: "priv-to-addr-c", category: .privateKey, title: "私钥 → Legacy(c)", detail: "使用压缩公钥派生 BTC 主网 P2PKH 地址。"),
        .init(id: "priv-to-addr-u", category: .privateKey, title: "私钥 → Legacy(u)", detail: "使用未压缩公钥派生 BTC 主网 P2PKH 地址。"),
        .init(id: "priv-to-addr-evm", category: .privateKey, title: "私钥 → EVM 地址", detail: "Keccak-256 派生并生成 EIP-55 校验地址。"),
        .init(id: "pub-compress", category: .publicKey, title: "压缩公钥", detail: "验证曲线点，返回 02 / 03 开头的公钥。"),
        .init(id: "pub-decompress", category: .publicKey, title: "展开公钥", detail: "验证曲线点，返回 04 开头的公钥。"),
        .init(id: "pub-to-addr", category: .publicKey, title: "公钥 → Legacy 地址", detail: "沿用输入公钥的压缩或未压缩格式。"),
        .init(id: "pub-to-addr-evm", category: .publicKey, title: "公钥 → EVM 地址", detail: "压缩公钥先还原曲线点，再派生 EIP-55 地址。"),
        .init(id: "pub-to-hash160", category: .publicKey, title: "公钥 → Hash160", detail: "对输入公钥的序列化字节计算 SHA-256 + RIPEMD-160。"),
        .init(id: "pub-validate", category: .publicKey, title: "校验公钥", detail: "检查长度、前缀及 secp256k1 曲线点。"),
        .init(id: "priv-to-wif-c", category: .wif, title: "私钥 → WIF(c)", detail: "Bitcoin 主网压缩格式，K / L 开头。"),
        .init(id: "priv-to-wif-u", category: .wif, title: "私钥 → WIF(u)", detail: "Bitcoin 主网未压缩格式，5 开头。"),
        .init(id: "wif-to-priv", category: .wif, title: "WIF → HEX 私钥", detail: "校验网络、校验和、压缩标记与私钥范围。"),
        .init(id: "wif-validate", category: .wif, title: "校验 WIF", detail: "显示主网 WIF 压缩属性及对应 Legacy 地址。"),
        .init(id: "bip38-encrypt", category: .bip38, title: "加密私钥", detail: "非 EC-multiply BIP38。WIF 保留压缩属性；HEX 使用下方选项。"),
        .init(id: "bip38-decrypt", category: .bip38, title: "解密私钥", detail: "支持 0x0142 非 EC-multiply 格式；验证口令后输出 WIF、HEX 和地址。"),
        .init(id: "hash160-to-addr", category: .address, title: "Hash160 → Legacy", detail: "输入 20 字节公钥哈希，编码为 BTC 主网 P2PKH。"),
        .init(id: "hash160-to-segwit", category: .address, title: "Hash160 → SegWit", detail: "输入 20 字节压缩公钥哈希，编码为 BTC 主网 P2WPKH。"),
        .init(id: "addr-to-hash160", category: .address, title: "地址 → 载荷", detail: "识别公钥哈希、脚本哈希和 witness program，显示类型与长度。"),
        .init(id: "addr-validate", category: .address, title: "校验 BTC / EVM 地址", detail: "校验 BTC 主网地址；混合大小写 EVM 地址须通过 EIP-55。"),
        .init(id: "sha256", category: .hash, title: "SHA-256 · HEX", detail: "对 HEX 表示的原始字节计算 SHA-256。"),
        .init(id: "sha256-text", category: .hash, title: "SHA-256 · 文本", detail: "对完整 UTF-8 文本计算摘要，保留首尾空白和换行。"),
        .init(id: "ripemd160", category: .hash, title: "RIPEMD-160", detail: "输入 HEX 字节，输出 20 字节摘要。"),
        .init(id: "hash160", category: .hash, title: "Hash160", detail: "RIPEMD160(SHA256(bytes))，输入为 HEX 字节。"),
        .init(id: "keccak256", category: .hash, title: "Keccak-256", detail: "Ethereum 使用的 Keccak，区别于 NIST SHA3-256。"),
        .init(id: "double-sha256", category: .hash, title: "双 SHA-256", detail: "SHA256(SHA256(bytes))，输入为 HEX 字节。"),
        .init(id: "base58-enc", category: .base58, title: "Base58 编码", detail: "输入 HEX 字节，保留前导零字节。"),
        .init(id: "base58-dec", category: .base58, title: "Base58 解码", detail: "返回完整原始 HEX 字节，不校验校验和。"),
        .init(id: "base58check-enc", category: .base58, title: "Base58Check 编码", detail: "输入含版本字节的完整 HEX 载荷，自动附加校验和。"),
        .init(id: "base58check-dec", category: .base58, title: "Base58Check 解码", detail: "校验后返回含版本字节的 HEX 载荷。"),
        .init(id: "bech32-enc", category: .bech32, title: "Bech32 · SegWit 编码", detail: "20 字节公钥哈希 → bc1q；固定 BTC 主网 v0。"),
        .init(id: "bech32-dec", category: .bech32, title: "Bech32 · SegWit 解码", detail: "检查主网、版本、校验和、载荷长度与填充。"),
        .init(id: "bech32m-enc", category: .bech32, title: "Bech32m · v1 编码", detail: "32 字节输出公钥 → bc1p；仅编码，不执行 Taproot tweak。"),
        .init(id: "bech32m-dec", category: .bech32, title: "Bech32m · v1 解码", detail: "检查 BTC 主网 v1 地址并显示 32 字节载荷。"),
        .init(id: "reverse-bytes", category: .utility, title: "反转字节", detail: "按字节反转 HEX，不是反转字符。"),
        .init(id: "pad-hex", category: .utility, title: "补齐 64 位 HEX", detail: "支持单字符 HEX；左补零，超过 32 字节时报错。"),
        .init(id: "checksum-evm", category: .utility, title: "生成 EIP-55 地址", detail: "20 字节地址生成校验大小写；不改变地址数值。"),
        .init(id: "random-key", category: .utility, title: "随机私钥", detail: "使用系统密码学随机源，生成 1 ≤ d < n 的 32 字节私钥。"),
    ]
}

enum CalculatorCategory: String, CaseIterable, Identifiable {
    case basic, privateKey, publicKey, wif, bip38, address, hash, base58, bech32, utility
    var id: Self { self }
    var title: String {
        switch self {
        case .basic: "基础转换"
        case .privateKey: "私钥"
        case .publicKey: "公钥"
        case .wif: "WIF"
        case .bip38: "BIP38"
        case .address: "地址"
        case .hash: "哈希"
        case .base58: "Base58"
        case .bech32: "Bech32"
        case .utility: "辅助工具"
        }
    }
    var operations: [CalculatorOperation] { CalculatorOperation.all.filter { $0.category == self } }
}

struct CalculatorOutput: Codable { let output: String }

/// Separate from wallet derivation so expensive scrypt does not block that actor.
actor CalculatorCoreClient {
    static let shared = CalculatorCoreClient()
    struct Request: Encodable {
        let operation: String
        let input: String
        let passphrase: String
        let compressed: Bool
    }
    func calculate(operation: String, input: String, passphrase: String = "", compressed: Bool = true) throws -> String {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Request(operation: operation, input: input, passphrase: passphrase, compressed: compressed))
        let raw = String(decoding: data, as: UTF8.self)
        let response = raw.withCString { pointer -> String in
            guard let result = AllKeyCalculate(UnsafeMutablePointer(mutating: pointer)) else { return "" }
            defer { AllKeyFree(result) }
            return String(cString: result)
        }
        try Task.checkCancellation()
        let value = try JSONDecoder().decode(CoreEnvelope<CalculatorOutput>.self, from: Data(response.utf8))
        guard value.ok, let output = value.data else {
            throw value.error ?? CoreAPIError(code: "calculator_error", message: "计算失败")
        }
        return output.output
    }
}

struct CalculatorRow: Identifiable {
    let id = UUID()
    let line: Int
    let output: String?
    let error: String?
}

@MainActor
final class CalculatorViewModel: ObservableObject {
    @Published var category: CalculatorCategory = .basic {
        didSet { if oldValue != category { operation = category.operations[0] } }
    }
    @Published var operation = CalculatorOperation.all[0] { didSet { if oldValue != operation { invalidate() } } }
    @Published var input = "" { didSet { if oldValue != input { invalidate() } } }
    @Published var passphrase = "" { didSet { if oldValue != passphrase { invalidate() } } }
    @Published var compressed = true { didSet { if oldValue != compressed { invalidate() } } }
    @Published var batch = false { didSet { if oldValue != batch { invalidate() } } }
    @Published private(set) var rows: [CalculatorRow] = []
    @Published private(set) var isRunning = false
    @Published private(set) var total = 0
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    var usesBatch: Bool { batch && !operation.isText && !operation.isRandom }
    var canRun: Bool { !isRunning && (operation.isRandom || operation.permitsEmpty || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && (!operation.needsPassphrase || !passphrase.isEmpty) }
    var successes: Int { rows.filter { $0.output != nil }.count }
    var outputText: String { rows.compactMap(\.output).joined(separator: "\n") }

    func invalidate() {
        task?.cancel(); requestID = UUID(); isRunning = false
        rows = []; total = 0; message = nil
    }
    func run() {
        guard canRun else { return }
        invalidate()
        let operation = operation, text = input, password = passphrase, compressed = compressed
        guard text.utf8.count <= 1024 * 1024, password.utf8.count <= 4096 else { message = "输入最多 1 MiB，口令最多 4096 字节"; return }
        let entries: [(Int, String)] = usesBatch
            ? text.components(separatedBy: .newlines).enumerated().filter { !$0.element.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { ($0.offset + 1, $0.element) }
            : [(1, text)]
        let limit = operation.needsPassphrase ? 4 : 200
        guard !entries.isEmpty, entries.count <= limit else { message = "本次最多处理 \(limit) 个非空行"; return }
        total = entries.count; isRunning = true
        let id = UUID(); requestID = id
        task = Task { [weak self] in
            for (line, value) in entries {
                guard !Task.isCancelled else { return }
                let row: CalculatorRow
                do {
                    let output = try await CalculatorCoreClient.shared.calculate(operation: operation.id, input: value,
                        passphrase: password, compressed: compressed)
                    row = CalculatorRow(line: line, output: output, error: nil)
                } catch is CancellationError { return }
                catch { row = CalculatorRow(line: line, output: nil, error: error.localizedDescription) }
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.rows.append(row)
            }
            guard let self, self.requestID == id else { return }
            self.isRunning = false
        }
    }
    func stop() {
        task?.cancel(); requestID = UUID(); isRunning = false
        message = "已停止等待；正在执行的单次计算会在后台结束，结果不会回写。"
    }
    func clear() { invalidate(); input = ""; passphrase = "" }
}

struct CryptoCalculatorView: View {
    @StateObject private var model = CalculatorViewModel()
    @State private var copiedText: String?
    @State private var showsPassphrase = false

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "Crypto Calculator", subtitle: "密钥、地址与字节转换") {
                Label("本地计算", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(Theme.positive)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    operations
                    CalculatorWorkspaceLayout {
                        inputPanel
                        outputPanel
                    }
                }.pageContent()
            }
        }
        .navigationTitle("Crypto Calculator")
        .onDisappear { model.clear(); copiedText = nil; showsPassphrase = false }
        .onChange(of: model.input) { _ in copiedText = nil }
        .onChange(of: model.operation) { _ in copiedText = nil }
    }

    private var operations: some View {
        VStack(alignment: .leading, spacing: 10) {
            ParameterFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(CalculatorCategory.allCases) { category in
                    Button { model.category = category } label: {
                        Text(category.title).font(.system(size: 12, weight: model.category == category ? .semibold : .regular))
                            .fixedSize().padding(.horizontal, 9).padding(.vertical, 6)
                            .foregroundStyle(model.category == category ? Theme.accent : Color.secondary)
                            .background(model.category == category ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    }
                    .interactiveButton()
                    .accessibilityAddTraits(model.category == category ? [.isSelected] : [])
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(model.category.operations) { operation in
                    Button { model.operation = operation } label: {
                        HStack(spacing: 6) {
                            Text(operation.title).font(.system(size: 12, weight: .medium))
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                            if model.operation == operation { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .foregroundStyle(model.operation == operation ? Theme.accent : Color.primary)
                        .background(model.operation == operation ? Theme.accent.opacity(0.09) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).stroke(model.operation == operation ? Theme.accent.opacity(0.45) : Theme.hairline) }
                    }
                    .interactiveButton()
                    .help(operation.detail)
                    .accessibilityAddTraits(model.operation == operation ? [.isSelected] : [])
                }
            }
            Text(model.operation.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(model.isRunning)
        .panel()
    }

    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResponsiveToolbar {
                Text("输入").font(.system(size: 15, weight: .semibold))
            } actions: {
                Button("粘贴") { if let value = NSPasteboard.general.string(forType: .string) { model.input = value } }
                    .disabled(model.isRunning || model.operation.isRandom)
                Button("清空") { model.clear() }
            }
            if model.operation.isRandom {
                VStack(spacing: 10) {
                    Image(systemName: "shuffle").font(.title2).foregroundStyle(Theme.accent)
                    Text("无需输入").font(.callout.weight(.medium))
                    Text("生成一个 32 字节的随机私钥").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 164)
                .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $model.input)
                        .font(.system(size: 13, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(5)
                        .disabled(model.isRunning)
                        .accessibilityLabel(model.operation.placeholder)
                    if model.input.isEmpty {
                        Text(model.operation.placeholder).font(.system(size: 13))
                            .foregroundStyle(.tertiary).padding(10).allowsHitTesting(false)
                    }
                }
                .frame(height: 164)
                .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline) }
            }
            if !model.operation.isRandom && !model.operation.isText {
                Toggle("按行批量处理", isOn: $model.batch).toggleStyle(.checkbox)
                    .font(.caption).disabled(model.isRunning)
                if model.usesBatch {
                    Text(model.operation.needsPassphrase ? "最多 4 行；逐行独立处理，跳过空行。" : "最多 200 行；逐行独立处理，跳过空行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.operation.isText {
                Text("按完整 UTF-8 文本处理，保留空白和换行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.operation.needsPassphrase {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "BIP38 口令")
                    HStack(spacing: 8) {
                        Group {
                            if showsPassphrase {
                                TextField("口令仅在本次计算中使用", text: $model.passphrase)
                            } else {
                                SecureField("口令仅在本次计算中使用", text: $model.passphrase)
                            }
                        }.textFieldStyle(.roundedBorder)
                        Button { showsPassphrase.toggle() } label: {
                            Image(systemName: showsPassphrase ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(showsPassphrase ? "隐藏口令" : "显示口令")
                        .accessibilityLabel(showsPassphrase ? "隐藏 BIP38 口令" : "显示 BIP38 口令")
                    }.disabled(model.isRunning)
                    if model.operation.id == "bip38-encrypt" {
                        Toggle("HEX 输入使用压缩公钥", isOn: $model.compressed)
                            .toggleStyle(.checkbox).font(.caption).disabled(model.isRunning)
                        Text("WIF 输入沿用其压缩属性。仅支持非 EC-multiply BIP38。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("仅支持 0x0142 非 EC-multiply 格式。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                Text("BTC 主网 · EVM 通用地址").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if model.isRunning {
                    Button("停止等待") { model.stop() }
                } else {
                    Button(model.operation.isRandom ? "生成私钥" : "计算") { model.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canRun)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }.panel()
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResponsiveToolbar {
                Text("结果").font(.system(size: 15, weight: .semibold))
            } actions: {
                Button(copiedText == model.outputText && model.successes > 0 ? "已复制" : model.rows.contains(where: { $0.error != nil }) ? "复制成功项" : "复制全部") { copy(model.outputText) }
                    .disabled(model.isRunning || model.successes == 0)
            }
            if model.isRunning {
                ProgressView(value: Double(model.rows.count), total: Double(max(1, model.total)))
                Text("正在本机计算 \(model.rows.count) / \(model.total)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "equal.square").font(.title2)
                    Text(model.isRunning ? "正在处理…" : "选择操作并点击计算")
                        .font(.callout)
                    Text("修改输入或操作后，旧结果会自动清除。")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 164)
                .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 8))
            } else {
                HStack(spacing: 10) {
                    Text("成功 \(model.successes)").foregroundStyle(Theme.positive)
                    Text("失败 \(model.rows.count - model.successes)").foregroundStyle(model.successes == model.rows.count ? Color.secondary : .orange)
                }.font(.caption)
                if model.outputText.count > 600 || model.rows.count > 6 {
                    ScrollView { outputRows }.frame(height: 460)
                } else {
                    outputRows
                }
            }
        }.panel()
    }

    private var outputRows: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(model.rows) { row in
                VStack(alignment: .leading, spacing: 7) {
                    if model.usesBatch { Text("第 \(row.line) 行").font(.caption).foregroundStyle(.secondary) }
                    if let error = row.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    } else if let output = row.output {
                        Text(output.isEmpty ? "（空结果）" : String(output.prefix(8192)))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if output.count > 8192 {
                            Text("仅预览前 8192 个字符；复制可获取完整结果。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ParameterFlowLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                            Button(copiedText == output ? "已复制" : "复制") { copy(output) }
                            Button("作为输入") { model.input = output }
                        }.controlSize(.small).disabled(model.isRunning)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedText = value
    }
}

/// Use the available width rather than the intrinsic width of long HEX output.
private struct CalculatorWorkspaceLayout: Layout {
    private func measurements(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGFloat, Bool, [CGSize]) {
        let width = max(0, proposal.width ?? 900)
        let horizontal = width >= 820
        let column = horizontal ? max(0, (width - 12) / 2) : width
        return (width, horizontal, subviews.map { $0.sizeThatFits(.init(width: column, height: nil)) })
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, horizontal, sizes) = measurements(proposal, subviews)
        return CGSize(width: width, height: horizontal ? sizes.map(\.height).max() ?? 0 : sizes.map(\.height).reduce(0, +) + CGFloat(max(0, sizes.count - 1)) * 12)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (_, horizontal, sizes) = measurements(.init(width: bounds.width, height: nil), subviews)
        let column = horizontal ? max(0, (bounds.width - 12) / 2) : bounds.width
        var offset: CGFloat = 0
        for index in subviews.indices {
            subviews[index].place(at: CGPoint(x: bounds.minX + (horizontal ? offset : 0), y: bounds.minY + (horizontal ? 0 : offset)), anchor: .topLeading,
                                 proposal: .init(width: column, height: sizes[index].height))
            offset += (horizontal ? column : sizes[index].height) + 12
        }
    }
}
