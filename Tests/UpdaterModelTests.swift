import Foundation
import XCTest
@testable import UpdaterCore

@MainActor
final class UpdaterModelTests: XCTestCase {
    func testValidatedProfileWorksWithoutSignerAndCanBeScopedByUser() async throws {
        let profile: [String: Any] = ["ProfileValidated": true, "Entitlements": ["get-task-allow": true]]
        let unsignedName = try XCTUnwrap(DeviceApp(lookupID: "app.profile", metadata: profile))
        let withName = try XCTUnwrap(DeviceApp(lookupID: "app.signer", metadata: profile.merging(
            ["SignerIdentity": "Apple Development: Jane Example"], uniquingKeysWith: { _, new in new }
        )))
        let store = try XCTUnwrap(DeviceApp(lookupID: "app.store", metadata: [
            "ProfileValidated": true, "SignerIdentity": "Apple iPhone OS Application Signing: Store"
        ]))
        let model = UpdaterModel(inventory: InventoryFixture([unsignedName, withName, store]),
                                 catalog: CatalogFixture(), defaults: try isolatedDefaults())
        await model.refresh()
        XCTAssertTrue(model.hasTracking)
        XCTAssertEqual(Set(model.trackedApps.map(\.id)), [unsignedName.id, withName.id])
        model.addRule(from: withName.id, expected: try XCTUnwrap(model.rule(for: withName)))
        XCTAssertEqual(model.trackedApps.map(\.id), [withName.id])
    }

    func testSelectedSignerDiscoversNewAppWithUnknownOriginAndExcludesStoreApp() async throws {
        let first = deviceApp("test.first")
        let second = deviceApp("test.second")
        let storeApp = deviceApp("test.store", sideloaded: false)
        let inventory = InventoryFixture([first, storeApp])
        let model = UpdaterModel(inventory: inventory, catalog: CatalogFixture(), defaults: try isolatedDefaults())

        await model.refresh()
        XCTAssertTrue(model.trackedApps.isEmpty)
        let rule = try XCTUnwrap(model.rule(for: first))
        XCTAssertEqual(rule.kind, .name)
        model.addRule(from: first.id, expected: rule)
        XCTAssertEqual(model.trackedApps.map(\.id), [first.id])

        await inventory.setResult(.success([first, second, storeApp]))
        await model.refresh()
        XCTAssertEqual(Set(model.trackedApps.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(model.match(for: second).reason, coreString("tracking.matchedName"))
        XCTAssertNil(model.rule(for: storeApp))
        guard case .hidden = model.match(for: storeApp) else {
            return XCTFail("Expected the positively identified App Store app to stay hidden")
        }
    }

    func testAmbiguousNameAndTeamIDRequireConfirmationAndCollisionDisablesSelectedName() async throws {
        let first = deviceApp("test.first")
        let generic = deviceApp("test.generic", signer: "Apple Development")
        let teamID = deviceApp("test.team", signer: "7HG293KD2A", sideloaded: true)
        let inventory = InventoryFixture([first, generic, teamID])
        let defaults = try isolatedDefaults()
        let catalog = CatalogFixture()
        let model = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)

        await model.refresh()
        let nameRule = try XCTUnwrap(model.rule(for: first))
        model.addRule(from: first.id, expected: nameRule)
        XCTAssertEqual(Set(model.pendingApps.map(\.id)), Set([generic.id, teamID.id]))
        XCTAssertNil(model.rule(for: generic))
        XCTAssertNil(model.rule(for: teamID))
        model.setTracking(.include, for: generic.id)
        XCTAssertTrue(model.match(for: generic).isTracked)
        XCTAssertFalse(model.match(for: teamID).isTracked)

        let fingerprint = String(repeating: "ab", count: 32)
        let knownCertificate = deviceApp("test.known-certificate", fingerprint: fingerprint)
        let otherCertificate = deviceApp("test.other-certificate", fingerprint: String(repeating: "cd", count: 32))
        let sameCertificate = deviceApp("test.same-certificate", fingerprint: fingerprint.uppercased())
        await inventory.setResult(.success([first, knownCertificate, otherCertificate, sameCertificate]))
        await model.refresh()
        XCTAssertTrue(model.trackedApps.isEmpty)
        XCTAssertEqual(
            Set(model.pendingApps.map(\.id)),
            Set([first.id, knownCertificate.id, otherCertificate.id, sameCertificate.id])
        )
        XCTAssertNil(model.rule(for: first))

        let fingerprintRule = try XCTUnwrap(model.rule(for: knownCertificate))
        XCTAssertEqual(fingerprintRule.kind, .fingerprint)
        model.addRule(from: knownCertificate.id, expected: fingerprintRule)
        XCTAssertEqual(Set(model.trackedApps.map(\.id)), Set([knownCertificate.id, sameCertificate.id]))

        await inventory.setResult(.success([first]))
        let restarted = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)
        await restarted.refresh()
        XCTAssertEqual(restarted.pendingApps.map(\.id), [first.id])
        XCTAssertNil(restarted.rule(for: first))
    }

