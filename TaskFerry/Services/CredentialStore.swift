import Foundation

protocol CredentialStore: Sendable {
    func string(for account: String) -> String
    /// Reads a credential, returning an empty string only when none is stored. Any other Keychain
    /// failure, such as a locked keychain or a denied access prompt, throws, so callers never
    /// mistake an unreadable secret for a missing one and replace it.
    func read(_ account: String) throws -> String
    func set(_ value: String, for account: String) throws
    func randomToken() throws -> String
}

extension CredentialStore {
    func read(_ account: String) throws -> String {
        string(for: account)
    }

    func setAtomically(_ values: [(account: String, value: String)]) throws {
        let originals = try values.map { (account: $0.account, value: try read($0.account)) }
        do {
            for value in values {
                try set(value.value, for: value.account)
            }
        } catch {
            var rollbackFailed = false
            for original in originals.reversed() {
                do {
                    try set(original.value, for: original.account)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                throw ReminderServiceError.message("Could not save or fully restore the previous Keychain credentials.")
            }
            throw error
        }
    }
}
