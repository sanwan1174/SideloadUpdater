import SwiftUI
import UniformTypeIdentifiers

private enum UpdaterDestination: Hashable {
    case app(String), inventory, settings, region, pending
}

@MainActor
struct ContentView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: UpdaterModel
    @State private var path: [UpdaterDestination] = []
    @State private var showsPairing = false
    @State private var notifiesPairingCode = false
    @State private var showsPairingImporter = false
    @State private var pairingFileError = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.country != nil {
                    dashboard
                } else if model.lastScan == nil {
                    connectionSetup
                } else if !model.hasTracking {
                    signatureSetup
                } else {
                    regionSetup
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: UpdaterDestination.settings) {
                        Label("设置", systemImage: "gearshape")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .navigationDestination(for: UpdaterDestination.self) { destination in
                switch destination {
                case .app(let bundleID):
                    AppDetailView(model: model, bundleID: bundleID) {
                        if model.country == nil, model.hasTracking { path.removeAll() }
                    }
                case .inventory:
                    InventoryView(model: model)
                case .settings:
                    SettingsView(model: model) { showsPairingImporter = true }
                case .region:
                    RegionView(model: model)
                case .pending:
                    PendingAppsView(model: model)
                }
            }
        }
        .fileImporter(isPresented: $showsPairingImporter, allowedContentTypes: [.data]) { result in
            switch result {
            case .success(let url) where url.pathExtension.lowercased() != "ipa":
                Task { await model.pair(recordAt: url) }
            case .failure(let error) where (error as? CocoaError)?.code == .userCancelled:
                break
            default:
                pairingFileError = true
            }
        }
        .alert("无法导入配对文件", isPresented: $pairingFileError) {
            Button("好", role: .cancel) {}
        } message: {
            Text("请选择已为此 iPhone 授权的 RPPairing 配对文件。")
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await model.refreshIfNeededOnActivation() }
        }
    }

    private var dashboard: some View {
        let tracked = model.trackedApps
        let updates = tracked.filter { model.row(for: $0).state == .update }
        let others = tracked.filter { model.row(for: $0).state != .update }
        return List {
            Section {
                statusBar
                if case .offline(let message) = model.connection {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if tracked.isEmpty {
                Section {
                    Text("暂无跟踪的 App。可从已安装的 App 选择签名或逐项跟踪。")
                        .foregroundStyle(.secondary)
                }
            }
            if !updates.isEmpty {
                Section(localized("有更新（%lld）", Int64(updates.count))) {
                    ForEach(updates) { trackedLink($0) }
                }
            }
            if !others.isEmpty {
                Section(localized(updates.isEmpty ? "全部 App（%lld）" : "其他（%lld）", Int64(others.count))) {
                    ForEach(others) { trackedLink($0) }
                }
            }
            Section {
                if !model.pendingApps.isEmpty {
                    NavigationLink(value: UpdaterDestination.pending) {
                        LabeledContent("待确认") {
                            Text(model.pendingApps.count, format: .number.locale(locale))
                        }
                    }
                }
                NavigationLink("查看已安装的 App", value: UpdaterDestination.inventory)
            }
        }
        .navigationTitle(UpdaterModel.pairingHostName)
        .refreshable { await model.refresh() }
    }

    private func trackedLink(_ app: DeviceApp) -> some View {
        NavigationLink(value: UpdaterDestination.app(app.id)) {
            TrackedAppRow(app: app, row: model.row(for: app))
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if model.isPairing {
                    Text("正在等待设备配对")
                } else if model.isRefreshing {
                    Text(refreshTitle)
                } else {
                    switch model.connection {
                    case .connected:
                        Label("设备已连接", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .offline:
                        Label("设备连接失败", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    case .idle:
                        Label("等待连接", systemImage: "iphone")
                            .foregroundStyle(.secondary)
                    }
                }
                if let date = model.lastScan {
                    Text(localized("上次扫描 %@", date.formatted(.relative(presentation: .named).locale(locale))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            Spacer()
            if model.isRefreshing || model.isPairing {
                ProgressView()
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("检查更新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var refreshTitle: LocalizedStringKey {
        model.lastScan == nil ? "正在读取设备清单" : "正在检查更新"
    }

    @ViewBuilder
    private var connectionStatus: some View {
        if model.isPairing {
            ProgressView("正在等待设备配对")
        } else if model.isRefreshing {
            ProgressView(refreshTitle)
        }
        switch model.connection {
        case .idle:
            if !model.isRefreshing && !model.isPairing {
                Label("等待连接", systemImage: "iphone")
                    .foregroundStyle(.secondary)
            }
        case .connected:
            Label("设备已连接", systemImage: "checkmark.circle")
        case .offline(let message):
            Label("设备连接失败", systemImage: "exclamationmark.triangle")
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        if let date = model.lastScan {
            LabeledContent("上次成功扫描") {
                Text(date, format: .dateTime.year().month().day().hour().minute().locale(locale))
            }
        }
    }

    private var connectionSetup: some View {
        List {
            if model.hasSavedPairing && !model.isPairing {
                Section {
                    Label("此 iPhone 已配对", systemImage: "checkmark.circle")
                    Text("保持本机回环连接，即可读取已安装的 App。可使用 Surge 的 Local Device Loopback 模块或 LocalDevVPN。")
                }
            } else if showsPairing {
                Section {
                    RemotePairingDetails(model: model)
                    if !model.isPairing {
                        Toggle("用通知显示配对码", isOn: $notifiesPairingCode)
                        Button("开始配对") {
                            Task { await model.pair(notifyCode: notifiesPairingCode) }
                        }
                        .disabled(model.isRefreshing)
                    }
                }
            } else {
                Section {
                    Text("先连接此 iPhone 上的本机回环 VPN，再继续配对。")
                    Button("继续配对") { showsPairing = true }
                        .disabled(model.isRefreshing)
                }
            }
            Section {
                connectionStatus
                Button("重试读取清单") {
                    Task { await model.refresh() }
                }
                .disabled(model.isPairing || model.isRefreshing)
            }
        }
        .navigationTitle(connectionTitle)
    }

    private var connectionTitle: LocalizedStringKey {
        if model.hasSavedPairing { return "读取设备清单" }
        return showsPairing ? "系统配对" : "连接设备"
    }

    private var signatureSetup: some View {
        List {
            Section {
                Text("选择一个你重签过的 App，确认跟踪它的证书指纹或签名名称。签名无法区分时，可以单独跟踪这个 App。")
            }
            if !model.pendingApps.isEmpty {
                Section("待确认") {
                    ForEach(model.pendingApps) { app in
                        appLink(app, reason: model.match(for: app).reason)
                    }
                }
            }
            Section {
                NavigationLink("从已安装的 App 选择", value: UpdaterDestination.inventory)
            }
        }
        .navigationTitle("选择你的签名")
        .refreshable { await model.refresh() }
    }

    private var regionSetup: some View {
        let suggested = UpdaterModel.suggestedCountry
        return List {
            Section {
                Text("可选择一个或多个地区。更新检查按顺序查询，使用最先匹配的 App Store 版本。")
                Button(localized("使用%@（%@）", UpdaterModel.countryName(suggested), suggested)) {
                    model.setCountries([suggested])
                }
                NavigationLink("选择地区", value: UpdaterDestination.region)
            }
        }
        .navigationTitle("选择 App Store 地区")
    }
}

private struct RemotePairingDetails: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        switch model.remotePairingStatus {
        case .idle:
            EmptyView()
        case .preparing:
            ProgressView("正在准备配对")
            cancelButton
        case .awaitingHost:
            ProgressView("等待在“设置”中选择主机")
            Text(localized("打开“设置” → “隐私与安全性” → “开发者模式”，选择与 %@ 配对。", UpdaterModel.pairingHostName))
            Text(localized("选择后返回 %@ 查看六位配对码。", UpdaterModel.pairingHostName))
                .foregroundStyle(.secondary)
            cancelButton
        case .showingCode(let code):
            LabeledContent("主机名称", value: UpdaterModel.pairingHostName)
            VStack(alignment: .leading, spacing: 4) {
                Text("六位配对码")
                    .font(.subheadline)
                Text(code)
                    .font(.largeTitle.weight(.semibold).monospacedDigit())
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
            }
            Text("切回“设置”，在配对提示中输入此配对码并确认。")
            cancelButton
        case .paired:
            Label("设备配对成功", systemImage: "checkmark.circle")
        case .cancelled:
            Text("配对已取消。")
        case .expired:
            Text("配对已过期，请重新开始。")
        case .failed(let message):
            Label("配对失败", systemImage: "exclamationmark.triangle")
            Text(message)
                .foregroundStyle(.secondary)
        }
    }

    private var cancelButton: some View {
        Button("取消配对", action: model.cancelRemotePairing)
    }
}

private struct TrackedAppRow: View {
    let app: DeviceApp
    let row: UpdateRow

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: row.entry?.artwork)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(versionLine)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                UpdateStatusLabel(row: row)
                    .font(.footnote)
            }
            Spacer(minLength: 8)
            if let url = storeURL {
                Link(destination: url) {
                    Text(localized(row.state == .update ? "更新" : "商店"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(row.state == .update ? .accentColor : .secondary)
                .accessibilityLabel(Text(localized("在 App Store 打开 %@", app.name)))
            }
        }
    }

    private var versionLine: String {
        let local = app.version.displayVersion
        guard let store = row.entry?.version else { return localized("本机 %@", local) }
        let version = local == store ? local : localized("%@ → %@", local, store)
        guard let country = row.country else { return version }
        return localized("%@（%@）", version, UpdaterModel.countryName(country))
    }

    private var storeURL: URL? {
        guard let entry = row.entry else { return nil }
        let region = row.country?.lowercased() ?? "us"
        return URL(string: "https://apps.apple.com/\(region)/app/id\(entry.id)")
    }
}

private struct AppIcon: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "app.dashed")
                .font(.title2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemFill))
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct PendingAppsView: View {
    @ObservedObject var model: UpdaterModel

    var body: some View {
        List {
            Section {
                ForEach(model.pendingApps) { app in
                    appLink(app, reason: model.match(for: app).reason)
                }
            } footer: {
                Text("这些 App 可能是侧载安装，但签名尚未确认。点进去可跟踪其签名或单独跟踪。")
            }
        }
        .navigationTitle("待确认")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct UpdateStatusLabel: View {
    @Environment(\.locale) private var locale
    let row: UpdateRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if row.state == .update {
                Label(row.state.title, systemImage: "arrow.up.circle.fill")
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(row.state.title)
                    .foregroundStyle(.secondary)
            }
            if row.isStale, let date = row.checkedAt {
                let timestamp = date.formatted(.dateTime.year().month().day().hour().minute().locale(locale))
                Text(localized("商店缓存 %@", timestamp))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct InventoryView: View {
    @ObservedObject var model: UpdaterModel
    @State private var query = ""

    private var apps: [DeviceApp] {
        model.installedApps.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
        }
    }

    var body: some View {
        List {
            if apps.isEmpty {
                Text(localized(query.isEmpty ? "清单中暂无 App。" : "没有符合条件的 App。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                appLink(app, reason: model.match(for: app).isTracked ? localized("已跟踪") : nil)
            }
        }
        .navigationTitle("已安装的 App")
        .searchable(text: $query, prompt: "搜索名称或 Bundle ID")
    }
}

private struct AppDetailView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: UpdaterModel
    let bundleID: String
    let onTrack: () -> Void
    @State private var showsBinding = false
    @State private var signatureToConfirm: SignatureRule?

    var body: some View {
        Group {
            if let app = model.app(bundleID) {
                Form {
                    deviceSection(app)
                    trackingSection(app)
                    if model.country != nil { storeSection(app) }
                }
                .navigationTitle(app.name)
            } else {
                ContentUnavailableView("清单中已找不到此 App", systemImage: "iphone")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsBinding) {
            NavigationStack {
                StoreBindingView(model: model, bundleID: bundleID)
            }
        }
        .confirmationDialog("跟踪这个签名？", isPresented: Binding(
            get: { signatureToConfirm != nil },
            set: { if !$0 { signatureToConfirm = nil } }
        ), titleVisibility: .visible, presenting: signatureToConfirm) { rule in
            Button("确认跟踪") {
                model.addRule(from: bundleID, expected: rule)
                onTrack()
            }
        } message: { rule in
            Text(localized("符合这个%@的其他 App 也会纳入跟踪。请仅选择你自己的签名。", rule.kind.title))
        }
    }

    private func deviceSection(_ app: DeviceApp) -> some View {
        Section("本机安装") {
            LabeledContent("Bundle ID", value: app.id)
                .textSelection(.enabled)
            LabeledContent("安装版本", value: app.version.displayVersion)
            LabeledContent("侧载来源", value: provenance(app))
            LabeledContent("签名名称", value: app.signer.displayVersion)
                .textSelection(.enabled)
            LabeledContent("证书指纹", value: app.certificateFingerprint.displayVersion)
                .textSelection(.enabled)
        }
    }

    private func trackingSection(_ app: DeviceApp) -> some View {
        let match = model.match(for: app)
        return Section("跟踪") {
            LabeledContent("依据", value: match.reason)
            if let rule = model.rule(for: app), !model.follows(rule) {
                Button(localized("跟踪这个%@", rule.kind.title)) { signatureToConfirm = rule }
            }
            if match.isTracked {
                Button("停止跟踪此 App") {
                    model.setTracking(.exclude, for: bundleID)
                }
            } else {
                Button("单独跟踪此 App") {
                    model.setTracking(.include, for: bundleID)
                    onTrack()
                }
            }
            if model.trackingOverride(for: bundleID) != nil {
                Button("恢复自动跟踪规则") {
                    model.setTracking(nil, for: bundleID)
                }
            }
        }
    }

    private func storeSection(_ app: DeviceApp) -> some View {
        let row = model.row(for: app)
        return Section("App Store 原版") {
            if let country = row.country {
                LabeledContent("匹配地区", value: UpdaterModel.countryName(country))
            }
            if let id = model.boundID(for: bundleID) {
                LabeledContent("商店 ID", value: String(id))
                    .textSelection(.enabled)
            }
            if let entry = row.entry {
                LabeledContent("名称", value: entry.name)
                LabeledContent("开发者", value: entry.artist)
            }
            LabeledContent("商店版本", value: row.entry?.version ?? localized("未知"))
            UpdateStatusLabel(row: row)
            if !row.isStale, let date = row.checkedAt {
                LabeledContent("查询时间") {
                    Text(date, format: .dateTime.year().month().day().hour().minute().locale(locale))
                }
            }
            Toggle("使用独立版本编号", isOn: Binding(
                get: { model.hasIndependentVersion(bundleID) },
                set: { model.setIndependentVersion($0, for: bundleID) }
            ))
            Button(localized(model.boundID(for: bundleID) == nil ? "绑定商店原版" : "更改商店绑定")) {
                showsBinding = true
            }
            if model.boundID(for: bundleID) != nil {
                Button("移除绑定", role: .destructive) {
                    model.removeBinding(for: bundleID)
                }
            }
        }
    }

    private func provenance(_ app: DeviceApp) -> String {
        switch app.isSideloadCandidate {
        case true?: localized("设备标记为侧载候选")
        case false?: localized("设备标记为非侧载")
        case nil where app.hasSideloadProfile == true: localized("已验证的描述文件安装")
        case nil: localized(app.isDeveloperApp == true ? "设备标记为开发 App" : "安装来源不明")
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: UpdaterModel
    let onImportPairing: () -> Void
    @State private var notifiesPairingCode = false

    var body: some View {
        Form {
            Section("App Store") {
                NavigationLink(value: UpdaterDestination.region) {
                    LabeledContent("地区优先顺序", value: regionSummary)
                }
            }
            Section {
                if model.rules.isEmpty {
                    Text("暂无签名规则。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.rules) { rule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.title)
                        Text(rule.kind == .fingerprint ? localized("证书指纹 %@", rule.value) : rule.kind.title)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .onDelete { indexes in
                    let rules = model.rules
                    for index in indexes { model.removeRule(rules[index]) }
                }
                NavigationLink("从已安装的 App 添加", value: UpdaterDestination.inventory)
            } header: {
                Text("跟踪的签名")
            } footer: {
                Text(localized(model.rules.isEmpty
                    ? "默认自动跟踪通过已验证描述文件安装的 App。"
                    : "自动跟踪范围为已选签名。"))
            }
            Section("设备") {
                RemotePairingDetails(model: model)
                if !model.isPairing {
                    Toggle("用通知显示配对码", isOn: $notifiesPairingCode)
                    Button(localized(model.hasSavedPairing ? "重新配对" : "开始配对")) {
                        Task { await model.pair(notifyCode: notifiesPairingCode) }
                    }
                    .disabled(model.isRefreshing)
                }
                if case .offline(let message) = model.connection {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("其他配对方式") {
                Button("使用已有配对文件", action: onImportPairing)
                    .disabled(model.isPairing || model.isRefreshing)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var regionSummary: String {
        guard let first = model.country else { return localized("未选择") }
        let name = UpdaterModel.countryName(first)
        return model.countries.count == 1 ? name : localized("%@等 %lld 个地区", name, Int64(model.countries.count))
    }
}

private struct RegionView: View {
    @ObservedObject var model: UpdaterModel
    @State private var editMode: EditMode = .inactive
    @State private var showsPicker = false

    var body: some View {
        List {
            Section {
                if model.countries.isEmpty {
                    Text("添加地区后即可检查 App Store 更新。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.countries, id: \.self) { code in
                    LabeledContent(UpdaterModel.countryName(code), value: code)
                }
                .onMove { indexes, destination in
                    var countries = model.countries
                    countries.move(fromOffsets: indexes, toOffset: destination)
                    model.setCountries(countries)
                }
                .onDelete { indexes in
                    var countries = model.countries
                    countries.remove(atOffsets: indexes)
                    model.setCountries(countries)
                    if countries.isEmpty { editMode = .inactive }
                }
            } header: {
                Text("查询顺序")
            } footer: {
                Text("从上到下查询，使用最先匹配的地区。")
            }
            Button("添加地区") { showsPicker = true }
        }
        .navigationTitle("App Store 地区")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
                    .disabled(model.countries.isEmpty)
            }
        }
        .environment(\.editMode, $editMode)
        .sheet(isPresented: $showsPicker) {
            NavigationStack {
                RegionPickerView(existingCountries: model.countries) { selection in
                    model.setCountries(model.countries + selection)
                }
            }
        }
    }
}

private struct RegionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let existingCountries: [String]
    let onAdd: ([String]) -> Void
    @State private var query = ""
    @State private var selection: [String] = []

    private var countries: [String] {
        Locale.Region.isoRegions.map(\.identifier)
            .filter {
                $0.utf8.count == 2 && !existingCountries.contains($0) && (
                    query.isEmpty || $0.localizedStandardContains(query)
                    || UpdaterModel.countryName($0).localizedStandardContains(query)
                )
            }
            .sorted { UpdaterModel.countryName($0).localizedStandardCompare(UpdaterModel.countryName($1)) == .orderedAscending }
    }

    var body: some View {
        List {
            if countries.isEmpty {
                Text(localized(query.isEmpty ? "没有可添加的地区。" : "没有找到符合条件的地区。"))
                    .foregroundStyle(.secondary)
            }
            ForEach(countries, id: \.self) { code in
                let isSelected = selection.contains(code)
                Button {
                    if let index = selection.firstIndex(of: code) {
                        selection.remove(at: index)
                    } else {
                        selection.append(code)
                    }
                } label: {
                    HStack {
                        Text(localized("%@（%@）", UpdaterModel.countryName(code), code))
                            .foregroundStyle(.primary)
                        Spacer()
                        if isSelected {
                            Image(systemName: "checkmark")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .navigationTitle("添加地区")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索地区或代码")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("添加") {
                    onAdd(selection)
                    dismiss()
                }
                .disabled(selection.isEmpty)
            }
        }
    }
}

private struct StoreBindingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: UpdaterModel
    let bundleID: String
    @State private var link = ""
    @State private var preview: StoreBindingPreview?
    @State private var errorMessage: String?
    @State private var isLookingUp = false

    var body: some View {
        Form {
            Section {
                TextField("粘贴 App Store 链接", text: $link)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isLookingUp)
                    .onChange(of: link) {
                        preview = nil
                        errorMessage = nil
                    }
                Button("查询原版") { Task { await lookup() } }
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLookingUp)
                if isLookingUp { ProgressView("正在查询商店") }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                }
            }
            if let preview {
                Section {
                    LabeledContent("名称", value: preview.entry.name)
                    LabeledContent("开发者", value: preview.entry.artist)
                    LabeledContent("商店版本", value: preview.entry.version)
                    LabeledContent("Bundle ID", value: preview.entry.bundleID)
                    LabeledContent("匹配地区", value: UpdaterModel.countryName(preview.country))
                    Button("确认绑定") {
                        if model.confirmBinding(preview, for: bundleID) {
                            dismiss()
                        } else {
                            errorMessage = localized("当前地区或设备清单已变化，请重新查询。")
                            self.preview = nil
                        }
                    }
                } header: {
                    Text("确认商店原版")
                } footer: {
                    if preview.entry.bundleID != bundleID {
                        Text("此条目的 Bundle ID 与本机 App 不同。请核对名称和开发者后再绑定。")
                    }
                }
            }
        }
        .navigationTitle("绑定商店原版")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
    }

    private func lookup() async {
        guard !isLookingUp else { return }
        isLookingUp = true
        preview = nil
        errorMessage = nil
        defer { isLookingUp = false }
        do {
            preview = try await model.previewBinding(link)
        } catch let error as StoreBindingError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = localized("无法查询商店。请检查网络后重试。")
        }
    }
}

private func appLink(_ app: DeviceApp, reason: String?) -> some View {
    NavigationLink(value: UpdaterDestination.app(app.id)) {
        VStack(alignment: .leading, spacing: 4) {
            Text(app.name)
            Text(reason.map { localized("本机 %@ · %@", app.version.displayVersion, $0) } ?? app.id)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private extension Optional where Wrapped == String {
    var displayVersion: String {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return localized("未知") }
        return self
    }
}

private func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: .main, comment: "")
    return arguments.isEmpty ? format : String(format: format, locale: .current, arguments: arguments)
}