    func testChangedBundleIDManualBindingPersistsAndRefreshUsesNumericID() async throws {
        let app = deviceApp("test.resigned")
        let original = storeEntry(bundleID: "test.original")
        let inventory = InventoryFixture([app])
        let catalog = CatalogFixture()
        let defaults = try isolatedDefaults()
        await catalog.respond(to: .bundle(app.id, "tw")) { original }
        await catalog.respond(to: .id(original.id, "tw")) { original }
        let model = try await trackedModel(for: app, inventory: inventory, catalog: catalog, defaults: defaults)

        XCTAssertNil(model.boundID(for: app.id))
        XCTAssertEqual(model.row(for: app).state, .notFound)

        let preview = try await model.previewBinding("https://apps.apple.com/tw/app/original/id42")
        XCTAssertEqual(preview.entry, original)
        XCTAssertEqual(preview.country, "TW")
        XCTAssertNil(model.boundID(for: app.id))
        XCTAssertTrue(model.confirmBinding(preview, for: app.id))
        XCTAssertEqual(model.boundID(for: app.id), original.id)
        XCTAssertEqual(model.row(for: app).state, .update)
        let initialRequests = await catalog.requests
        XCTAssertEqual(initialRequests, [.bundle(app.id, "tw"), .id(original.id, "tw")])

        let restartedCatalog = CatalogFixture()
        let newerOriginal = storeEntry(bundleID: original.bundleID, version: "3.11")
        await restartedCatalog.respond(to: .id(original.id, "tw")) { newerOriginal }
        let restarted = UpdaterModel(inventory: inventory, catalog: restartedCatalog, defaults: defaults)
        XCTAssertEqual(restarted.boundID(for: app.id), original.id)
        XCTAssertEqual(restarted.row(for: app).entry, original)
        XCTAssertTrue(restarted.row(for: app).isStale)

        await restarted.refresh()
        let restartedRequests = await restartedCatalog.requests
        XCTAssertEqual(restartedRequests, [.id(original.id, "tw")])
        XCTAssertEqual(restarted.row(for: app).entry, newerOriginal)
        XCTAssertEqual(restarted.row(for: app).state, .update)
        XCTAssertFalse(restarted.row(for: app).isStale)
    }

    func testBundleLookupStopsAtFirstMatchInStorefrontOrder() async throws {
        let app = deviceApp("test.app")
        let japaneseEntry = storeEntry(bundleID: app.id)
        let americanEntry = storeEntry(bundleID: app.id, version: "4.0")
        let catalog = CatalogFixture()
        await catalog.respond(to: .bundle(app.id, "tw")) { throw StoreCatalogError.unavailableInStorefront }
        await catalog.respond(to: .bundle(app.id, "jp")) { japaneseEntry }
        await catalog.respond(to: .bundle(app.id, "us")) { americanEntry }
        let model = try storefrontModel(for: app, catalog: catalog, countries: ["TW", "JP", "US"])

        await model.refresh()

        let requests = await catalog.requests
        XCTAssertEqual(requests, [.bundle(app.id, "tw"), .bundle(app.id, "jp")])
        XCTAssertEqual(model.row(for: app).entry, japaneseEntry)
        XCTAssertEqual(model.row(for: app).country, "JP")
        XCTAssertEqual(model.row(for: app).state, .update)
    }

