import Foundation
import IDevice
import UIKit
import dnssd

private enum LocalPairingHostError: LocalizedError {
    case unsupported
    case wifi
    case advertisement
    case timeout
    case rejected
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unsupported:
            NSLocalizedString("pairing.host.error.unsupported", tableName: "Pairing", comment: "Six-digit pairing requires a newer version of iOS")
        case .wifi:
            NSLocalizedString("pairing.host.error.wifi", tableName: "Pairing", comment: "Pairing needs a Wi-Fi connection")
        case .advertisement:
            NSLocalizedString("pairing.host.error.advertisement", tableName: "Pairing", comment: "Could not advertise the pairing host on the local network")
        case .timeout:
            NSLocalizedString("pairing.host.error.timeout", tableName: "Pairing", comment: "The pairing attempt timed out")
        case .rejected:
            NSLocalizedString("pairing.host.error.rejected", tableName: "Pairing", comment: "The pairing attempt was rejected")
        case .unavailable:
            NSLocalizedString("pairing.host.error.unavailable", tableName: "Pairing", comment: "Could not start pairing")
        }
    }
}

enum LocalPairingHost {
    @MainActor
    static func pair(
        onCode: @escaping @Sendable (String) -> Void,
        save: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        guard #available(iOS 27, *) else { throw LocalPairingHostError.unsupported }
        try Task.checkCancellation()
        guard let attempt = PairingHostAttempt(onCode: onCode) else {
            throw LocalPairingHostError.unavailable
        }
        let background = PairingHostBackgroundTask()
        background.identifier = UIApplication.shared.beginBackgroundTask(withName: "Pair with iPhone") {
            attempt.cancel()
            Task { @MainActor in background.end() }
        }
        defer { background.end() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PairingHostAttempt.worker.async {
                    continuation.resume(with: Result { try save(attempt.accept()) })
                }
            }
        } onCancel: {
            attempt.cancel()
        }
    }
}

@MainActor
private final class PairingHostBackgroundTask {
    var identifier: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard identifier != .invalid else { return }
        let task = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
}

private final class PairingHostAttempt: @unchecked Sendable {
    static let worker = DispatchQueue(label: "shen3w.sideloadupdater.pairing-host", qos: .userInitiated)
    private static let publishing = DispatchQueue(label: "shen3w.sideloadupdater.pairing-bonjour")

    private let cancellation: OpaquePointer
    private let onCode: @Sendable (String) -> Void
    private var advertisement: DNSServiceRef?
    private var advertisementFailed = false

    init?(onCode: @escaping @Sendable (String) -> Void) {
        guard let cancellation = updater_pairing_cancel_new() else { return nil }
        self.cancellation = cancellation
        self.onCode = onCode
    }

    deinit {
        updater_pairing_cancel_free(cancellation)
    }

    func cancel() {
        updater_pairing_cancel(cancellation)
    }

    func accept() throws -> Data {
        var record: UnsafeMutablePointer<UInt8>?
        var length: UInt = 0
        defer { updater_inventory_free(record, length) }
        let status = updater_pairing_accept(
            cancellation,
            { context, name, interface, port, txt, length in
                guard let attempt = PairingHostAttempt.from(context),
                      let name, let txt else { return false }
                return attempt.publish(name: name, interface: interface, port: port, txt: txt, length: length)
            },
            { context, code in
                guard let attempt = PairingHostAttempt.from(context),
                      let code, let value = String(validatingCString: code) else { return }
                DispatchQueue.main.sync { attempt.onCode(value) }
            },
            Unmanaged.passUnretained(self).toOpaque(),
            &record,
            &length
        )
        let publishFailed = Self.publishing.sync {
            if let advertisement {
                DNSServiceRefDeallocate(advertisement)
                self.advertisement = nil
            }
            return advertisementFailed
        }
        if publishFailed && status != 0 { throw LocalPairingHostError.advertisement }
        switch status {
        case 0:
            guard let record, length > 0 else { throw LocalPairingHostError.unavailable }
            return Data(bytes: record, count: Int(length))
        case 1: throw LocalPairingHostError.wifi
        case 2: throw LocalPairingHostError.advertisement
        case 3: throw LocalPairingHostError.timeout
        case 4: throw LocalPairingHostError.rejected
        case 5: throw CancellationError()
        default: throw LocalPairingHostError.unavailable
        }
    }

    private func publish(
        name: UnsafePointer<CChar>,
        interface: UInt32,
        port: UInt16,
        txt: UnsafePointer<UInt8>,
        length: UInt16
    ) -> Bool {
        Self.publishing.sync {
            var registration: DNSServiceRef?
            let status = DNSServiceRegister(
                &registration,
                DNSServiceFlags(kDNSServiceFlagsNoAutoRename),
                interface,
                name,
                "_remotepairing-pairable-host._tcp",
                "local.",
                nil,
                port.bigEndian,
                length,
                txt,
                { _, _, error, _, _, _, context in
                    guard error != kDNSServiceErr_NoError,
                          let attempt = PairingHostAttempt.from(context) else { return }
                    attempt.advertisementFailed = true
                    attempt.cancel()
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let registration else { return false }
            guard DNSServiceSetDispatchQueue(registration, Self.publishing) == kDNSServiceErr_NoError else {
                DNSServiceRefDeallocate(registration)
                return false
            }
            advertisement = registration
            return true
        }
    }

    private static func from(_ context: UnsafeMutableRawPointer?) -> PairingHostAttempt? {
        context.map { Unmanaged<PairingHostAttempt>.fromOpaque($0).takeUnretainedValue() }
    }
}
