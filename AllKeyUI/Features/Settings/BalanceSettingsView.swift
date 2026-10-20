import AppKit
import SwiftUI

struct BalanceSettingsView: View {
    @AppStorage(ThemeAppearance.storageKey) private var appearance: ThemeAppearance = .system
    @AppStorage(BalanceSettings.autoRefreshStorageKey) private var autoRefreshBalances = false
    @State private var configurationMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            FeatureHeader(title: "设置", subtitle: "外观偏好与余额查询服务") { EmptyView() }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "外观", subtitle: "选择应用的显示模式，立即生效并自动保存")
                        Picker("显示模式", selection: $appearance) {
                            ForEach(ThemeAppearance.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityLabel("显示模式")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "余额查询", subtitle: "控制地址生成与翻页后的查询行为")
                        Toggle("自动刷新地址余额", isOn: $autoRefreshBalances)
                            .toggleStyle(.checkbox)
                        Text("开启后，私钥库、BIP39 和 Electrum 在生成、搜索或翻页得到新地址后，自动请求已配置的余额 API。自动查询会绕过余额缓存，并消耗服务额度。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panel()

                    SectionHeading(title: "服务配置", subtitle: "查看已保存的平台；展开币种后编辑主服务与备用服务")
                    DisclosureGroup("配置文件说明") {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("仅发送公开地址", systemImage: "lock.shield")
                                .font(.headline)
                            Text("服务地址和 API Key 保存在本机 JSON 配置文件，不访问钥匙串。API Key 以明文保存，文件仅当前用户可读写。查询时只发送当前页生成的公开地址，筛选只改变显示；成功结果缓存 60 秒；可强制刷新或仅重试失败地址。备用服务会在主服务失败后自动尝试，不同平台的额度和可用性取决于你的账号。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(BalanceSettings.configurationURL.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button("打开配置目录") {
                                do {
                                    try BalanceSettings.prepareConfigurationDirectory()
                                    NSWorkspace.shared.open(BalanceSettings.configurationURL.deletingLastPathComponent())
                                } catch { configurationMessage = error.localizedDescription }
                            }
                            if let error = BalanceSettings.configurationError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Text("旧钥匙串中的 Key 不会自动迁移，请在对应服务中重新填写。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let configurationMessage {
                                Text(configurationMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }.panel()

                    DisclosureGroup("自定义 EVM 网络") {
                        EVMNetworksEditor().padding(.top, 8)
                    }.panel()

                    ForEach(Coin.allCases) { coin in
                        BalanceServiceSection(coin: coin)
                    }
                }
                .pageContent()
            }
        }
        .navigationTitle("设置")
    }


}

private struct BalanceServiceSection: View {
    let coin: Coin
    @State private var expanded = false
    @State private var revision = 0

