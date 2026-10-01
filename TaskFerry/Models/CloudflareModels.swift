import Foundation

struct CloudflareZone: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let accountID: String
    let accountName: String
}

struct CloudflareProvisioning: Codable, Equatable, Sendable {
    let accountID: String
    let zoneID: String
    let tunnelID: String
    let accessApplicationID: String
    let serviceTokenID: String
    let dnsRecordID: String
    let hostname: String
}

struct CloudflareProvisioningSecrets: Equatable, Sendable {
    let tunnelToken: String
    let accessClientID: String
    let accessClientSecret: String
}

struct CloudflareProvisioningResult: Equatable, Sendable {
    let provisioning: CloudflareProvisioning
    let secrets: CloudflareProvisioningSecrets
}

/// Non-secret resource identifiers retained until provisioning commits or cleanup succeeds.
struct CloudflareCleanup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let accountID: String
    let zoneID: String
    let hostname: String
    var tunnelID: String?
    var serviceTokenID: String?
    var accessApplicationID: String?
    var dnsRecordID: String?

    var isEmpty: Bool {
        tunnelID == nil && serviceTokenID == nil && accessApplicationID == nil && dnsRecordID == nil
    }

    init(accountID: String, zoneID: String, hostname: String) {
        self.accountID = accountID
        self.zoneID = zoneID
        self.hostname = hostname
    }

    init(_ provisioning: CloudflareProvisioning) {
        accountID = provisioning.accountID
        zoneID = provisioning.zoneID
        hostname = provisioning.hostname
        tunnelID = provisioning.tunnelID
        serviceTokenID = provisioning.serviceTokenID
        accessApplicationID = provisioning.accessApplicationID
        dnsRecordID = provisioning.dnsRecordID
    }
}

struct CloudflareCleanupError: LocalizedError {
    let message: String
    let remaining: CloudflareCleanup

    var errorDescription: String? {
        "\(message) Cleanup is incomplete for \(remaining.hostname). Retry Cleanup in Settings → Bridge."
    }
}

enum CloudflareConnectorState: Equatable, Sendable {
    case notConfigured
    case stopped
    case starting
    case connected
    case reconnecting
    case failed(String)
}

struct TaskFerryConnectionCode: Codable, Equatable, Sendable {
    private static let prefix = "TASKFERRY1:"

    let endpoint: String
    let accessClientID: String
    let accessClientSecret: String
    let bridgeToken: String

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + payload
    }

    static func decode(_ value: String) throws -> Self {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else {
            throw ReminderServiceError.message("That is not a Task Ferry connection code.")
        }
        var payload = String(trimmed.dropFirst(prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload) else {
            throw ReminderServiceError.message("The Task Ferry connection code is invalid.")
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw ReminderServiceError.message("The Task Ferry connection code is invalid.")
        }
    }
}