    func testBundleLookupReportsNotFoundAfterAllStorefrontsMiss() async throws {
        let app = deviceApp("test.app")
        let catalog = CatalogFixture()
        let model = try storefrontModel(for: app, catalog: catalog, countries: ["TW", "US", "JP"])

        await model.refresh()

        let requests = await catalog.requests
        XCTAssertEqual(requests, [.bundle(app.id, "tw"), .bundle(app.id, "us"), .bundle(app.id, "jp")])
        let row = model.row(for: app)
        XCTAssertEqual(row.state, .notFound)
        XCTAssertNil(row.entry)
        XCTAssertNil(row.country)
        XCTAssertNil(model.boundID(for: app.id))
    }

    func testHardNetworkErrorStopsBundleLookupAndManualPreview() async throws {
        let app = deviceApp("test.app")
        let entry = storeEntry(bundleID: app.id)
        let catalog = CatalogFixture()
        await catalog.respond(to: .bundle(app.id, "jp")) { throw FixtureError.offline }
        await catalog.respond(to: .bundle(app.id, "us")) { entry }
        await catalog.respond(to: .id(entry.id, "jp")) { throw FixtureError.offline }
        await catalog.respond(to: .id(entry.id, "us")) { entry }
        let model = try storefrontModel(for: app, catalog: catalog, countries: ["TW", "JP", "US"])

        await model.refresh()

        XCTAssertEqual(model.row(for: app).state, .queryFailed)
        XCTAssertNil(model.row(for: app).entry)
        XCTAssertNil(model.row(for: app).country)
        do {
            _ = try await model.previewBinding("https://apps.apple.com/tw/app/original/id42")
            XCTFail("Expected the catalog error to stop manual preview")
        } catch FixtureError.offline {}

        let requests = await catalog.requests
        XCTAssertEqual(requests, [
            .bundle(app.id, "tw"), .bundle(app.id, "jp"),
            .id(entry.id, "tw"), .id(entry.id, "jp")
        ])
    }

    func testManualPreviewAndBoundRefreshFallBackAcrossStorefronts() async throws {
        let app = deviceApp("test.resigned")
        let original = storeEntry(bundleID: "test.original")
        let newerOriginal = storeEntry(bundleID: original.bundleID, version: "3.11")
        let catalog = CatalogFixture()
        await catalog.respond(to: .id(original.id, "tw")) { throw StoreCatalogError.unavailableInStorefront }
        await catalog.respond(to: .id(original.id, "jp")) { original }
        let model = try storefrontModel(for: app, catalog: catalog, countries: ["TW", "JP"])
        await model.refresh()

        let preview = try await model.previewBinding("https://apps.apple.com/tw/app/original/id42")
        XCTAssertEqual(preview.entry, original)
        XCTAssertEqual(preview.country, "JP")
        XCTAssertNil(model.boundID(for: app.id))
        XCTAssertTrue(model.confirmBinding(preview, for: app.id))
        XCTAssertEqual(model.row(for: app).country, "JP")

        await catalog.respond(to: .id(original.id, "jp")) { newerOriginal }
        await model.refresh()

        let refreshRequests = await catalog.requests
        XCTAssertEqual(refreshRequests, [
            .bundle(app.id, "tw"), .bundle(app.id, "jp"),
            .id(original.id, "tw"), .id(original.id, "jp"),
            .id(original.id, "tw"), .id(original.id, "jp")
        ])
        XCTAssertEqual(model.boundID(for: app.id), original.id)
        XCTAssertEqual(model.row(for: app).entry, newerOriginal)
        XCTAssertEqual(model.row(for: app).country, "JP")

        await catalog.respond(to: .id(original.id, "tw")) { throw FixtureError.offline }
        await model.refresh()

        let failedRequests = await catalog.requests
        XCTAssertEqual(failedRequests, refreshRequests + [.id(original.id, "tw")])
        XCTAssertEqual(model.row(for: app).state, .queryFailed)
        XCTAssertTrue(model.row(for: app).isStale)
        XCTAssertEqual(model.row(for: app).entry, newerOriginal)
    }

