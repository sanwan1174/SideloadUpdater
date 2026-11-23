import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct StoreEntry: Codable, Equatable, Sendable {
    let id: Int64
    let bundleID: String
    let name: String
    let artist: String
    let version: String
    var artwork: URL? = nil
}

enum StoreCatalogError: LocalizedError, Equatable {
    case invalidCountry
    case invalidID
    case invalidResponse
    case httpStatus(Int)
    case unavailableInStorefront
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .invalidCountry: coreString("catalog.invalidCountry")
        case .invalidID: coreString("catalog.invalidID")
        case .invalidResponse: coreString("catalog.invalidResponse")
        case .httpStatus(let status): coreString("catalog.httpStatus", String(status))
        case .unavailableInStorefront: coreString("catalog.unavailableInStorefront")
        case .rateLimited: coreString("catalog.rateLimited")
        }
    }
}

struct StoreCatalog: Sendable {
    private let load: @Sendable (URL) async throws -> (Data, URLResponse)

    init(session: URLSession = .shared) {
        load = { try await session.data(from: $0) }
    }

    init(load: @escaping @Sendable (URL) async throws -> (Data, URLResponse)) {
        self.load = load
    }

    func lookup(bundleID: String, country: String) async throws -> StoreEntry? {
        try await lookup(URLQueryItem(name: "bundleId", value: bundleID), country: country, knownID: false) {
            $0.bundleId == bundleID
        }
    }

    func lookup(id: Int64, country: String) async throws -> StoreEntry? {
        guard id > 0 else { throw StoreCatalogError.invalidID }
        return try await lookup(URLQueryItem(name: "id", value: String(id)), country: country, knownID: true) {
            $0.trackId == id
        }
    }

    private func lookup(
        _ identifier: URLQueryItem,
        country: String,
        knownID: Bool,
        matching matches: (LookupRow) -> Bool
    ) async throws -> StoreEntry? {
        let country = country.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isStorefrontCode(country) else { throw StoreCatalogError.invalidCountry }
        let storefront = country.lowercased()
        let localRows = try await rows(for: identifier, storefront: storefront).filter(matches)
        try Task.checkCancellation()
        if localRows.count == 1 {
            guard let entry = localRows[0].entry else { throw StoreCatalogError.invalidResponse }
            return entry
        }
        if localRows.isEmpty, knownID {
            throw StoreCatalogError.unavailableInStorefront
        }
        return nil
    }

    private func rows(for identifier: URLQueryItem, storefront: String) async throws -> [LookupRow] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        components.queryItems = [
            identifier,
            URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "entity", value: "software")
        ]
        guard let url = components.url else { throw StoreCatalogError.invalidResponse }
        let data = try await request(url, canRetry: true)
        guard let response = try? JSONDecoder().decode(LookupResponse.self, from: data),
              response.resultCount == response.results.count else {
            throw StoreCatalogError.invalidResponse
        }
        return response.results.filter(\.isPhoneSoftware)
    }

    private func request(_ url: URL, canRetry: Bool) async throws -> Data {
        let (data, response) = try await load(url)
        guard let http = response as? HTTPURLResponse else { throw StoreCatalogError.invalidResponse }
        if http.statusCode == 429 {
            let retryAfter = Self.retryDelay(from: http.value(forHTTPHeaderField: "Retry-After"))
            let delay = retryAfter ?? 1
            guard canRetry, delay <= 5 else {
                throw StoreCatalogError.rateLimited(retryAfter: retryAfter)
            }
            try await Task.sleep(for: .seconds(delay))
            return try await request(url, canRetry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StoreCatalogError.httpStatus(http.statusCode)
        }
        return data
    }

    private static func retryDelay(from header: String?) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private struct LookupResponse: Decodable {
        let resultCount: Int
        let results: [LookupRow]
    }

    private struct LookupRow: Decodable {
        private enum CodingKeys: String, CodingKey {
            case wrapperType, kind, trackId, bundleId, trackName, artistName, version, artworkUrl100
        }

        let isPhoneSoftware: Bool
        let trackId: Int64?
        let bundleId: String?
        let entry: StoreEntry?

        init(from decoder: Decoder) throws {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            let wrapper = try? fields?.decode(String.self, forKey: .wrapperType)
            let kind = try? fields?.decode(String.self, forKey: .kind)
            isPhoneSoftware = wrapper == "software" && kind == "software"
            trackId = try? fields?.decode(Int64.self, forKey: .trackId)
            bundleId = try? fields?.decode(String.self, forKey: .bundleId)

            guard let id = trackId, id > 0, let bundleID = bundleId,
                  let name = try? fields?.decode(String.self, forKey: .trackName),
                  let artist = try? fields?.decode(String.self, forKey: .artistName),
                  let version = try? fields?.decode(String.self, forKey: .version),
                  [bundleID, name, artist, version].allSatisfy({
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else {
                entry = nil
                return
            }
            let artwork = (try? fields?.decode(String.self, forKey: .artworkUrl100))
                .flatMap(URL.init(string:))
                .flatMap { $0.scheme == "https" ? $0 : nil }
            entry = StoreEntry(id: id, bundleID: bundleID, name: name, artist: artist, version: version, artwork: artwork)
        }
    }
}

enum VersionStatus: Equatable, Sendable {
    case newer, equal, older, incomparable
}

func compareVersions(installed: String?, store: String?) -> VersionStatus {
    guard let installed = versionComponents(installed), let store = versionComponents(store) else {
        return .incomparable
    }
    for index in 0..<max(installed.count, store.count) {
        let localPart = index < installed.count ? installed[index] : ""
        let storePart = index < store.count ? store[index] : ""
        if localPart.count != storePart.count {
            return storePart.count > localPart.count ? .newer : .older
        }
        if localPart != storePart {
            return storePart.lexicographicallyPrecedes(localPart) ? .older : .newer
        }
    }
    return .equal
}

private func versionComponents(_ value: String?) -> [Substring]? {
    guard let value, !value.isEmpty else { return nil }
    let components = value.split(separator: ".", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isASCIIDigit) }) else { return nil }
    return components.map { $0.drop(while: { $0 == "0" }) }
}

func storeID(from text: String) -> Int64? {
    guard let link = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          link.scheme?.lowercased() == "https",
          let host = link.host?.lowercased(), ["apps.apple.com", "itunes.apple.com"].contains(host),
          link.user == nil, link.password == nil, link.port == nil else { return nil }

    let path = link.percentEncodedPath.split(separator: "/")
    let appPath = path.first.map { isStorefrontCode(String($0)) } == true ? path.dropFirst() : path[...]
    guard (2...3).contains(appPath.count), appPath.first == "app",
          let idPart = appPath.last, idPart.hasPrefix("id") else { return nil }
    let digits = idPart.dropFirst(2)
    guard !digits.isEmpty, digits.utf8.allSatisfy(isASCIIDigit),
          let id = Int64(digits), id > 0 else { return nil }
    return id
}

private func isASCIIDigit(_ byte: UInt8) -> Bool {
    (48...57).contains(byte)
}

private func isStorefrontCode(_ value: String) -> Bool {
    value.utf8.count == 2 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) }
}
