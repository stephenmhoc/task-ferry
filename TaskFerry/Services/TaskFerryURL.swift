import Foundation

/// The `taskferry://` URL scheme, for launchers such as Raycast and Alfred, and for scripts.
///
/// - `taskferry://add?title=Buy%20milk&list=Groceries&due=today&notes=…` adds a reminder.
///   Without a title, it opens Quick Entry.
/// - `taskferry://show/today`, `show/tomorrow`, `show/all`, and `show/list/<id or name>` open a view.
/// - `taskferry://reminder/<id>` opens one reminder.
///
/// Connection codes are deliberately not accepted, because a URL could deliver someone else's.
enum TaskFerryURL: Equatable {
    case add(title: String?, list: String?, due: QuickDueOption, notes: String?)
    case show(NavigationRequest.Destination)

    static let scheme = "taskferry"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased() else { return nil }
        let query = Dictionary(
            (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let path = components.path.split(separator: "/").map(String.init)

        switch host {
        case "add", "new":
            let due = query["due"].flatMap { QuickDueOption(rawValue: $0.lowercased()) } ?? .none
            self = .add(
                title: query["title"].map(\.trimmed).flatMap { $0.isEmpty ? nil : $0 },
                list: query["list"].flatMap { $0.isEmpty ? nil : $0 },
                due: due,
                notes: query["notes"].flatMap { $0.isEmpty ? nil : $0 }
            )
        case "show", "open":
            switch path.first?.lowercased() {
            case "today", nil: self = .show(.today)
            case "tomorrow": self = .show(.tomorrow)
            case "all": self = .show(.all)
            case "list" where path.count > 1: self = .show(.list(path[1]))
            default: return nil
            }
        case "reminder" where !path.isEmpty:
            self = .show(.reminder(path[0]))
        default:
            return nil
        }
    }
}