    func testReorderingStorefrontsChangesTheWinningRegion() async throws {
        let app = deviceApp("test.app")
        let taiwaneseEntry = storeEntry(bundleID: app.id)
        let japaneseEntry = storeEntry(bundleID: app.id, version: "4.0")
        let catalog = CatalogFixture()
        await catalog.respond(to: .bundle(app.id, "tw")) { taiwaneseEntry }
        await catalog.respond(to: .bundle(app.id, "jp")) { japaneseEntry }
        await catalog.respond(to: .id(japaneseEntry.id, "jp")) { japaneseEntry }
        await catalog.respond(to: .id(taiwaneseEntry.id, "tw")) { taiwaneseEntry }
        let model = try storefrontModel(for: app, catalog: catalog, countries: ["TW", "JP"])
        await model.refresh()

        XCTAssertEqual(model.row(for: app).country, "TW")
        XCTAssertEqual(model.row(for: app).entry, taiwaneseEntry)

        model.setCountries(["JP", "TW"])
        await model.refresh()

        let requests = await catalog.requests
        XCTAssertEqual(requests, [.bundle(app.id, "tw"), .id(japaneseEntry.id, "jp")])
        XCTAssertEqual(model.countries, ["JP", "TW"])
        XCTAssertEqual(model.row(for: app).country, "JP")
        XCTAssertEqual(model.row(for: app).entry, japaneseEntry)
    }

    func testLegacyStorefrontMigratesAndOrderedCountriesPersist() async throws {
        let defaults = try isolatedDefaults()
        let legacy = Data("""
        {
            "country": "TW",
            "rules": [],
            "overrides": {},
            "independentVersions": [],
            "bindings": {"test.resigned": 42},
            "cache": [],
            "fingerprintsByName": {}
        }
        """.utf8)
        defaults.set(legacy, forKey: "SideloadUpdater.settings.v1")
        let inventory = InventoryFixture([])
        let catalog = CatalogFixture()
        let model = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)

        XCTAssertEqual(model.countries, ["TW"])
        XCTAssertEqual(model.boundID(for: "test.resigned"), 42)
        model.setCountries(["JP", "TW", "US"])

