import Foundation
import Observation

/// Owns role-scoped credentials and serializes complete Keychain transactions off the main thread.
/// A revision invalidates reads and saves whenever a role or connection changes.
@MainActor
@Observable
final class CredentialManager {
    struct StoredCredentials: Sendable {
        var accessClientID: String
        var accessClientSecret: String
        var bridgeToken: String
        var tunnelToken: String

        static let empty = StoredCredentials(accessClientID: "", accessClientSecret: "", bridgeToken: "", tunnelToken: "")
    }

    /// Keychain accounts. A bridge and a remote client keep separate items. Otherwise switching
    /// roles could make a remote Mac reuse its own bridge credentials and connect to itself.
    enum SecretKey {
        static let accessClientID = "access-client-id"
        static let accessClientSecret = "access-client-secret"
        static let bridgeToken = "bridge-token"
        static let tunnelToken = "cloudflare-tunnel-token"

        static let remoteAccessClientID = "remote-access-client-id"
        static let remoteAccessClientSecret = "remote-access-client-secret"
        static let remoteBridgeToken = "remote-bridge-token"
    }

    private(set) var cached = StoredCredentials.empty
    private var loaded = false
    private var cachedRole: AppMode?
    private var revision = 0
    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(store: any CredentialStore) { self.store = store }

    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable (any CredentialStore) throws -> Value
    ) -> Task<Value, Error> {
        let predecessor = tail
        let store = store
        let task = Task {
            await predecessor?.value
            return try await Task.detached(priority: .userInitiated) {
                try operation(store)
            }.value
        }
        tail = Task { _ = try? await task.value }
        return task
    }

    func load(for mode: AppMode?, mayMigrateLegacy: Bool) async throws -> StoredCredentials {
        if loaded, cachedRole == mode { return cached }
        if loaded {
            revision += 1
            cached = .empty
            loaded = false
        }
        let expectedRevision = revision
        let value = try await enqueue { store in
            try Self.readCredentials(from: store, mode: mode, mayMigrateLegacy: mayMigrateLegacy)
        }.value
        // A newer save may have completed while this read was pending. Return its values.
        guard expectedRevision == revision else {
            if loaded, cachedRole == mode { return cached }
            throw CancellationError()
        }
        cached = value
        cachedRole = mode
        loaded = true
        return value
    }

    /// Enqueue deletion synchronously, before any subsequently submitted save. Resetting the
    /// cache immediately also prevents an in-flight read from bringing the old role back.
    func reset(clearRemote: Bool) -> Task<Void, Error>? {
        revision += 1
        cached = .empty
        cachedRole = nil
        loaded = false
        guard clearRemote else { return nil }
        return enqueue { store in
            try store.setAtomically([
                (SecretKey.remoteAccessClientID, ""),
                (SecretKey.remoteAccessClientSecret, ""),
                (SecretKey.remoteBridgeToken, "")
            ])
        }
    }

    func useDemoCredentials() {
        revision += 1
        cached = StoredCredentials(accessClientID: "DEMO-CLIENT", accessClientSecret: "DEMO-SECRET",
            bridgeToken: "DEMO-BRIDGE-TOKEN", tunnelToken: "")
        loaded = true
    }

    func saveRemote(_ configuration: RemoteConfiguration) async throws {
        revision += 1
        let expectedRevision = revision
        try await enqueue { store in
            try store.setAtomically([
                (SecretKey.remoteAccessClientID, configuration.accessClientID),
                (SecretKey.remoteAccessClientSecret, configuration.accessClientSecret),
                (SecretKey.remoteBridgeToken, configuration.bridgeToken)
            ])
        }.value
        guard expectedRevision == revision else { throw CancellationError() }
        cached = StoredCredentials(accessClientID: configuration.accessClientID,
            accessClientSecret: configuration.accessClientSecret,
            bridgeToken: configuration.bridgeToken, tunnelToken: "")
        cachedRole = .remote
        loaded = true
    }

    func saveProvisioning(_ secrets: CloudflareProvisioningSecrets) async throws {
        revision += 1
        let expectedRevision = revision
        try await enqueue { store in
            try store.setAtomically([
                (SecretKey.accessClientID, secrets.accessClientID),
                (SecretKey.accessClientSecret, secrets.accessClientSecret),
                (SecretKey.tunnelToken, secrets.tunnelToken)
            ])
        }.value
        guard expectedRevision == revision else { throw CancellationError() }
        cached.accessClientID = secrets.accessClientID
        cached.accessClientSecret = secrets.accessClientSecret
        cached.tunnelToken = secrets.tunnelToken
        cachedRole = .bridge
        loaded = true
    }

    func removeProvisioning() async throws {
        try await saveProvisioning(.init(tunnelToken: "", accessClientID: "", accessClientSecret: ""))
    }

    func generateBridgeToken() async throws -> String {
        revision += 1
        let expectedRevision = revision
        let token = try await enqueue { store in
            let token = try store.randomToken()
            try store.set(token, for: SecretKey.bridgeToken)
            return token
        }.value
        guard expectedRevision == revision else { throw CancellationError() }
        cached.bridgeToken = token
        cachedRole = .bridge
        loaded = true
        return token
    }

    nonisolated private static func readCredentials(
        from store: any CredentialStore,
        mode: AppMode?,
        mayMigrateLegacy: Bool
    ) throws -> StoredCredentials {
        switch mode {
        case .remote:
            var credentials = StoredCredentials(
                accessClientID: try store.read(SecretKey.remoteAccessClientID),
                accessClientSecret: try store.read(SecretKey.remoteAccessClientSecret),
                bridgeToken: try store.read(SecretKey.remoteBridgeToken),
                tunnelToken: ""
            )
            // Versions before role-scoped items stored a remote's connection in the shared
            // accounts. Move it once, but never adopt credentials that belong to a bridge.
            if credentials.bridgeToken.isEmpty, mayMigrateLegacy {
                let legacy = StoredCredentials(
                    accessClientID: try store.read(SecretKey.accessClientID),
                    accessClientSecret: try store.read(SecretKey.accessClientSecret),
                    bridgeToken: try store.read(SecretKey.bridgeToken),
                    tunnelToken: ""
                )
                if !legacy.bridgeToken.isEmpty {
                    try store.setAtomically([
                        (SecretKey.remoteAccessClientID, legacy.accessClientID),
                        (SecretKey.remoteAccessClientSecret, legacy.accessClientSecret),
                        (SecretKey.remoteBridgeToken, legacy.bridgeToken)
                    ])
                    try? store.setAtomically([
                        (SecretKey.accessClientID, ""),
                        (SecretKey.accessClientSecret, ""),
                        (SecretKey.bridgeToken, "")
                    ])
                    credentials = legacy
                }
            }
            return credentials
        case .bridge:
            return StoredCredentials(
                accessClientID: try store.read(SecretKey.accessClientID),
                accessClientSecret: try store.read(SecretKey.accessClientSecret),
                bridgeToken: try store.read(SecretKey.bridgeToken),
                tunnelToken: try store.read(SecretKey.tunnelToken)
            )
        case nil:
            return .empty
        }
    }

}
