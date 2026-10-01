import Foundation
import Observation

/// Persists non-secret resource IDs independently of a successful connection setup.
@MainActor
@Observable
final class CloudflareCleanupStore {
    private(set) var pending: [CloudflareCleanup]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "cloudflare-pending-cleanup"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let records = try? JSONDecoder().decode([CloudflareCleanup].self, from: data) {
            pending = records
        } else {
            pending = []
        }
    }

    func record(_ cleanup: CloudflareCleanup) throws {
        var updated = pending.filter { $0.id != cleanup.id }
        if !cleanup.isEmpty { updated.append(cleanup) }
        try save(updated)
    }

    func commit(_ provisioning: CloudflareProvisioning) throws {
        try save(pending.filter {
            $0.accountID != provisioning.accountID || $0.tunnelID != provisioning.tunnelID
        })
    }

    private func save(_ records: [CloudflareCleanup]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: Self.key)
        pending = records
    }
}