        let restarted = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)
        XCTAssertEqual(restarted.countries, ["JP", "TW", "US"])
        XCTAssertEqual(restarted.boundID(for: "test.resigned"), 42)
    }

    func testScanAndCatalogFailuresPreserveSuccessfulDataUntilRecovery() async throws {
        let app = deviceApp("test.app")
        let original = storeEntry(bundleID: app.id)
        let inventory = InventoryFixture([app])
        let catalog = CatalogFixture()
        let defaults = try isolatedDefaults()
        await catalog.respond(to: .bundle(app.id, "tw")) { original }
        let model = try await trackedModel(for: app, inventory: inventory, catalog: catalog, defaults: defaults)

        let firstScan = try XCTUnwrap(model.lastScan)
        let firstCheck = try XCTUnwrap(model.row(for: app).checkedAt)
        XCTAssertEqual(model.row(for: app).state, .update)

        await inventory.setResult(.failure(.offline))
        await model.refresh()
        guard case .offline = model.connection else {
            return XCTFail("Expected an offline connection after the failed scan")
        }
        XCTAssertEqual(model.apps.map(\.id), [app.id])
        XCTAssertEqual(model.app(app.id)?.version, app.version)
        XCTAssertEqual(model.lastScan, firstScan)
        XCTAssertEqual(model.row(for: app).checkedAt, firstCheck)
        XCTAssertEqual(model.row(for: app).entry, original)
        XCTAssertEqual(model.row(for: app).state, .stale)
        XCTAssertTrue(model.row(for: app).isStale)
        let requestsAfterFailedScan = await catalog.requests
        XCTAssertEqual(requestsAfterFailedScan, [.bundle(app.id, "tw")])

        let restarted = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)
        XCTAssertEqual(restarted.apps.map(\.id), [app.id])
        XCTAssertEqual(restarted.lastScan, firstScan)
        XCTAssertEqual(restarted.row(for: app).checkedAt, firstCheck)

        await inventory.setResult(.success([app]))
        await catalog.respond(to: .id(original.id, "tw")) { throw FixtureError.offline }
        await model.refresh()
        XCTAssertEqual(model.row(for: app).state, .queryFailed)
        XCTAssertEqual(model.row(for: app).checkedAt, firstCheck)
        XCTAssertEqual(model.row(for: app).entry, original)
        XCTAssertTrue(model.row(for: app).isStale)

        let recovered = storeEntry(bundleID: app.id, version: "3.9.0")
        await catalog.respond(to: .id(original.id, "tw")) { recovered }
        await model.refresh()
        let current = model.row(for: app)
        XCTAssertEqual(current.state, .equal)
        XCTAssertEqual(current.entry, recovered)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(current.checkedAt), firstCheck)
        XCTAssertFalse(current.isStale)
    }

    func testOlderInFlightLookupCannotOverwriteReconfirmedSameID() async throws {
        let app = deviceApp("test.app")
        let original = storeEntry(bundleID: app.id)
        let refreshed = storeEntry(bundleID: app.id, version: "3.11")
        let inventory = InventoryFixture([app])
        let catalog = CatalogFixture()
        await catalog.respond(to: .bundle(app.id, "tw")) { original }
        await catalog.respond(to: .id(original.id, "tw")) { refreshed }
        let model = try await trackedModel(
            for: app, inventory: inventory, catalog: catalog, defaults: isolatedDefaults()
        )
        let preview = try await model.previewBinding("https://apps.apple.com/tw/app/original/id42")

        let started = expectation(description: "Numeric refresh is waiting for its catalog response")
        let gate = LookupGate()
        await catalog.respond(to: .id(original.id, "tw")) {
            await gate.wait(signaling: started)
            throw FixtureError.offline
        }
        let refresh = Task { await model.refresh() }
        let waitResult = await XCTWaiter.fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(waitResult, .completed)
        XCTAssertTrue(model.confirmBinding(preview, for: app.id))
        await gate.release()
        await refresh.value

        let current = model.row(for: app)
        XCTAssertEqual(current.entry, refreshed)
        XCTAssertEqual(current.checkedAt, preview.checkedAt)
        XCTAssertEqual(current.state, .update)
        XCTAssertFalse(current.isStale)
    }

    func testColdLaunchScansAndWarmReturnPreservesListUntilManualRefresh() async throws {
        let first = deviceApp("test.first")
        let second = deviceApp("test.second")
        let inventory = InventoryFixture([first])
        let defaults = try isolatedDefaults()
        let catalog = CatalogFixture()
        let model = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)

        await model.refreshIfNeededOnActivation()
        XCTAssertEqual(model.apps.map(\.id), [first.id])
        await inventory.setResult(.success([second]))
        await model.refreshIfNeededOnActivation()
        XCTAssertEqual(model.apps.map(\.id), [first.id])
        await model.refresh()
        XCTAssertEqual(model.apps.map(\.id), [second.id])

        await inventory.setResult(.success([first]))
        let relaunched = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)
        await relaunched.refreshIfNeededOnActivation()
        XCTAssertEqual(relaunched.apps.map(\.id), [first.id])
    }

    func testLocalPairingSurvivesFirstScanFailureAndRelaunch() async throws {
        let inventory = InventoryFixture([])
        let defaults = try isolatedDefaults()
        let model = UpdaterModel(inventory: inventory, catalog: CatalogFixture(), defaults: defaults)
        await inventory.setResult(.failure(.offline))
        await model.pair()
        XCTAssertEqual(model.remotePairingStatus, .paired)
        XCTAssertTrue(model.hasSavedPairing)
        guard case .offline = model.connection else { return XCTFail("Expected post-pairing scan failure") }

        let relaunched = UpdaterModel(inventory: inventory, catalog: CatalogFixture(), defaults: defaults)
        await relaunched.refresh()
        XCTAssertTrue(relaunched.hasSavedPairing)
        XCTAssertNil(relaunched.lastScan)
        await inventory.setResult(.success([]))
        await relaunched.refresh()
        XCTAssertNotNil(relaunched.lastScan)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "UpdaterModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func storefrontModel(
        for app: DeviceApp, catalog: CatalogFixture, countries: [String]
    ) throws -> UpdaterModel {
        let model = UpdaterModel(inventory: InventoryFixture([app]), catalog: catalog, defaults: try isolatedDefaults())
        model.setTracking(.include, for: app.id)
        model.setCountries(countries)
        return model
    }

    private func trackedModel(
        for app: DeviceApp,
        inventory: InventoryFixture,
        catalog: CatalogFixture,
        defaults: UserDefaults
    ) async throws -> UpdaterModel {
        let model = UpdaterModel(inventory: inventory, catalog: catalog, defaults: defaults)
        await model.refresh()
        model.addRule(from: app.id, expected: try XCTUnwrap(model.rule(for: app)))
        model.setCountry("TW")
        await model.refresh()
        return model
    }
}

