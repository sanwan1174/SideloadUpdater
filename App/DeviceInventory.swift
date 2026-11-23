import Foundation
import IDevice
import Security

enum DeviceInventoryError: LocalizedError {
    case needsPairing
    case loopbackUnavailable
    case pairingRejected
    case invalidRecord
    case inventoryUnavailable
    case keychainUnavailable
    case simulatorUnavailable

    var errorDescription: String? {
        switch self {
        case .needsPairing:
            NSLocalizedString("inventory.error.needsPairing", tableName: "Pairing", comment: "No pairing has been saved")
        case .loopbackUnavailable:
            NSLocalizedString("inventory.error.loopbackUnavailable", tableName: "Pairing", comment: "Could not connect to the device's loopback address")
        case .pairingRejected:
            NSLocalizedString("inventory.error.pairingRejected", tableName: "Pairing", comment: "The device rejected the saved pairing")
        case .invalidRecord:
            NSLocalizedString("inventory.error.invalidRecord", tableName: "Pairing", comment: "The pairing record is invalid")
        case .inventoryUnavailable:
            NSLocalizedString("inventory.error.inventoryUnavailable", tableName: "Pairing", comment: "Could not read the complete inventory")
        case .keychainUnavailable:
            NSLocalizedString("inventory.error.keychainUnavailable", tableName: "Pairing", comment: "Could not access the pairing key in Keychain")
        case .simulatorUnavailable:
            NSLocalizedString("inventory.error.simulatorUnavailable", tableName: "Pairing", comment: "The inventory requires a physical iPhone")
        }
    }
}

struct DeviceInventory {
    private static let worker = DispatchQueue(label: "shen3w.sideloadupdater.inventory", qos: .userInitiated)
    private static let storage = PairingStorage()
    private static let defaultPort: UInt16 = 49152
    private static let maximumRecordSize = 128 * 1024

    func hasSavedPairing() async throws -> Bool {
        try await Self.perform { try Self.storage.snapshot().0 != nil }
    }

    func scan() async throws -> [DeviceApp] {
        let discoveredPort = await LocalPairingPort.discover()
        return try await Self.perform {
            let (saved, revision) = try Self.storage.snapshot()
            guard let saved else { throw DeviceInventoryError.needsPairing }
            let result = try Self.readInventory(record: saved.data, port: discoveredPort ?? saved.port)
            try Self.storage.requireRevision(revision)
            return result.apps
        }
    }

    func pair() async throws {
        let discoveredPort = await LocalPairingPort.discover()
        try await Self.perform {
            let (saved, revision) = try Self.storage.snapshot()
            let port = discoveredPort ?? saved?.port ?? Self.defaultPort
            let result = try Self.readInventory(record: saved?.data, port: port)
            if let record = result.record {
                try Self.storage.save(PairingRecord(data: record, port: port), at: revision)
            } else {
                try Self.storage.requireRevision(revision)
            }
        }
    }

    func pair(onCode: @escaping @Sendable (String) -> Void) async throws {
        #if targetEnvironment(simulator)
        throw DeviceInventoryError.simulatorUnavailable
        #else
        let revision = Self.storage.currentRevision()
        let port = (try? Self.storage.snapshot().0?.port) ?? Self.defaultPort
        try await LocalPairingHost.pair(onCode: onCode) { record in
            try Self.storage.save(PairingRecord(data: record, port: port), at: revision)
        }
        #endif
    }

    func pair(recordAt url: URL, port: UInt16 = 49152) async throws {
        let discoveredPort = await LocalPairingPort.discover()
        try await Self.perform {
            let revision = Self.storage.currentRevision()
            let storedPort = (try? Self.storage.snapshot().0)?.port
            guard port != 0, url.isFileURL else { throw DeviceInventoryError.invalidRecord }
            let fallbackPort = port == Self.defaultPort ? (storedPort ?? port) : port
            let connectionPort = discoveredPort ?? fallbackPort
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let record: Data
            do {
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                guard let contents = try file.read(upToCount: Self.maximumRecordSize + 1),
                      !contents.isEmpty, contents.count <= Self.maximumRecordSize else {
                    throw DeviceInventoryError.invalidRecord
                }
                record = contents
            } catch {
                throw DeviceInventoryError.invalidRecord
            }
            _ = try Self.readInventory(record: record, port: connectionPort)
            try Self.storage.save(PairingRecord(data: record, port: connectionPort), at: revision)
        }
    }

