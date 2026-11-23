import XCTest
@testable import UpdaterCore

final class DeviceAppTests: XCTestCase {
    func testLookupUsesMarketingVersionAndPreservesSignatureEvidence() throws {
        let fields: [String: Any] = ["SignerIdentity": "Apple Development: Example",
                                     "CFBundleShortVersionString": "3.9", "CFBundleVersion": "325",
                                     "Entitlements": ["get-task-allow": true], "ProfileValidated": true]
        let app = try XCTUnwrap(DeviceApp(lookupID: "local.test", metadata: fields))
        XCTAssertEqual(app.version, "3.9")
        XCTAssertEqual(app.isSideloadCandidate, true)
        XCTAssertEqual(app.isDeveloperApp, true)
        XCTAssertEqual(app.hasSideloadProfile, true)
        XCTAssertNil(app.certificateFingerprint)
    }

    func testStoreDistributionUnknownAndDeveloperOnlyRemainDistinct() {
        XCTAssertEqual(DeviceApp(lookupID: "store", metadata: ["SignerIdentity": "Apple iPhone OS Application Signing"])?.isSideloadCandidate, false)
        let unknown = DeviceApp(lookupID: "user", metadata: ["ApplicationType": "User", "IsDeveloperApp": true])
        XCTAssertNil(unknown?.isSideloadCandidate)
        XCTAssertEqual(unknown?.isDeveloperApp, true)
        XCTAssertNil(unknown?.version)
        XCTAssertNil(DeviceApp(lookupID: "first", metadata: ["CFBundleIdentifier": "second"]))
    }
}
