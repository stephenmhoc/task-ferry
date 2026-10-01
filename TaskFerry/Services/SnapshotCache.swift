import Foundation

/// Keeps the last snapshot a remote Mac received, so the next launch can draw reminders in its
/// first frame instead of waiting on a round trip through Cloudflare.
///
/// This is a read-only display cache, not a second task database. Nothing is ever written back
/// from it, every mutation still goes to the bridge, and the first live snapshot replaces it. The
/// file sits in Caches, is readable only by the user, and is keyed to one endpoint.
struct SnapshotCache: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var endpoint: String
        var savedAt: Date
        var snapshot: ReminderSnapshot
    }

    let fileURL: URL?

    static let live = SnapshotCache(fileURL: {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = Bundle.main.bundleIdentifier ?? "com.merimerimeri.TaskFerry"
        return caches.appending(path: folder).appending(path: "last-snapshot.json")
    }())

    static let disabled = SnapshotCache(fileURL: nil)

    /// Reads synchronously on purpose: the file is small and local, and reading it while the app
    /// launches is what lets the first frame show real content.
    func load(endpoint: String) -> Entry? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.endpoint == endpoint else {
            return nil
        }
        return entry
    }

    func save(_ entry: Entry) async {
        guard let fileURL else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Self.queue.async {
                defer { continuation.resume() }
                Self.write(entry, to: fileURL)
            }
        }
    }

    /// Submit synchronously so a subsequent clear cannot overtake a not-yet-started save Task.
    func enqueueSave(_ entry: Entry) {
        guard let fileURL else { return }
        Self.queue.async { Self.write(entry, to: fileURL) }
    }

    private static func write(_ entry: Entry, to fileURL: URL) {
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if (try? data.write(to: fileURL, options: [.atomic])) != nil {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    /// Runs after any save already queued, so a copy can't be written back after it was cleared.
    func clear() {
        guard let fileURL else { return }
        Self.queue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Serializes writes and removal, so they land in the order they were requested.
    private static let queue = DispatchQueue(label: "TaskFerry.SnapshotCache", qos: .utility)
}
