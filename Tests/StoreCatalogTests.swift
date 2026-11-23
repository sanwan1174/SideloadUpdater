import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import UpdaterCore

final class StoreCatalogTests: XCTestCase {
    func testBundleLookupRequiresOneExactPhoneSoftwareMatch() async throws {
        let matching = row(id: 42)
        let catalog = StoreCatalog { url in
            XCTAssertEqual(url.host, "itunes.apple.com")
            XCTAssertEqual(url.path, "/lookup")
            XCTAssertEqual(query(url), ["bundleId": "example.app", "country": "tw", "entity": "software"])
            return response(url, rows: [
                row(id: 41, bundleID: "Example.app"),
                row(id: 43, kind: "iPadSoftware"),
                row(id: 44, wrapperType: "track"),
                matching,
                "null"
            ])
        }
        let entry = try await catalog.lookup(bundleID: "example.app", country: " TW ")
        XCTAssertEqual(entry, StoreEntry(id: 42, bundleID: "example.app", name: "Example", artist: "Developer", version: "3.10"))

        let ambiguous = StoreCatalog { url in
            XCTAssertEqual(query(url)["country"], "tw")
            return response(url, rows: [matching, row(id: 45)])
        }
        let ambiguousEntry = try await ambiguous.lookup(bundleID: "example.app", country: "TW")
        XCTAssertNil(ambiguousEntry)
    }

    func testIDLookupRejectsMismatchedIDAndRequiresVersion() async throws {
        let catalog = StoreCatalog { url in
            XCTAssertEqual(query(url), ["id": "42", "country": "us", "entity": "software"])
            return response(url, rows: [row(id: 99), row(id: 42, bundleID: "original.app")])
        }
        let entry = try await catalog.lookup(id: 42, country: "US")
        XCTAssertEqual(entry?.id, 42)
        XCTAssertEqual(entry?.bundleID, "original.app")

        let malformed = StoreCatalog { url in
            response(url, rows: [row(id: 42, version: "")])
        }
        do {
            _ = try await malformed.lookup(id: 42, country: "US")
            XCTFail("An exact software entry requires a version")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testNumericIDMissReportsStorefrontUnavailabilityWithoutFallback() async throws {
        let catalog = StoreCatalog { url in
            XCTAssertEqual(query(url)["country"], "tw")
            return response(url, rows: [row(id: 99)])
        }
        do {
            _ = try await catalog.lookup(id: 42, country: "TW")
            XCTFail("Expected the numeric ID to be unavailable in the selected storefront")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .unavailableInStorefront)
        }
    }

    func testBundleMissQueriesOnlyTheRequestedStorefront() async throws {
        let attempts = Attempts()
        let catalog = StoreCatalog { url in
            _ = await attempts.next()
            XCTAssertEqual(query(url), ["bundleId": "example.app", "country": "tw", "entity": "software"])
            return response(url, rows: [])
        }
        let entry = try await catalog.lookup(bundleID: "example.app", country: "TW")
        XCTAssertNil(entry)
        let requestCount = await attempts.count
        XCTAssertEqual(requestCount, 1)
    }

    func testBundleLookupPropagatesTaskAndURLCancellation() async throws {
        let taskCancelled = StoreCatalog { url in
            XCTAssertEqual(query(url)["country"], "tw")
            throw CancellationError()
        }
        do {
            _ = try await taskCancelled.lookup(bundleID: "example.app", country: "TW")
            XCTFail("Expected task cancellation to propagate")
        } catch is CancellationError {}

        let requestCancelled = StoreCatalog { url in
            XCTAssertEqual(query(url)["country"], "tw")
            throw URLError(.cancelled)
        }
        do {
            _ = try await requestCancelled.lookup(bundleID: "example.app", country: "TW")
            XCTFail("Expected URL request cancellation to propagate")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
    }

    func testRejectsInvalidCountryAndIDBeforeNetworking() async throws {
        let catalog = StoreCatalog { url in
            XCTFail("An invalid lookup must not request \(url)")
            return response(url, rows: [])
        }
        for country in ["", "USA", "12", "U1", "éU"] {
            do {
                _ = try await catalog.lookup(id: 42, country: country)
                XCTFail("Accepted invalid country \(country)")
            } catch let error as StoreCatalogError {
                XCTAssertEqual(error, .invalidCountry)
            }
        }
        do {
            _ = try await catalog.lookup(id: 0, country: "US")
            XCTFail("Accepted a nonpositive store ID")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .invalidID)
        }
    }

    func testNetworkAndHTTPFailuresRemainErrors() async throws {
        let offline = StoreCatalog { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await offline.lookup(id: 42, country: "US")
            XCTFail("Expected the transport error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }

        let serverError = StoreCatalog { url in
            XCTAssertEqual(query(url)["country"], "tw")
            return response(url, rows: [], status: 503)
        }
        do {
            _ = try await serverError.lookup(bundleID: "example.app", country: "TW")
            XCTFail("Expected the HTTP failure")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .httpStatus(503))
        }
    }

    func testRateLimitRetriesOnceAndSurfacesRetryAfter() async throws {
        let attempts = Attempts()
        let recovers = StoreCatalog { url in
            if await attempts.next() == 1 {
                return response(url, rows: [], status: 429, retryAfter: "0")
            }
            return response(url, rows: [row(id: 42)])
        }
        let entry = try await recovers.lookup(id: 42, country: "US")
        XCTAssertEqual(entry?.id, 42)
        let recoveredCount = await attempts.count
        XCTAssertEqual(recoveredCount, 2)

        let limitedAttempts = Attempts()
        let limited = StoreCatalog { url in
            _ = await limitedAttempts.next()
            return response(url, rows: [], status: 429, retryAfter: "0")
        }
        do {
            _ = try await limited.lookup(id: 42, country: "US")
            XCTFail("Expected rate limiting after one retry")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 0))
        }
        let limitedCount = await limitedAttempts.count
        XCTAssertEqual(limitedCount, 2)

        let longDelay = StoreCatalog { url in
            response(url, rows: [], status: 429, retryAfter: "120")
        }
        do {
            _ = try await longDelay.lookup(id: 42, country: "US")
            XCTFail("Expected the server's longer retry delay")
        } catch let error as StoreCatalogError {
            XCTAssertEqual(error, .rateLimited(retryAfter: 120))
        }
    }

