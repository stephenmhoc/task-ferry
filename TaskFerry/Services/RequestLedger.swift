import Foundation

/// Remembers recently applied mutations so a request retried after a lost response is applied once.
///
/// Remotes retry a mutation only after an ambiguous network failure, and they reuse the original
/// `requestID`. The bridge answers a repeat with a fresh snapshot and the originally created ID,
/// instead of creating a second reminder.
struct RequestLedger {
    struct Entry: Equatable {
        let createdID: String?
        let recordedAt: Date
    }

    private let capacity: Int
    private let lifetime: TimeInterval
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    init(capacity: Int = 128, lifetime: TimeInterval = 10 * 60) {
        self.capacity = capacity
        self.lifetime = lifetime
    }

    mutating func entry(for requestID: String, now: Date = Date()) -> Entry? {
        prune(now: now)
        return entries[requestID]
    }

    mutating func record(_ requestID: String, createdID: String?, now: Date = Date()) {
        prune(now: now)
        if entries[requestID] == nil {
            order.append(requestID)
        }
        entries[requestID] = Entry(createdID: createdID, recordedAt: now)
        while order.count > capacity {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    private mutating func prune(now: Date) {
        while let oldest = order.first,
              let entry = entries[oldest],
              now.timeIntervalSince(entry.recordedAt) > lifetime {
            entries.removeValue(forKey: oldest)
            order.removeFirst()
        }
    }
}
