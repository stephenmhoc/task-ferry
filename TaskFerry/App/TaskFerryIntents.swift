import AppIntents
import Foundation

/// A Reminders list, as Shortcuts shows it.
struct ReminderListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = ReminderListQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct ReminderListQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ReminderListEntity] {
        await Self.lists().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ReminderListEntity] {
        await Self.lists()
    }

    @MainActor
    static func lists() async -> [ReminderListEntity] {
        let state = AppState.shared
        await state.start()
        if state.snapshot.lists.isEmpty {
            await state.refresh(showLoadingIndicator: false)
        }
        return state.snapshot.lists.map { ReminderListEntity(id: $0.id, title: $0.title) }
    }
}

enum DueOptionAppEnum: String, AppEnum {
    case none
    case today
    case tomorrow

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Due Date"
    static let caseDisplayRepresentations: [DueOptionAppEnum: DisplayRepresentation] = [
        .none: "No Date",
        .today: "Today",
        .tomorrow: "Tomorrow"
    ]

    var option: QuickDueOption { QuickDueOption(rawValue: rawValue) ?? .none }
}

struct AddReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Reminder"
    static let description = IntentDescription("Adds a reminder to Apple Reminders on your bridge Mac.")

    @Parameter(title: "Title")
    var reminderTitle: String

    @Parameter(title: "List", description: "Leave empty to use your default list.")
    var list: ReminderListEntity?

    @Parameter(title: "Due", default: DueOptionAppEnum.none)
    var due: DueOptionAppEnum

    @Parameter(title: "Notes")
    var notes: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$reminderTitle) to \(\.$list)") {
            \.$due
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        guard state.mode == .remote else {
            throw ReminderServiceError.message(String(localized: "Connect this Mac to your bridge in Task Ferry first."))
        }
        await state.start()
        if state.snapshot.lists.isEmpty {
            await state.refresh(showLoadingIndicator: false)
        }
        guard let listID = list?.id ?? state.defaultListID else {
            throw ReminderServiceError.message(String(localized: "Task Ferry couldn’t find a list to add to."))
        }
        let outcome = await state.createReminder(title: reminderTitle, listID: listID, due: due.option.due(), notes: notes)
        guard outcome.succeeded else {
            throw ReminderServiceError.message(state.errorMessage ?? String(localized: "The reminder couldn’t be added."))
        }
        let listTitle = state.list(for: listID)?.title ?? ""
        return .result(dialog: "Added “\(reminderTitle)” to \(listTitle).")
    }
}

enum WorkspaceViewAppEnum: String, AppEnum {
    case today
    case tomorrow
    case all

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "View"
    static let caseDisplayRepresentations: [WorkspaceViewAppEnum: DisplayRepresentation] = [
        .today: "Today",
        .tomorrow: "Tomorrow",
        .all: "All Reminders"
    ]
}

struct OpenRemindersViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Reminders View"
    static let description = IntentDescription("Opens Task Ferry to Today, Tomorrow, or All Reminders.")
    static let openAppWhenRun = true

    @Parameter(title: "View", default: WorkspaceViewAppEnum.today)
    var view: WorkspaceViewAppEnum

    @MainActor
    func perform() async throws -> some IntentResult {
        WindowRouter.shared.showMainWindow()
        switch view {
        case .today: AppState.shared.navigate(to: .today)
        case .tomorrow: AppState.shared.navigate(to: .tomorrow)
        case .all: AppState.shared.navigate(to: .all)
        }
        return .result()
    }
}

struct TodayRemindersIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today’s Reminders"
    static let description = IntentDescription("Returns the titles of reminders due today or overdue.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let state = AppState.shared
        await state.start()
        await state.refresh(showLoadingIndicator: false)
        let titles = state.todayReminders.map(\.title)
        let dialog: IntentDialog = titles.isEmpty
            ? "Nothing is due today."
            : "^[\(titles.count) reminder](inflect: true) due today."
        return .result(value: titles, dialog: dialog)
    }
}

struct TaskFerryShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddReminderIntent(),
            phrases: [
                "Add a reminder with \(.applicationName)",
                "New \(.applicationName) reminder"
            ],
            shortTitle: "Add Reminder",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: TodayRemindersIntent(),
            phrases: [
                "What’s due today in \(.applicationName)",
                "Show today in \(.applicationName)"
            ],
            shortTitle: "Today’s Reminders",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: OpenRemindersViewIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open View",
            systemImageName: "checklist"
        )
    }
}
