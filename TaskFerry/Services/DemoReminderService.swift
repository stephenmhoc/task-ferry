import Foundation

@MainActor
final class DemoReminderService: ReminderService {
    private var value: ReminderSnapshot

    init(now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
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
    }

    func execute(_ request: RPCRequest) async throws -> ReminderSnapshot {
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
            } else {
                value.lists.append(ReminderListRecord(id: UUID().uuidString, title: title, colorHex: "30D158"))
            }
        case .deleteList:
            guard let id = request.id, value.lists.contains(where: { $0.id == id }) else {
                throw ReminderServiceError.message("That list is no longer editable.")
            }
            value.lists.removeAll { $0.id == id }
            value.reminders.removeAll { $0.listID == id }
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
                value.reminders.append(ReminderRecord(
                    id: UUID().uuidString,
                    listID: listID,
                    title: title,
                    notes: request.notes.flatMap { $0.trimmed.isEmpty ? nil : $0 },
                    due: request.due
                ))
            }
        case .setCompleted:
            guard let id = request.id, value.reminders.contains(where: { $0.id == id }) else {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
            if request.completed == true {
                value.reminders.removeAll { $0.id == id }
            }
        case .deleteReminder:
            guard let id = request.id, value.reminders.contains(where: { $0.id == id }) else {
                throw ReminderServiceError.message("That reminder changed elsewhere. Refresh and try again.")
            }
            value.reminders.removeAll { $0.id == id }
        }
        value.lists.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return value
    }
}