private enum FixtureError: Error {
    case offline
}

private actor InventoryFixture: UpdaterInventory {
    private var paired = false
    private var result: Result<[DeviceApp], FixtureError>

    init(_ apps: [DeviceApp]) {
        result = .success(apps)
    }

    func setResult(_ result: Result<[DeviceApp], FixtureError>) {
        self.result = result
    }

    func scan() async throws -> [DeviceApp] { try result.get() }
    func hasSavedPairing() async throws -> Bool { paired }
    func pair() async throws { paired = true }
    nonisolated func forget() throws {}
}

private actor CatalogFixture: UpdaterCatalog {
    enum Request: Hashable {
        case bundle(String, String)
        case id(Int64, String)
    }

    private var responses: [Request: @Sendable () async throws -> StoreEntry?] = [:]
    private(set) var requests: [Request] = []

    func respond(to request: Request, with response: @escaping @Sendable () async throws -> StoreEntry?) {
        responses[request] = response
    }

    func lookup(bundleID: String, country: String) async throws -> StoreEntry? {
        try await lookup(.bundle(bundleID, country))
    }

    func lookup(id: Int64, country: String) async throws -> StoreEntry? {
        try await lookup(.id(id, country))
    }

    private func lookup(_ request: Request) async throws -> StoreEntry? {
        requests.append(request)
        return try await responses[request]?()
    }
}

private actor LookupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait(signaling started: XCTestExpectation) async {
        started.fulfill()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private func deviceApp(
    _ id: String,
    signer: String = "Example Signing Identity",
    fingerprint: String? = nil,
    sideloaded: Bool? = nil
) -> DeviceApp {
    DeviceApp(
        id: id, name: id, version: "3.9", signer: signer,
        certificateFingerprint: fingerprint, isSideloadCandidate: sideloaded
    )
}

private func storeEntry(bundleID: String, version: String = "3.10") -> StoreEntry {
    StoreEntry(id: 42, bundleID: bundleID, name: "Original", artist: "Developer", version: version)
}