    func forget() throws {
        try Self.storage.forget()
    }

    private static func perform<Result: Sendable>(
        _ work: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        #if targetEnvironment(simulator)
        throw DeviceInventoryError.simulatorUnavailable
        #else
        try Task.checkCancellation()
        let result: Result = try await withCheckedThrowingContinuation { continuation in
            worker.async {
                continuation.resume(with: Swift.Result { try work() })
            }
        }
        try Task.checkCancellation()
        return result
        #endif
    }

    private static func readInventory(record: Data?, port: UInt16) throws -> (apps: [DeviceApp], record: Data?) {
        var appsBytes: UnsafeMutablePointer<UInt8>?
        var appsLength: UInt = 0
        var recordBytes: UnsafeMutablePointer<UInt8>?
        var recordLength: UInt = 0
        defer {
            updater_inventory_free(appsBytes, appsLength)
            updater_inventory_free(recordBytes, recordLength)
        }
        let status = (record ?? Data()).withUnsafeBytes { bytes in
            updater_inventory_read(
                port, record == nil ? nil : bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count),
                &appsBytes, &appsLength, &recordBytes, &recordLength
            )
        }
        switch status {
        case 0: break
        case 1: throw DeviceInventoryError.loopbackUnavailable
        case 2: throw DeviceInventoryError.pairingRejected
        case 3: throw DeviceInventoryError.invalidRecord
        default: throw DeviceInventoryError.inventoryUnavailable
        }

        guard let appsBytes else { throw DeviceInventoryError.inventoryUnavailable }
        let plist = Data(bytes: appsBytes, count: Int(appsLength))
        guard let listed = (try? PropertyListSerialization.propertyList(from: plist, format: nil))
            as? [String: [String: Any]] else {
            throw DeviceInventoryError.inventoryUnavailable
        }

        let apps = try listed.map { id, fields in
            guard let app = DeviceApp(lookupID: id, metadata: fields) else {
                throw DeviceInventoryError.inventoryUnavailable
            }
            return app
        }
        return (apps.sorted { $0.id < $1.id }, recordBytes.map { Data(bytes: $0, count: Int(recordLength)) })
    }
}

private struct PairingRecord: Codable {
    let data: Data
    let port: UInt16
}

private final class PairingStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "shen3w.sideloadupdater",
            kSecAttrAccount as String: "remote-pairing.v1",
            kSecAttrSynchronizable as String: false
        ]
    }

    func snapshot() throws -> (PairingRecord?, Int) {
        try lock.withLock {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &item)
            if status == errSecItemNotFound { return (nil, revision) }
            guard status == errSecSuccess, let data = item as? Data else {
                throw DeviceInventoryError.keychainUnavailable
            }
            guard let record = try? PropertyListDecoder().decode(PairingRecord.self, from: data),
                  !record.data.isEmpty, record.port != 0 else {
                throw DeviceInventoryError.invalidRecord
            }
            return (record, revision)
        }
    }

    func requireRevision(_ expected: Int) throws {
        try lock.withLock {
            guard revision == expected else { throw CancellationError() }
        }
    }

    func currentRevision() -> Int {
        lock.withLock { revision }
    }

    func save(_ record: PairingRecord, at expected: Int) throws {
        let data = try PropertyListEncoder().encode(record)
        try lock.withLock {
            guard revision == expected else { throw CancellationError() }
            let values: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                let newItem = query.merging(values) { _, value in value }
                status = SecItemAdd(newItem as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw DeviceInventoryError.keychainUnavailable }
            revision &+= 1
        }
    }

    func forget() throws {
        try lock.withLock {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw DeviceInventoryError.keychainUnavailable
            }
            revision &+= 1
        }
    }
}
