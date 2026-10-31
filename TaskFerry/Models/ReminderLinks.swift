import Foundation

/// Detect links without interpreting a reminder's plain text as Markdown or changing its contents.
enum ReminderLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributed(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        for match in matches(in: text) {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: text),
                  let range = Range(stringRange, in: value) else { continue }
            value[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
        }
        return value
    }

    static func urls(title: String, notes: String?, url: URL? = nil) -> [URL] {
        let detected = [title, notes ?? ""].flatMap { matches(in: $0).compactMap(\.url) }
        var seen = Set<URL>()
        return (detected + [url].compactMap { $0 }).filter { seen.insert($0).inserted }
    }

    static func urls(for reminder: ReminderRecord) -> [URL] {
        urls(title: reminder.title, notes: reminder.notes, url: reminder.url)
    }

    private static func matches(in text: String) -> [NSTextCheckingResult] {
        detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }
}
