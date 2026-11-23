import Foundation

struct DeviceApp: Identifiable, Codable {
    let id: String
    let name: String
    let version: String?
    let signer: String?
    let certificateFingerprint: String?
    let isSideloadCandidate: Bool?
    var isDeveloperApp: Bool? = nil
    var hasSideloadProfile: Bool? = nil
}

extension DeviceApp {
    init?(lookupID: String, metadata: [String: Any]) {
        func text(_ key: String) -> String? {
            guard let value = metadata[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard !lookupID.isEmpty,
              metadata["CFBundleIdentifier"] == nil || text("CFBundleIdentifier") == lookupID else { return nil }
        let signer = text("SignerIdentity")
        let entitlements = metadata["Entitlements"] as? [String: Any]
        let developerFlag = (metadata["IsDeveloperApp"] ?? metadata["isDeveloperApp"]) as? Bool
        let development = developerFlag ?? entitlements?["get-task-allow"] as? Bool
        let candidate: Bool?
        if signer?.hasPrefix("Apple iPhone OS Application Signing") == true ||
            entitlements?["beta-reports-active"] as? Bool == true {
            candidate = false
        } else if metadata["ProfileValidated"] as? Bool == true && (signer != nil || entitlements != nil) {
            candidate = true
        } else {
            candidate = nil
        }
        self.init(id: lookupID, name: text("CFBundleDisplayName") ?? text("CFBundleName") ?? lookupID,
                  version: text("CFBundleShortVersionString"), signer: signer,
                  certificateFingerprint: nil, isSideloadCandidate: candidate, isDeveloperApp: development,
                  hasSideloadProfile: candidate == true ? true : nil)
    }
}