    private func summary(_ revision: Int) -> String {
        let primary = BalanceSettings.endpoint(for: coin, role: .primary)?.provider.title ?? "未配置"
        let backup = BalanceSettings.endpoint(for: coin, role: .backup)?.provider.title ?? "未配置"
        return "主服务：\(primary) · 备用：\(backup)"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                BalanceEndpointEditor(coin: coin, role: .primary) { revision += 1 }
                DisclosureGroup("备用服务（主服务失败时自动切换）") {
                    BalanceEndpointEditor(coin: coin, role: .backup) { revision += 1 }
                        .padding(.top, 8)
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(coin.rawValue) · \(coin.name)").font(.callout.weight(.semibold))
                Text(summary(revision)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .panel()
    }
}

private struct BalanceEndpointEditor: View {
    let coin: Coin
    let role: BalanceServiceRole
    let onConfigurationChange: () -> Void
    @State private var provider: BalanceProvider
    @State private var address: String
    @State private var apiKey: String
    @State private var isConfigured: Bool
    @State private var message: String?
    @State private var isError = false

    init(coin: Coin, role: BalanceServiceRole, onConfigurationChange: @escaping () -> Void = {}) {
        self.coin = coin
        self.role = role
        self.onConfigurationChange = onConfigurationChange
        let stored = BalanceSettings.endpoint(for: coin, role: role)
        let selected = stored?.provider ?? BalanceProvider.choices(for: coin)[0]
        _provider = State(initialValue: selected)
        _address = State(initialValue: stored?.url ?? selected.defaultURL(for: coin))
        _apiKey = State(initialValue: BalanceSettings.apiKey(for: coin, role: role) ?? "")
        _isConfigured = State(initialValue: stored != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ResponsiveToolbar {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(coin.rawValue) · \(coin.name) · \(role.title)")
                        .font(.title3.weight(.semibold))
                    Text(isConfigured ? "已配置" : "尚未配置")
                        .font(.caption)
                        .foregroundStyle(isConfigured ? Theme.positive : .secondary)
                }
            } actions: {
                Picker("平台", selection: $provider) {
                    ForEach(BalanceProvider.choices(for: coin)) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .frame(width: 250)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("服务地址")
                    .frame(width: 72, alignment: .leading)
                TextField("HTTPS URL", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(coin.rawValue) 服务地址")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("API Key")
                    .frame(width: 72, alignment: .leading)
                SecureField([.solanaRPC, .evmRPC].contains(provider) ? "可选；URL 中可使用 {API_KEY}" : "留空表示无需密钥", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(coin.rawValue) API Key")
            }

            ResponsiveToolbar {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } actions: {
                if isConfigured {
                    Button("移除配置") { remove() }
                        .buttonStyle(.borderless)
                }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : Theme.positive)
            }
        }
        .panel()
        .onChange(of: provider) { newValue in
            address = newValue.defaultURL(for: coin)
            apiKey = ""
            message = nil
        }
    }

    private var hint: String {
        switch provider {
        case .blockchain: "BTC 批量余额；无需 Key，每批最多 100 个地址"
        case .blockcypher: "DOGE 地址余额；Token 可选，免费额度有限"
        case .blockchair: "基础 URL；Key 可选，查询余额按平台额度计费"
        case .etherscan: "Etherscan V2 API；ETH 与 BSC 使用同一账号的 Key"
        case .evmRPC: "\(coin == .ETH ? "Ethereum" : "BNB Chain") 主网 JSON-RPC；使用 eth_getBalance，可用 {API_KEY} 占位"
        case .tronGrid: "主网 TronGrid；需要 API Key"
        case .solanaRPC: "主网 JSON-RPC；若服务商把 Key 放在 URL，可用 {API_KEY} 占位"
        case .chainz: "Litecoin 余额接口；需要 Chainz API Key"
        case .okLink: "Dogecoin 地址摘要；需要 OKLink Access Key"
        }
    }

    private func save() {
        do {
            try BalanceSettings.save(BalanceEndpoint(provider: provider, url: address.trimmingCharacters(in: .whitespacesAndNewlines)), apiKey: apiKey, for: coin, role: role)
            isConfigured = true
            isError = false
            message = "已保存"
            onConfigurationChange()
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }

    private func remove() {
        do {
            try BalanceSettings.remove(for: coin, role: role)
            isConfigured = false
            onConfigurationChange()
            apiKey = ""
            isError = false
            message = "配置已移除"
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}

private struct EVMNetworksEditor: View {
    @State private var networks = BalanceSettings.evmNetworks
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: "自定义 EVM 网络", subtitle: "勾选 ETH 派生时，附加已启用网络；查询主币余额")
            Text("每个网络可配置链 ID、RPC、主币精度和浏览器。地址沿用 ETH 派生路径；查询前校验 RPC 的链 ID。编辑后保存全部网络。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($networks) { $network in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Toggle("启用网络", isOn: $network.enabled).toggleStyle(.checkbox)
                        Spacer()
                        Button("移除") { networks.removeAll { $0.id == network.id } }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], alignment: .leading, spacing: 8) {
                        field("网络名称", text: $network.name, prompt: "例如 My EVM Network")
                        field("链 ID（十进制）", text: $network.chainID, prompt: "正整数")
                        field("主币符号", text: $network.symbol, prompt: "ETH")
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel(title: "主币精度")
                            Stepper("\(network.decimals)", value: $network.decimals, in: 0...36)
                        }
                    }
                    field("RPC 地址", text: $network.rpcURL, prompt: "https://…，可用 {API_KEY} 占位")
                    HStack(alignment: .bottom, spacing: 10) {
                        field("浏览器网站（可选）", text: $network.explorerURL, prompt: "https://…，自动附加 /address/地址")
                        VStack(alignment: .leading, spacing: 4) {
                            FieldLabel(title: "API Key（可选）")
                            SecureField("仅在 URL 占位处使用", text: $network.apiKey).textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(10).background(Theme.raisedPanel, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button("添加网络") { networks.append(EVMNetwork()) }
                Button("保存全部网络") {
                    do {
                        try BalanceSettings.saveEVMNetworks(networks)
                        failed = false; message = "网络配置已保存；重新生成地址后应用"
                    } catch { failed = true; message = error.localizedDescription }
                }.buttonStyle(.borderedProminent)
                Button("重新载入") { networks = BalanceSettings.evmNetworks; message = nil }
            }
            if let message { Text(message).font(.caption).foregroundStyle(failed ? Color.red : Theme.positive) }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(title: title)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
}