    func testVersionComparisonUsesNumericComponentsAndZeroPadding() {
        XCTAssertEqual(compareVersions(installed: "3.9", store: "3.10"), .newer)
        XCTAssertEqual(compareVersions(installed: "2.0", store: "2.0.0"), .equal)
        XCTAssertEqual(compareVersions(installed: "2.0.1", store: "02.00"), .older)
        XCTAssertEqual(compareVersions(installed: "1.99999999999999999999", store: "1.100000000000000000000"), .newer)
        for invalidVersion in [nil, "", "1..2", "2.0-beta", "２.０", " 2.0", "+2.0"] {
            XCTAssertEqual(compareVersions(installed: invalidVersion, store: "2.0"), .incomparable)
            XCTAssertEqual(compareVersions(installed: "2.0", store: invalidVersion), .incomparable)
        }
    }

    func testStoreIDParsesOnlyAppleAppLinksWithPositiveDecimalIDs() {
        XCTAssertEqual(storeID(from: " https://apps.apple.com/tw/app/sample/id42?l=en \n"), 42)
        XCTAssertEqual(storeID(from: "https://itunes.apple.com/us/app/id9223372036854775807?mt=8"), Int64.max)
        XCTAssertEqual(storeID(from: "https://apps.apple.com/app/id1"), 1)
        for invalidLink in [
            "https://apps.apple.com.example.org/us/app/id42",
            "https://apps.apple.com@evil.example/us/app/id42",
            "https://apps.apple.com/us/album/id42",
            "https://apps.apple.com/us/app?id=42",
            "https://apps.apple.com/us/app/id42/other",
            "https://apps.apple.com/us/app/id42text",
            "https://apps.apple.com/us/app/id0",
            "https://apps.apple.com/us/app/id9223372036854775808",
            "42"
        ] {
            XCTAssertNil(storeID(from: invalidLink), invalidLink)
        }
    }
}

private actor Attempts {
    private(set) var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
}

private func row(
    id: Int64,
    bundleID: String = "example.app",
    version: String = "3.10",
    kind: String = "software",
    wrapperType: String = "software"
) -> String {
    """
    {"trackId":\(id),"bundleId":"\(bundleID)","trackName":"Example","artistName":"Developer",\
    "version":"\(version)","kind":"\(kind)","wrapperType":"\(wrapperType)"}
    """
}

private func response(
    _ url: URL,
    rows: [String],
    status: Int = 200,
    retryAfter: String? = nil
) -> (Data, URLResponse) {
    let payload = #"{"resultCount":\#(rows.count),"results":[\#(rows.joined(separator: ","))]}"#
    let headers = retryAfter.map { ["Retry-After": $0] }
    let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    return (Data(payload.utf8), http)
}
