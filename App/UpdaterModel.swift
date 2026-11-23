import Foundation
import SwiftUI
#if os(iOS) && !SWIFT_PACKAGE
import UIKit
import UserNotifications
#endif

#if SWIFT_PACKAGE
private let coreBundle = Bundle.module
#else
private let coreBundle = Bundle.main
#endif

private var coreLocale: Locale {
    Locale(identifier: coreBundle.preferredLocalizations.first ?? "en")
}

func coreString(_ key: String, _ arguments: CVarArg...) -> String {
    let text = NSLocalizedString(key, tableName: "Core", bundle: coreBundle, comment: "")
    return arguments.isEmpty ? text : String(format: text, locale: coreLocale, arguments: arguments)
}

enum SignatureKind: String, Codable {
    case fingerprint, name

    var title: String {
        switch self {
        case .fingerprint: coreString("signature.fingerprint")
        case .name: coreString("signature.name")
        }
    }
}

struct SignatureRule: Codable, Hashable, Identifiable {
    let kind: SignatureKind
    let value: String
    let name: String?

    var id: String { "\(kind.rawValue):\(value)" }
    var title: String { name ?? value }
}

enum TrackingOverride: String, Codable {
    case include, exclude
}

private struct InventorySnapshot: Codable {
    let apps: [DeviceApp]
    let date: Date
}

private struct StoreKey: Codable, Hashable {
    let id: Int64
    let country: String
}

private struct CachedStoreEntry: Codable {
    let entry: StoreEntry
    let date: Date
}

private typealias StoreResult = Result<CachedStoreEntry?, Error>

private struct UpdaterStorage: Codable {
    var snapshot: InventorySnapshot?
    var country: String?
    var countries: [String]?
    var matchedCountries: [String: String]?
    var rules: [SignatureRule] = []
    var overrides: [String: TrackingOverride] = [:]
    var independentVersions: Set<String> = []
    var bindings: [String: Int64] = [:]
    var cache: [StoreKey: CachedStoreEntry] = [:]
    var fingerprintsByName: [String: Set<String>] = [:]
}

enum ConnectionState {
    case idle, connected, offline(String)
}

enum TrackingMatch {
    case tracked(String)
    case pending(String)
    case hidden

    var reason: String {
        switch self {
        case .tracked(let reason), .pending(let reason): reason
        case .hidden: coreString("tracking.hidden")
        }
    }

    var isTracked: Bool {
        if case .tracked = self { return true }
        return false
    }
}

enum UpdateState {
    case update, equal, installedNewer, incomparable, independent
    case checking, notFound, unavailable, queryFailed, stale, awaitingCheck

    var title: String {
        switch self {
        case .update: coreString("update.available")
        case .equal: coreString("update.equal")
        case .installedNewer: coreString("update.installedNewer")
        case .incomparable: coreString("update.incomparable")
        case .independent: coreString("update.independent")
        case .checking: coreString("update.checking")
        case .notFound: coreString("update.notFound")
        case .unavailable: coreString("update.unavailable")
        case .queryFailed: coreString("update.queryFailed")
        case .stale: coreString("update.stale")
        case .awaitingCheck: coreString("update.awaitingCheck")
        }
    }
}

struct UpdateRow {
    let entry: StoreEntry?
    let country: String?
    let checkedAt: Date?
    let state: UpdateState
    let isStale: Bool
}

struct StoreBindingPreview {
    let entry: StoreEntry
    let country: String
    let searchOrder: [String]
    let checkedAt: Date
}

enum StoreBindingError: LocalizedError {
    case invalidLink, unavailable, missingRegion

    var errorDescription: String? {
        switch self {
        case .invalidLink: coreString("binding.invalidLink")
        case .unavailable: coreString("binding.unavailable")
        case .missingRegion: coreString("binding.missingRegion")
        }
    }
}

private enum StoreOutcome {
    case found, notFound, unavailable, failed
}

enum RemotePairingStatus: Equatable {
    case idle, preparing, awaitingHost, showingCode(String), paired, cancelled, expired, failed(String)
}

enum RemotePairingError: LocalizedError {
    case expired

    var errorDescription: String? { coreString("pairing.expired") }
}

