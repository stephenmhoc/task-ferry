import Foundation

@MainActor
final class DemoReminderService: ReminderService {
    private var value: ReminderSnapshot
    private let scenario: DemoScenario
    private var failedMutation = false
    var initialSnapshot: ReminderSnapshot { value }
    /// Completed reminders stay here, as they do in EventKit, so completion can be undone.
    private var completed: [ReminderRecord] = []

    init(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent, scenario: DemoScenario = .standard) {
        self.scenario = scenario
        let today = ReminderDue(date: now, includesTime: false, calendar: calendar)
        let tomorrowDate = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        let tomorrow = ReminderDue(date: tomorrowDate, includesTime: false, calendar: calendar)
        let overdueDate = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let overdue = ReminderDue(date: overdueDate, includesTime: false, calendar: calendar)
        value = ReminderSnapshot(
            lists: [
                ReminderListRecord(id: "personal", title: "Personal", colorHex: "5E5CE6"),
                ReminderListRecord(id: "work", title: "Work", colorHex: "0A84FF")
            ],
            reminders: [
                ReminderRecord(
                    id: "1",
                    listID: "work",
                    title: "Send the quarterly report",
                    notes: "Include the revised forecast and hiring plan.",
                    due: today
                ),
                ReminderRecord(id: "2", listID: "personal", title: "Renew prescription", due: today),
                ReminderRecord(id: "3", listID: "personal", title: "Call the dentist", due: overdue),
                ReminderRecord(id: "4", listID: "work", title: "Prepare tomorrow’s notes", due: tomorrow)
            ],
            defaultListID: "personal"
        )
        if scenario == .empty { value.reminders = [] }
        if scenario == .longContent {
            value.lists[0].title = "Personal projects and plans for the coming year"
            value.reminders[0].title = "Review the complete quarterly planning document with engineering and design, then send the revised schedule before the planning meeting"
            value.reminders[0].notes = String(repeating: "Detailed planning notes for review.\n", count: 8)
            value.reminders += (5...45).map { ReminderRecord(id: String($0), listID: "work", title: "Planning task \($0)", due: today) }
        }
    }

    func execute(_ request: RPCRequest) async throws -> RPCResult {
        if scenario == .offline {
            throw ReminderServiceError.message("Demo: the bridge is offline. Try again when it is connected.")
        }
        if scenario == .mutationFailure, request.operation != .snapshot, !failedMutation {
            failedMutation = true
            throw ReminderServiceError.message("Demo: the first change failed. Retry to save it.")
        }
        var createdID: String?
        switch request.operation {
        case .snapshot:
            break
        case .upsertList:
            guard let title = request.title?.trimmed, !title.isEmpty else {
                throw ReminderServiceError.message("A list needs a name.")
            }
            if let id = request.id {
                guard let index = value.lists.firstIndex(where: { $0.id == id }) else {
                    throw ReminderServiceError.message("That list is no longer editable.")
                }
                value.lists[index].title = title
                if let colorHex = request.colorHex {
                    value.lists[index].colorHex = colorHex
                }
            } else {
                let id = UUID().uuidString
                value.lists.append(ReminderListRecord(id: id, title: title, colorHex: request.colorHex ?? "30D158"))
                createdID = id
            }
        case .deleteList:
            guard let id = request.id, value.lists.contains(where: { $0.id == id }) else {
                throw ReminderServiceError.message("That list is no longer editable.")
            }
            value.lists.removeAll { $0.id == id }
            value.reminders.removeAll { $0.listID == id }
            completed.removeAll { $0.listID == id }
            if value.defaultListID == id {
                value.defaultListID = value.lists.first?.id
            }
        case .upsertReminder:
            guard let title = request.title?.trimmed, !title.isEmpty,
                  let listID = request.listID,
                  value.lists.contains(where: { $0.id == listID }) else {
                throw ReminderServiceError.message("A reminder needs a title and editable list.")
            }
            if let id = request.id {
                guard let index = value.reminders.firstIndex(where: { $0.id == id }) else {
                    throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
                }
                value.reminders[index].title = title
                if let notes = request.notes {
                    value.reminders[index].notes = notes.trimmed.isEmpty ? nil : notes
                }
                value.reminders[index].listID = listID
                value.reminders[index].due = request.due
            } else {
                let id = UUID().uuidString
                value.reminders.append(ReminderRecord(
                    id: id,
                    listID: listID,
                    title: title,
                    notes: request.notes.flatMap { $0.trimmed.isEmpty ? nil : $0 },
                    due: request.due
                ))
                createdID = id
            }
        case .setCompleted:
            guard let id = request.id else {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
            if request.completed ?? true {
                guard let index = value.reminders.firstIndex(where: { $0.id == id }) else {
                    throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
                }
                completed.append(value.reminders.remove(at: index))
            } else if let index = completed.firstIndex(where: { $0.id == id }) {
                value.reminders.append(completed.remove(at: index))
            } else if !value.reminders.contains(where: { $0.id == id }) {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
        case .deleteReminder:
            guard let id = request.id, value.reminders.contains(where: { $0.id == id }) else {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
            value.reminders.removeAll { $0.id == id }
        }
        value.lists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return RPCResult(snapshot: value, createdID: createdID)
    }
}