protocol UpdaterInventory {
    func hasSavedPairing() async throws -> Bool
    func scan() async throws -> [DeviceApp]
    func pair() async throws
    func pair(onCode: @escaping @Sendable (String) -> Void) async throws
    func pair(recordAt url: URL, port: UInt16) async throws
}

private enum PairingImportError: LocalizedError {
    case unavailable

    var errorDescription: String? { coreString("pairing.importUnavailable") }
}

extension UpdaterInventory {
    func pair(onCode: @escaping @Sendable (String) -> Void) async throws {
        try await pair()
    }

    func pair(recordAt url: URL, port: UInt16) async throws {
        throw PairingImportError.unavailable
    }
}

protocol UpdaterCatalog {
    func lookup(bundleID: String, country: String) async throws -> StoreEntry?
    func lookup(id: Int64, country: String) async throws -> StoreEntry?
}

extension StoreCatalog: UpdaterCatalog {}

#if !SWIFT_PACKAGE
extension DeviceInventory: UpdaterInventory {}
#endif

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private var storage: UpdaterStorage
    @Published private var outcomes: [String: StoreOutcome] = [:]
    @Published private(set) var connection = ConnectionState.idle
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPairing = false
    @Published private(set) var hasSavedPairing = false
    @Published private(set) var remotePairingStatus = RemotePairingStatus.idle

    private let inventory: any UpdaterInventory
    private let catalog: any UpdaterCatalog
    private let defaults: UserDefaults
    private static let storageKey = "SideloadUpdater.settings.v1"
    static let pairingHostName = "Sideload Updater"

    private var refreshTask: Task<Void, Never>?
    private var remotePairingTask: Task<Void, Never>?
    private var remotePairingAttempt: UUID?
    private var inventoryRequested = false
    private var needsScanOnActivation = true
    private var inventoryQueued = false
    private var catalogQueued = false
    private var catalogRevision = 0
    private var bindingRevisions: [String: Int] = [:]
    private var storeRequests: [StoreKey: Task<CachedStoreEntry?, Error>] = [:]

    #if !SWIFT_PACKAGE
    convenience init() {
        self.init(inventory: DeviceInventory(), catalog: StoreCatalog())
    }
    #endif

    init(inventory: any UpdaterInventory, catalog: any UpdaterCatalog, defaults: UserDefaults = .standard) {
        self.inventory = inventory
        self.catalog = catalog
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(UpdaterStorage.self, from: data) {
            storage = saved
        } else {
            storage = UpdaterStorage()
        }
    }

    var apps: [DeviceApp] { storage.snapshot?.apps ?? [] }
    var lastScan: Date? { storage.snapshot?.date }
    var countries: [String] { storage.countries ?? storage.country.map { [$0] } ?? [] }
    var country: String? { countries.first }
    var rules: [SignatureRule] { storage.rules }
    var hasTracking: Bool {
        !rules.isEmpty || storage.overrides.values.contains(.include)
            || apps.contains { match(for: $0).isTracked }
    }

    static var suggestedCountry: String {
        let code = Locale.current.region?.identifier.uppercased() ?? "US"
        return isCountryCode(code) ? code : "US"
    }

    static func countryName(_ country: String) -> String {
        coreLocale.localizedString(forRegionCode: country) ?? country
    }

    private static func isCountryCode(_ value: String) -> Bool {
        value.utf8.count == 2 && value.utf8.allSatisfy { (65...90).contains($0) }
    }

    var trackedApps: [DeviceApp] {
        apps.filter { match(for: $0).isTracked }.sorted {
            let leftHasUpdate = row(for: $0).state == .update
            let rightHasUpdate = row(for: $1).state == .update
            if leftHasUpdate != rightHasUpdate { return leftHasUpdate }
            return appOrder($0, $1)
        }
    }

    var pendingApps: [DeviceApp] {
        apps.filter {
            if case .pending = match(for: $0) { return true }
            return false
        }.sorted(by: appOrder)
    }

    var installedApps: [DeviceApp] { apps.sorted(by: appOrder) }

    private func appOrder(_ left: DeviceApp, _ right: DeviceApp) -> Bool {
        let order = left.name.localizedStandardCompare(right.name)
        return order == .orderedSame ? left.id < right.id : order == .orderedAscending
    }

    func app(_ bundleID: String) -> DeviceApp? {
        apps.first { $0.id == bundleID }
    }

    func match(for app: DeviceApp) -> TrackingMatch {
        switch storage.overrides[app.id] {
        case .include: return .tracked(coreString("tracking.manual"))
        case .exclude: return .hidden
        case nil: break
        }
        guard app.isSideloadCandidate != false else { return .hidden }
        if rules.isEmpty, app.hasSideloadProfile == true {
            return .tracked(coreString("tracking.verifiedProfile"))
        }

        let fingerprint = Self.fingerprint(app)
        let name = Self.signer(app)
        let matchesFingerprint = fingerprint.map { value in
            rules.contains { $0.kind == .fingerprint && $0.value == value }
        } ?? false
        let matchesName = name.map { value in
            rules.contains { $0.kind == .name && $0.value == value }
        } ?? false

        if matchesFingerprint { return .tracked(coreString("tracking.matchedFingerprint")) }
        if let name, Self.ambiguousName(name) || hasNameCollision(name) {
            return .pending(coreString(fingerprint == nil ? "tracking.ambiguousName" : "tracking.confirmFingerprint"))
        }
        if matchesName { return .tracked(coreString("tracking.matchedName")) }
        if app.hasSideloadProfile == true { return .pending(coreString("tracking.untrackedProfileSignature")) }
        guard app.isSideloadCandidate == true else {
            return app.isDeveloperApp == true ? .pending(coreString("tracking.developerApp")) : .hidden
        }
        if fingerprint != nil || name != nil { return .pending(coreString("tracking.untrackedSignature")) }
        return .pending(coreString("tracking.missingSignature"))
    }

    func rule(for app: DeviceApp) -> SignatureRule? {
        guard app.isSideloadCandidate != false else { return nil }
        let name = Self.signer(app)
        if let fingerprint = Self.fingerprint(app) {
            return SignatureRule(kind: .fingerprint, value: fingerprint, name: name)
        }
        guard let name, !Self.ambiguousName(name), !hasNameCollision(name) else { return nil }
        return SignatureRule(kind: .name, value: name, name: name)
    }

    func follows(_ rule: SignatureRule) -> Bool {
        rules.contains { $0.id == rule.id }
    }

    func addRule(from bundleID: String, expected: SignatureRule) {
        guard let app = app(bundleID), let rule = rule(for: app), rule == expected else { return }
        if !follows(rule) { storage.rules.append(rule) }
        configurationChanged()
    }

    func removeRule(_ rule: SignatureRule) {
        storage.rules.removeAll { $0.id == rule.id }
        configurationChanged()
    }

    func trackingOverride(for bundleID: String) -> TrackingOverride? {
        storage.overrides[bundleID]
    }

    func setTracking(_ value: TrackingOverride?, for bundleID: String) {
        storage.overrides[bundleID] = value
        configurationChanged()
    }

    func hasIndependentVersion(_ bundleID: String) -> Bool {
        storage.independentVersions.contains(bundleID)
    }

    func setIndependentVersion(_ value: Bool, for bundleID: String) {
        if value {
            storage.independentVersions.insert(bundleID)
        } else {
            storage.independentVersions.remove(bundleID)
        }
        persist()
    }

    func setCountry(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isCountryCode(value) else { return }
        setCountries([value])
    }

    func setCountries(_ inputs: [String]) {
        var seen = Set<String>()
        let values = inputs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { Self.isCountryCode($0) && seen.insert($0).inserted }
        guard values != countries else { return }
        storage.countries = values
        storage.country = nil
        outcomes.removeAll()
        configurationChanged()
    }

    func boundID(for bundleID: String) -> Int64? {
        storage.bindings[bundleID]
    }

    func previewBinding(_ input: String) async throws -> StoreBindingPreview {
        let order = countries
        guard !order.isEmpty else { throw StoreBindingError.missingRegion }
        guard let id = storeID(from: input.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw StoreBindingError.invalidLink
        }
        for country in order {
            guard order == countries else { throw CancellationError() }
            do {
                if let result = try await lookupStore(StoreKey(id: id, country: country)) {
                    return StoreBindingPreview(entry: result.entry, country: country, searchOrder: order, checkedAt: result.date)
                }
            } catch StoreCatalogError.unavailableInStorefront {
                continue
            }
        }
        throw StoreBindingError.unavailable
    }

    func confirmBinding(_ preview: StoreBindingPreview, for bundleID: String) -> Bool {
        guard preview.searchOrder == countries, app(bundleID) != nil else { return false }
        let key = StoreKey(id: preview.entry.id, country: preview.country)
        bindingRevisions[bundleID, default: 0] += 1
        recordMatch(CachedStoreEntry(entry: preview.entry, date: preview.checkedAt), for: key, bundleID: bundleID)
        persist()
        return true
    }

    func removeBinding(for bundleID: String) {
        storage.bindings.removeValue(forKey: bundleID)
        storage.matchedCountries?.removeValue(forKey: bundleID)
        outcomes.removeValue(forKey: bundleID)
        configurationChanged()
    }

    func row(for app: DeviceApp) -> UpdateRow {
        let order = countries
        let cachedKey = storage.bindings[app.id].flatMap { id -> StoreKey? in
            if let matched = storage.matchedCountries?[app.id], order.contains(matched) {
                return StoreKey(id: id, country: matched)
            }
            return order.lazy.map { StoreKey(id: id, country: $0) }.first { self.storage.cache[$0] != nil }
        }
        let cached = cachedKey.flatMap { storage.cache[$0] }
        let isConnected: Bool
        if case .connected = connection { isConnected = true } else { isConnected = false }
        let state: UpdateState
        let isStale = cached != nil && (!isConnected || outcomes[app.id] != .found)
        if !isConnected {
            state = cached == nil ? .awaitingCheck : .stale
        } else {
            switch outcomes[app.id] {
            case .found:
                if hasIndependentVersion(app.id) {
                    state = .independent
                } else {
                    switch compareVersions(installed: app.version, store: cached?.entry.version) {
                    case .newer: state = .update
                    case .equal: state = .equal
                    case .older: state = .installedNewer
                    case .incomparable: state = .incomparable
                    }
                }
            case .notFound: state = .notFound
            case .unavailable: state = .unavailable
            case .failed: state = .queryFailed
            case nil where isRefreshing: state = .checking
            case nil: state = cached == nil ? .awaitingCheck : .stale
            }
        }
        return UpdateRow(entry: cached?.entry, country: cachedKey?.country, checkedAt: cached?.date, state: state, isStale: isStale)
    }

    func refreshIfNeededOnActivation() async {
        guard needsScanOnActivation else { return }
        await refresh()
    }

    func refresh() async {
        guard !isPairing else { return }
        needsScanOnActivation = false
        if !inventoryRequested {
            inventoryRequested = true
            inventoryQueued = true
        }
        await startRefresh().value
    }

    func pair(notifyCode: Bool = false) async {
        guard !isPairing else { return }
        isPairing = true
        remotePairingStatus = .preparing
        let attempt = UUID()
        remotePairingAttempt = attempt
        let task = Task { [self] in
            await refreshTask?.value
            do {
                try Task.checkCancellation()
                let canNotify = notifyCode ? await requestPairingNotifications() : false
                try Task.checkCancellation()
                remotePairingStatus = .awaitingHost
                try await inventory.pair { [weak self] code in
                    Task { @MainActor [weak self] in
                        self?.showPairingCode(code, attempt: attempt, notify: canNotify)
                    }
                }
                try Task.checkCancellation()
                hasSavedPairing = true
                connection = .idle
                remotePairingStatus = .paired
            } catch is CancellationError {
                remotePairingStatus = Task.isCancelled ? .cancelled : .expired
            } catch RemotePairingError.expired {
                if !Task.isCancelled { remotePairingStatus = .expired }
            } catch {
                if !Task.isCancelled {
                    let message = connectionMessage(error, fallback: coreString("pairing.remoteFailed"))
                    remotePairingStatus = .failed(message)
                }
            }
            clearPairingNotification(for: attempt)
            remotePairingAttempt = nil
            remotePairingTask = nil
            isPairing = false
            if remotePairingStatus == .paired {
                needsScanOnActivation = true
                #if os(iOS) && !SWIFT_PACKAGE
                guard UIApplication.shared.applicationState == .active else { return }
                #endif
                await refresh()
            }
        }
        remotePairingTask = task
        await task.value
    }

    func cancelRemotePairing() {
        guard let remotePairingTask, let remotePairingAttempt else { return }
        remotePairingStatus = .cancelled
        remotePairingTask.cancel()
        clearPairingNotification(for: remotePairingAttempt)
    }

    private func showPairingCode(_ code: String, attempt: UUID, notify: Bool) {
        guard remotePairingAttempt == attempt, remotePairingStatus == .awaitingHost,
              code.utf8.count == 6, code.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        remotePairingStatus = .showingCode(code)
        if notify { showPairingNotification(code: code, attempt: attempt) }
    }

    private func requestPairingNotifications() async -> Bool {
        #if os(iOS) && !SWIFT_PACKAGE
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) == true
        #else
        false
        #endif
    }

    private func showPairingNotification(code: String, attempt: UUID) {
        #if os(iOS) && !SWIFT_PACKAGE
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = coreString("pairing.notificationTitle", Self.pairingHostName)
        content.body = coreString("pairing.notificationBody", code)
        let request = UNNotificationRequest(identifier: pairingNotificationID(attempt), content: content, trigger: nil)
        Task {
            try? await center.add(request)
            if remotePairingAttempt != attempt || remotePairingStatus != .showingCode(code) {
                clearPairingNotification(for: attempt)
            }
        }
        #endif
    }

    private func clearPairingNotification(for attempt: UUID) {
        #if os(iOS) && !SWIFT_PACKAGE
        let center = UNUserNotificationCenter.current()
        let identifiers = [pairingNotificationID(attempt)]
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        #endif
    }

    private func pairingNotificationID(_ attempt: UUID) -> String {
        "remote-pairing-\(attempt.uuidString)"
    }

    func pair(recordAt url: URL, port: UInt16 = 49152) async {
        guard !isPairing else { return }
        isPairing = true
        remotePairingStatus = .idle
        await refreshTask?.value
        connection = .idle
        do {
            try await inventory.pair(recordAt: url, port: port)
            hasSavedPairing = true
            isPairing = false
            await refresh()
        } catch {
            connection = .offline(connectionMessage(error, fallback: coreString("pairing.importFailed")))
            isPairing = false
        }
    }

    private func configurationChanged() {
        persist()
        catalogRevision += 1
        if country != nil, !trackedApps.isEmpty {
            catalogQueued = true
            _ = startRefresh()
        }
    }

    private func startRefresh() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        isRefreshing = true
        let task = Task {
            while inventoryQueued || catalogQueued {
                if inventoryQueued {
                    inventoryQueued = false
                    await scan()
                } else {
                    catalogQueued = false
                    await refreshCatalog()
                }
            }
            inventoryRequested = false
            isRefreshing = false
            refreshTask = nil
        }
        refreshTask = task
        return task
    }

    private func scan() async {
        do {
            hasSavedPairing = try await inventory.hasSavedPairing()
            let apps = try await inventory.scan()
            var seen = Set<String>()
            var snapshot = storage
            snapshot.snapshot = InventorySnapshot(
                apps: apps.filter { !$0.id.isEmpty && seen.insert($0.id).inserted },
                date: Date()
            )
            for app in apps {
                if let name = Self.signer(app), let fingerprint = Self.fingerprint(app) {
                    snapshot.fingerprintsByName[name, default: []].insert(fingerprint)
                }
            }
            storage = snapshot
            persist()
            outcomes.removeAll()
            connection = .connected
            catalogQueued = country != nil
        } catch {
            connection = .offline(connectionMessage(error, fallback: coreString("inventory.scanFailed")))
        }
    }

    private func refreshCatalog() async {
        let order = countries
        guard !order.isEmpty else { return }
        let revision = catalogRevision
        var results: [StoreKey: StoreResult] = [:]
        appLoop: for app in trackedApps {
            guard revision == catalogRevision, !inventoryQueued else { return }
            let originalID = storage.bindings[app.id]
            let bindingRevision = bindingRevisions[app.id, default: 0]
            var outcome: StoreOutcome = .notFound
            for country in order {
                let result: StoreResult
                let key = originalID.map { StoreKey(id: $0, country: country) }
                if let key, let previous = results[key] {
                    result = previous
                } else {
                    result = await lookupResult(for: app.id, country: country, key: key)
                    if let key { results[key] = result }
                }

                guard revision == catalogRevision, !inventoryQueued else { return }
                guard bindingRevisions[app.id, default: 0] == bindingRevision,
                      storage.bindings[app.id] == originalID else { continue appLoop }
                switch result {
                case .success(let lookup?):
                    let key = StoreKey(id: lookup.entry.id, country: country)
                    recordMatch(lookup, for: key, bundleID: app.id)
                    results[key] = result
                    persist()
                    continue appLoop
                case .success(nil): continue
                case .failure(let error) where (error as? StoreCatalogError) == .unavailableInStorefront:
                    outcome = .unavailable
                case .failure:
                    outcomes[app.id] = .failed
                    continue appLoop
                }
            }
            outcomes[app.id] = outcome
        }
    }

    private func lookupResult(for bundleID: String, country: String, key: StoreKey?) async -> StoreResult {
        do {
            if let key { return .success(try await lookupStore(key)) }
            let entry = try await catalog.lookup(bundleID: bundleID, country: country.lowercased())
            guard let entry, entry.bundleID == bundleID else { return .success(nil) }
            return .success(CachedStoreEntry(entry: entry, date: Date()))
        } catch {
            return .failure(error)
        }
    }

    private func lookupStore(_ key: StoreKey) async throws -> CachedStoreEntry? {
        if let pending = storeRequests[key] { return try await pending.value }
        let catalog = self.catalog
        let task = Task {
            let entry = try await catalog.lookup(id: key.id, country: key.country.lowercased())
            let receivedAt = Date()
            return entry.flatMap { $0.id == key.id ? CachedStoreEntry(entry: $0, date: receivedAt) : nil }
        }
        storeRequests[key] = task
        defer { storeRequests.removeValue(forKey: key) }
        return try await task.value
    }

    private func recordMatch(_ result: CachedStoreEntry, for key: StoreKey, bundleID: String) {
        storage.bindings[bundleID] = key.id
        if storage.matchedCountries == nil { storage.matchedCountries = [:] }
        storage.matchedCountries?[bundleID] = key.country
        outcomes[bundleID] = .found
        if let previous = storage.cache[key], previous.date > result.date { return }
        storage.cache[key] = result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(storage) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private func connectionMessage(_ error: Error, fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }

    private func hasNameCollision(_ name: String) -> Bool {
        (storage.fingerprintsByName[name]?.count ?? 0) > 1
    }

    private static func fingerprint(_ app: DeviceApp) -> String? {
        nonempty(app.certificateFingerprint)?.lowercased()
    }

    private static func signer(_ app: DeviceApp) -> String? {
        nonempty(app.signer)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func ambiguousName(_ name: String) -> Bool {
        let subject = name
            .replacingOccurrences(of: #"\s*\([A-Z0-9]{10}\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(
                of: #"^(apple (development|distribution)|iphone (developer|distribution)|ios (development|distribution))\s*:\s*"#,
                with: "", options: [.regularExpression, .caseInsensitive]
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if subject.isEmpty || subject.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil {
            return true
        }
        let generic = [
            "apple", "apple development", "apple developer", "apple distribution",
            "apple iphone os application signing", "app store", "ios development", "ios distribution",
            "iphone developer", "iphone distribution", "development", "distribution",
            "adhoc", "ad hoc", "enterprise", "developer", "developer mode", "debug",
            "team", "team id", "unknown", "none", "unsigned", "true", "false"
        ]
        return generic.contains(subject.lowercased())
            || subject.range(of: #"^(team(\s*(id|identifier))?|unknown)\s*[:=]"#, options: [.regularExpression, .caseInsensitive]) != nil
            || !subject.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}
