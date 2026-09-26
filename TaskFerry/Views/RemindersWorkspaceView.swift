import SwiftUI
import UniformTypeIdentifiers

enum ReminderSidebarSelection: Hashable {
    case today
    case tomorrow
    case all
    case list(String)

    init(storageValue: String) {
        switch storageValue {
        case "today": self = .today
        case "tomorrow": self = .tomorrow
        case "all": self = .all
        default:
            if storageValue.hasPrefix("list:") {
                self = .list(String(storageValue.dropFirst(5)))
            } else {
                self = .today
            }
        }
    }

    init?(_ destination: NavigationRequest.Destination) {
        switch destination {
        case .today: self = .today
        case .tomorrow: self = .tomorrow
        case .all: self = .all
        case .list(let id): self = .list(id)
        case .reminder, .newReminder: return nil
        }
    }

    var storageValue: String {
        switch self {
        case .today: "today"
        case .tomorrow: "tomorrow"
        case .all: "all"
        case .list(let id): "list:\(id)"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .tomorrow: "moon.stars.fill"
        case .all: "tray.full.fill"
        case .list: "list.bullet.circle.fill"
        }
    }

    var quickDue: QuickDueOption? {
        switch self {
        case .today: .today
        case .tomorrow: .tomorrow
        case .all, .list: nil
        }
    }

    var emptyTitle: LocalizedStringKey {
        switch self {
        case .today: "A clear day"
        case .tomorrow: "Tomorrow is open"
        case .all: "Nothing left to do"
        case .list: "This list is ready"
        }
    }

    func title(listTitle: String?) -> String {
        switch self {
        case .today: String(localized: "Today")
        case .tomorrow: String(localized: "Tomorrow")
        case .all: String(localized: "All Reminders")
        case .list: listTitle ?? String(localized: "List")
        }
    }

    func subtitle(today: Date) -> String? {
        switch self {
        case .today:
            today.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .tomorrow:
            Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: today)?
                .formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .all, .list:
            nil
        }
    }

    func color(listColorHex: String?) -> Color {
        switch self {
        case .today: TaskFerryPalette.today
        case .tomorrow: TaskFerryPalette.tomorrow
        case .all: TaskFerryPalette.all
        case .list: Color(hex: listColorHex ?? TaskFerryPalette.defaultListHex)
        }
    }
}

/// One section of the reminder list: the overdue items, or one list's reminders.
private struct ReminderSection: Identifiable {
    let id: String
    let title: String?
    let color: Color?
    let isOverdue: Bool
    let reminders: [ReminderRecord]
}

struct RemindersWorkspaceView: View {
    @Bindable var state: AppState

    @SceneStorage("TaskFerry.sidebar-selection") private var storedSelection = "today"
    @SceneStorage("TaskFerry.sidebar-hidden") private var sidebarHidden = false
    @State private var selection = Set<String>()
    @State private var editingID: String?
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var composerFocusRequest = 0
    @State private var listEditor: ListEditorContext?
    @State private var remindersPendingDeletion: [ReminderRecord] = []
    @State private var listPendingDeletion: ReminderListRecord?
    @State private var isDropTargeted = false
    @FocusState private var listFocused: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(\.workspaceActions, workspaceActions)
        .onChange(of: storedSelection) { _, _ in
            selection = []
            editingID = nil
        }
        .onChange(of: state.snapshot.lists) { _, _ in
            repairSelectionIfNeeded()
        }
        .onChange(of: state.snapshot.reminders) { _, reminders in
            let ids = Set(reminders.map(\.id))
            selection.formIntersection(ids)
            if let editingID, !ids.contains(editingID) {
                self.editingID = nil
            }
        }
        .onChange(of: state.navigationRequest, initial: true) { _, request in
            consume(request)
        }
        .onChange(of: state.hasLoadedSnapshot) { _, _ in
            consume(state.navigationRequest)
        }
        .sheet(item: $listEditor) { context in
            ListEditorSheet(state: state, context: context)
        }
        .alert(
            ReminderDeletionCopy.title(count: remindersPendingDeletion.count),
            isPresented: Binding(
                get: { !remindersPendingDeletion.isEmpty },
                set: { if !$0 { remindersPendingDeletion = [] } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                delete(remindersPendingDeletion)
            }
        } message: {
            Text(ReminderDeletionCopy.message(for: remindersPendingDeletion))
        }
        .alert(
            Text("Delete “\(listPendingDeletion?.title ?? "")”?"),
            isPresented: Binding(
                get: { listPendingDeletion != nil },
                set: { if !$0 { listPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete List", role: .destructive) {
                if let list = listPendingDeletion {
                    Task { await state.deleteList(list) }
                }
            }
        } message: {
            Text("This also deletes every reminder in the list, including completed reminders. This can’t be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Focus") {
                smartRow(.today, count: state.todayReminders.count)
                smartRow(.tomorrow, count: state.tomorrowReminders.count)
                smartRow(.all, count: state.allReminders.count)
            }

            Section("Lists") {
                ForEach(state.snapshot.lists) { list in
                    Label {
                        HStack {
                            Text(list.title).lineLimit(1)
                            Spacer()
                            sidebarCount(state.reminders(in: list.id).count)
                        }
                    } icon: {
                        Image(systemName: "list.bullet.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color(hex: list.colorHex))
                    }
                    .tag(ReminderSidebarSelection.list(list.id))
                    .onDrop(of: [.taskFerryReminders, .plainText], isTargeted: nil) { providers in
                        acceptDrop(providers, into: .list(list.id))
                    }
                    .contextMenu {
                        Button("Get Info…") { listEditor = .edit(list) }
                        Divider()
                        Button("Delete List…", role: .destructive) { listPendingDeletion = list }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand {
            if case .list(let id) = currentSelection, let list = state.list(for: id) {
                listPendingDeletion = list
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                listEditor = .create
            } label: {
                Label("Add List", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .help("Create a new list in Apple Reminders (⇧⌘N)")
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 300)
    }

    private func smartRow(_ destination: ReminderSidebarSelection, count: Int) -> some View {
        Label {
            HStack {
                Text(destination.title(listTitle: nil))
                Spacer()
                sidebarCount(count)
            }
        } icon: {
            Image(systemName: destination.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(destination.color(listColorHex: nil))
        }
        .tag(destination)
        .onDrop(of: [.taskFerryReminders, .plainText], isTargeted: nil) { providers in
            acceptDrop(providers, into: destination)
        }
    }

    @ViewBuilder
    private func sidebarCount(_ count: Int) -> some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        let displayed = displayedReminders
        return VStack(spacing: 0) {
            header(count: displayed.count)

            if let error = state.errorMessage {
                ErrorBanner(message: error, showsSettingsLink: state.errorNeedsSettings) { state.dismissError() }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Group {
                if needsConnection {
                    ConnectBridgeView(state: state)
                } else if !state.hasLoadedSnapshot && !state.isShowingCachedSnapshot && state.errorMessage == nil {
                    // Never claim "nothing to do" before the first sync has answered.
                    ProgressView("Loading your reminders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayed.isEmpty {
                    emptyState
                } else {
                    reminderList(sections(for: displayed))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.taskFerryReminders, .plainText], isTargeted: $isDropTargeted) { providers in
                acceptDrop(providers, into: currentSelection)
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }

            if !needsConnection {
                QuickTaskComposer(
                    state: state,
                    selection: currentSelection,
                    contextTitle: displayTitle,
                    focusRequest: composerFocusRequest
                ) { newReminderID in
                    if let newReminderID {
                        selection = [newReminderID]
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(displayTitle)
        .navigationSplitViewColumnWidth(min: 360, ideal: 680)
        .searchable(text: $searchText, isPresented: $isSearchPresented, placement: .toolbar, prompt: Text("Search"))
        .toolbar(id: "workspace") {
            ToolbarItem(id: "new-reminder", placement: .primaryAction) {
                Button(action: beginNewReminder) {
                    Label("New Reminder", systemImage: "plus")
                }
                .help("New Reminder (⌘N)")
                .disabled(needsConnection)
            }
            ToolbarItem(id: "complete", placement: .primaryAction) {
                Button {
                    complete(selectedReminders)
                } label: {
                    Label("Mark as Completed", systemImage: "checkmark.circle")
                }
                .help("Mark as Completed (⌘K)")
                .disabled(selection.isEmpty)
            }
            ToolbarItem(id: "refresh", placement: .primaryAction, showsByDefault: false) {
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.largeTitle.bold())
                    .fontDesign(.rounded)
                    .foregroundStyle(displayColor)
                if let subtitle = currentSelection.subtitle(today: state.currentDay) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SyncStatusView(state: state)
            if count > 0 {
                Text(count, format: .number)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(displayColor)
                    .accessibilityLabel(Text("^[\(count) open reminder](inflect: true)"))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmed.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label(currentSelection.emptyTitle, systemImage: "checkmark.circle")
            } description: {
                Text("Add a reminder below when something comes up.")
            } actions: {
                if !state.snapshot.lists.isEmpty {
                    Button("New Reminder", action: beginNewReminder)
                }
            }
        }
    }

    private func reminderList(_ sections: [ReminderSection]) -> some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                ForEach(sections) { section in
                    if let title = section.title {
                        Section {
                            rows(section)
                        } header: {
                            sectionHeader(title: title, section: section)
                        }
                    } else {
                        rows(section)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                beginEditing(ids)
            }
            .onDeleteCommand {
                requestDelete(selectedReminders)
            }
            .onKeyPress(.return) {
                guard editingID == nil, !selection.isEmpty else { return .ignored }
                beginEditing(selection)
                return .handled
            }
            .onKeyPress(.escape) {
                if editingID != nil {
                    endEditing()
                    return .handled
                }
                guard !selection.isEmpty else { return .ignored }
                selection = []
                return .handled
            }
            .copyable(selectedReminders.map(\.title))
            .pasteDestination(for: String.self) { strings in
                createReminders(fromText: strings)
            }
            .onChange(of: selection) { _, newSelection in
                if let editingID, !newSelection.contains(editingID) {
                    endEditing()
                }
                if newSelection.count == 1, let id = newSelection.first {
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private func sectionHeader(title: String, section: ReminderSection) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(section.color ?? .secondary)
            Spacer()
            Text(section.reminders.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ section: ReminderSection) -> some View {
        ForEach(section.reminders) { reminder in
            Group {
                if editingID == reminder.id {
                    InlineReminderEditor(
                        state: state,
                        reminder: reminder,
                        onSave: { save(reminder, title: $0, notes: $1, listID: $2, due: $3) },
                        onComplete: { complete([reminder]) },
                        onDelete: { requestDelete([reminder]) },
                        onClose: endEditing
                    )
                } else {
                    ReminderRow(
                        state: state,
                        reminder: reminder,
                        showsList: section.isOverdue || currentSelection == .all && section.title == nil,
                        showsFullDate: currentSelection == .all || currentSelection.isList || section.isOverdue,
                        onComplete: { await completeReporting([reminder]) }
                    )
                }
            }
            .tag(reminder.id)
            .id(reminder.id)
            // List's own drag API, which leaves click, ⌘-click, ⇧-click, and double-click alone.
            .itemProvider { dragProvider(for: reminder) }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let reminders = state.snapshot.reminders.filter { ids.contains($0.id) }
        if !reminders.isEmpty {
            if reminders.count == 1 {
                Button("Show Info") { beginEditing(ids) }
            }
            Button("Mark as Completed") { complete(reminders) }
            Divider()
            Button("Due Today") { reschedule(reminders, to: .today) }
            Button("Due Tomorrow") { reschedule(reminders, to: .tomorrow) }
            Button("Remove Due Date") { reschedule(reminders, to: .none) }
            Menu("Move to List") {
                ForEach(state.snapshot.lists) { list in
                    Button(list.title) { move(reminders, to: list.id) }
                }
            }
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reminders.map(\.title).joined(separator: "\n"), forType: .string)
            }
            ShareLink(item: reminders.map(\.title).joined(separator: "\n"))
            Divider()
            Button("Delete…", role: .destructive) { requestDelete(reminders) }
        }
    }

    // MARK: - Derived data

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarHidden ? .detailOnly : .all },
            set: { sidebarHidden = $0 == .detailOnly }
        )
    }

    private var sidebarSelection: Binding<ReminderSidebarSelection?> {
        Binding(
            get: { currentSelection },
            set: { selection in
                if let selection {
                    storedSelection = selection.storageValue
                }
            }
        )
    }

    private var currentSelection: ReminderSidebarSelection {
        ReminderSidebarSelection(storageValue: storedSelection)
    }

    private var selectedList: ReminderListRecord? {
        guard case .list(let id) = currentSelection else { return nil }
        return state.list(for: id)
    }

    private var needsConnection: Bool {
        state.endpoint.isEmpty && !state.hasLoadedSnapshot && !state.isShowingCachedSnapshot
    }

    private var baseReminders: [ReminderRecord] {
        switch currentSelection {
        case .today: state.todayReminders
        case .tomorrow: state.tomorrowReminders
        case .all: state.allReminders
        case .list(let id): state.reminders(in: id)
        }
    }

    private var displayedReminders: [ReminderRecord] {
        let query = searchText.trimmed
        guard !query.isEmpty else { return baseReminders }
        return baseReminders.filter { reminder in
            reminder.title.localizedStandardContains(query)
                || reminder.notes?.localizedStandardContains(query) == true
                || state.list(for: reminder.listID)?.title.localizedStandardContains(query) == true
        }
    }

    private var selectedReminders: [ReminderRecord] {
        displayedReminders.filter { selection.contains($0.id) }
    }

    private func sections(for reminders: [ReminderRecord]) -> [ReminderSection] {
        switch currentSelection {
        case .list:
            return [ReminderSection(id: "list", title: nil, color: nil, isOverdue: false, reminders: reminders)]
        case .today, .tomorrow, .all:
            var result: [ReminderSection] = []
            var remaining = reminders
            if currentSelection == .today {
                let overdue = reminders.filter(state.isOverdue)
                if !overdue.isEmpty {
                    result.append(ReminderSection(
                        id: "overdue",
                        title: String(localized: "Overdue"),
                        color: TaskFerryPalette.overdue,
                        isOverdue: true,
                        reminders: overdue
                    ))
                    remaining.removeAll(where: state.isOverdue)
                }
            }
            let byList = Dictionary(grouping: remaining, by: \.listID)
            for list in state.snapshot.lists {
                guard let items = byList[list.id], !items.isEmpty else { continue }
                result.append(ReminderSection(
                    id: list.id,
                    title: list.title,
                    color: Color(hex: list.colorHex),
                    isOverdue: false,
                    reminders: items
                ))
            }
            let knownListIDs = Set(state.snapshot.lists.map(\.id))
            let unknown = remaining.filter { !knownListIDs.contains($0.listID) }
            if !unknown.isEmpty {
                result.append(ReminderSection(id: "unknown", title: String(localized: "Other"), color: nil, isOverdue: false, reminders: unknown))
            }
            return result
        }
    }

    private var displayTitle: String {
        currentSelection.title(listTitle: selectedList?.title)
    }

    private var displayColor: Color {
        currentSelection.color(listColorHex: selectedList?.colorHex)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            newReminder: beginNewReminder,
            newList: { listEditor = .create },
            find: { isSearchPresented = true },
            refresh: refresh,
            show: handle,
            lists: state.snapshot.lists,
            hasSelection: !selection.isEmpty,
            editSelection: { beginEditing(selection) },
            completeSelection: { complete(selectedReminders) },
            rescheduleSelection: { reschedule(selectedReminders, to: $0) },
            moveSelection: { move(selectedReminders, to: $0) }
        )
    }

    // MARK: - Actions

    /// Applies a request from the Dock, a notification, a URL, or Shortcuts. With several windows
    /// open, only the key window, which WindowRouter just brought forward, responds.
    private func consume(_ request: NavigationRequest?) {
        guard let request else { return }
        guard controlActiveState == .key || WindowRouter.shared.visibleMainWindowCount <= 1 else { return }
        if case .reminder(let id) = request.destination, state.reminder(for: id) == nil, !state.hasLoadedSnapshot {
            // Launched from a notification before the first sync: wait for the reminder to arrive.
            return
        }
        handle(request.destination)
        state.navigationRequest = nil
    }

    private func handle(_ destination: NavigationRequest.Destination) {
        switch destination {
        case .newReminder:
            beginNewReminder()
        case .reminder(let id):
            guard let reminder = state.reminder(for: id) else { return }
            if state.todayReminders.contains(where: { $0.id == id }) {
                storedSelection = ReminderSidebarSelection.today.storageValue
            } else if state.tomorrowReminders.contains(where: { $0.id == id }) {
                storedSelection = ReminderSidebarSelection.tomorrow.storageValue
            } else {
                storedSelection = ReminderSidebarSelection.list(reminder.listID).storageValue
            }
            searchText = ""
            Task { @MainActor in
                selection = [id]
                listFocused = true
            }
        default:
            if let target = ReminderSidebarSelection(destination) {
                storedSelection = target.storageValue
            }
        }
    }

    private func beginNewReminder() {
        guard !state.snapshot.lists.isEmpty else {
            listEditor = .create
            return
        }
        composerFocusRequest += 1
    }

    private func beginEditing(_ ids: Set<String>) {
        guard let id = ids.count == 1 ? ids.first : displayedReminders.first(where: { ids.contains($0.id) })?.id else { return }
        selection = [id]
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            editingID = id
        }
    }

    private func endEditing() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            editingID = nil
        }
        listFocused = true
    }

    private func refresh() {
        Task { await state.refresh() }
    }

    /// After completing or deleting, selection moves to the next reminder, as in Reminders.
    private func advanceSelection(past removed: [ReminderRecord]) {
        let removedIDs = Set(removed.map(\.id))
        guard !removedIDs.isDisjoint(with: selection) else { return }
        let order = displayedReminders.map(\.id)
        let lastIndex = order.lastIndex(where: removedIDs.contains) ?? 0
        let next = order[(lastIndex + 1)...].first { !removedIDs.contains($0) }
            ?? order[..<lastIndex].last { !removedIDs.contains($0) }
        selection = next.map { [$0] } ?? []
    }

    private func complete(_ reminders: [ReminderRecord]) {
        Task { await completeReporting(reminders) }
    }

    /// Completes reminders and reports whether all of them succeeded.
    @discardableResult
    private func completeReporting(_ reminders: [ReminderRecord]) async -> Bool {
        guard !reminders.isEmpty else { return false }
        advanceSelection(past: reminders)
        if reminders.contains(where: { $0.id == editingID }) {
            editingID = nil
        }
        do {
            var completed: [String] = []
            for reminder in reminders where await state.complete(reminder) {
                completed.append(reminder.id)
            }
            guard !completed.isEmpty else { return false }
            ReminderUndo.registerCompletion(completed, completed: true, state: state, undoManager: undoManager)
            let message = completed.count == 1
                ? String(localized: "Completed \(reminders[0].title)")
                : String(localized: "Completed \(completed.count) reminders")
            AccessibilityNotification.Announcement(message).post()
            return completed.count == reminders.count
        }
    }

    private func save(_ reminder: ReminderRecord, title: String, notes: String, listID: String, due: ReminderDue?) {
        let updated = ReminderRecord(id: reminder.id, listID: listID, title: title, notes: notes.trimmed.isEmpty ? nil : notes, due: due)
        guard updated != reminder else { return }
        Task {
            if await state.updateReminder(reminder, title: title, listID: listID, due: due, notes: notes) {
                ReminderUndo.registerEdit(
                    restoring: [reminder],
                    redoing: [updated],
                    name: String(localized: "Edit Reminder"),
                    state: state,
                    undoManager: undoManager
                )
            }
        }
    }

    private func reschedule(_ reminders: [ReminderRecord], to option: QuickDueOption) {
        guard !reminders.isEmpty else { return }
        Task {
            if await state.reschedule(reminders, to: option) {
                let updated = reminders.compactMap { state.reminder(for: $0.id) }
                ReminderUndo.registerEdit(
                    restoring: reminders,
                    redoing: updated,
                    name: String(localized: "Change Due Date"),
                    state: state,
                    undoManager: undoManager
                )
            }
        }
    }

    private func move(_ reminders: [ReminderRecord], to listID: String) {
        let moving = reminders.filter { $0.listID != listID }
        guard !moving.isEmpty else { return }
        Task {
            if await state.move(moving, toList: listID) {
                let updated = moving.map { reminder -> ReminderRecord in
                    var copy = reminder
                    copy.listID = listID
                    return copy
                }
                ReminderUndo.registerEdit(
                    restoring: moving,
                    redoing: updated,
                    name: String(localized: "Move to List"),
                    state: state,
                    undoManager: undoManager
                )
            }
        }
    }

    private func requestDelete(_ reminders: [ReminderRecord]) {
        guard !reminders.isEmpty else { return }
        remindersPendingDeletion = reminders
    }

    private func delete(_ reminders: [ReminderRecord]) {
        remindersPendingDeletion = []
        advanceSelection(past: reminders)
        Task {
            for reminder in reminders {
                await state.deleteReminder(reminder)
            }
        }
    }

    private func dragProvider(for reminder: ReminderRecord) -> NSItemProvider {
        let dragged = selection.contains(reminder.id) ? selectedReminders : [reminder]
        let item = ReminderDragItem(ids: dragged.map(\.id), titles: dragged.map(\.title))
        let provider = NSItemProvider()
        provider.register(item)
        return provider
    }

    /// Handles reminders dropped on a view (moving or rescheduling them) and text dropped from
    /// another app (creating one reminder per line).
    private func acceptDrop(_ providers: [NSItemProvider], into target: ReminderSidebarSelection) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.taskFerryReminders.identifier) }) {
            let shownHere = target == currentSelection ? Set(displayedReminders.map(\.id)) : []
            _ = provider.loadTransferable(type: ReminderDragItem.self) { result in
                guard case .success(let item) = result else { return }
                // Dropped back onto the view it came from: nothing to move or reschedule.
                if !shownHere.isEmpty, Set(item.ids).isSubset(of: shownHere) { return }
                Task { @MainActor in
                    let reminders = item.ids.compactMap(state.reminder(for:))
                    switch target {
                    case .list(let listID):
                        move(reminders, to: listID)
                    case .today, .tomorrow:
                        reschedule(reminders, to: target.quickDue ?? .none)
                    case .all:
                        break
                    }
                }
            }
            return true
        }
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            guard let text else { return }
            Task { @MainActor in
                createReminders(fromText: [text], in: target)
            }
        }
        return true
    }

    /// Creates one reminder per non-empty line, as pasting into Reminders does.
    @discardableResult
    private func createReminders(fromText strings: [String], in target: ReminderSidebarSelection? = nil) -> Bool {
        let titles = strings
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }
        let target = target ?? currentSelection
        let listID: String?
        if case .list(let id) = target {
            listID = id
        } else {
            listID = state.defaultListID
        }
        guard !titles.isEmpty, let listID else { return false }
        let due = target.quickDue?.due()
        Task {
            var created: [String] = []
            for title in titles.prefix(100) {
                if let id = await state.createReminder(title: title, listID: listID, due: due).createdID {
                    created.append(id)
                }
            }
            selection = Set(created)
        }
        return true
    }

    private func repairSelectionIfNeeded() {
        guard state.hasLoadedSnapshot, case .list(let id) = currentSelection else { return }
        if !state.snapshot.lists.contains(where: { $0.id == id }) {
            storedSelection = ReminderSidebarSelection.today.storageValue
        }
    }
}

private extension ReminderSidebarSelection {
    var isList: Bool {
        if case .list = self { return true }
        return false
    }
}

// MARK: - Row

private struct ReminderRow: View {
    let state: AppState
    let reminder: ReminderRecord
    let showsList: Bool
    let showsFullDate: Bool
    let onComplete: () async -> Bool

    @State private var isHoveringCompletion = false
    @State private var isCompleting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: complete) {
                ZStack {
                    Circle()
                        .strokeBorder(listColor, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isHoveringCompletion || isCompleting {
                        Circle()
                            .fill(listColor)
                            .frame(width: 10, height: 10)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCompletion = $0 }
            .help("Mark as Completed")
            .accessibilityHidden(true)
            .disabled(isCompleting)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .lineLimit(2)

                if let notes = reminder.notes?.trimmed, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let metadata {
                    metadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Mark as Completed", complete)
    }

    private var isOverdue: Bool { state.isOverdue(reminder) }

    private var dueText: String? {
        guard let due = reminder.due else { return nil }
        return showsFullDate ? due.summary : due.timeText
    }

    private var metadata: Text? {
        var parts: [Text] = []
        if showsList, let list = state.list(for: reminder.listID) {
            parts.append(Text(list.title))
        }
        if isOverdue {
            parts.append(Text("Overdue").foregroundStyle(TaskFerryPalette.overdue))
        }
        if let dueText {
            parts.append(Text(dueText).foregroundStyle(isOverdue ? TaskFerryPalette.overdue : .secondary))
        }
        guard var text = parts.first else { return nil }
        for part in parts.dropFirst() {
            text = text + Text(" · ") + part
        }
        return text
    }

    private var accessibilityLabel: String {
        var parts = [reminder.title]
        if let list = state.list(for: reminder.listID) { parts.append(list.title) }
        if isOverdue { parts.append(String(localized: "Overdue")) }
        if let due = reminder.due { parts.append(String(localized: "Due \(due.summary)")) }
        if let notes = reminder.notes?.trimmed, !notes.isEmpty { parts.append(notes) }
        return parts.joined(separator: ", ")
    }

    private var listColor: Color {
        Color(hex: state.list(for: reminder.listID)?.colorHex ?? TaskFerryPalette.defaultListHex)
    }

    private func complete() {
        guard !isCompleting else { return }
        isCompleting = true
        Task {
            // On failure the reminder stays, so it must look and act uncompleted again.
            if !(await onComplete()) {
                isCompleting = false
            }
        }
    }
}

// MARK: - Composer

private struct QuickTaskComposer: View {
    let state: AppState
    let selection: ReminderSidebarSelection
    let contextTitle: String
    let focusRequest: Int
    let onCreated: (String?) -> Void

    @State private var title = ""
    @State private var selectedListID = ""
    @State private var isSubmitting = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            TextField("New reminder in \(contextTitle)", text: $title)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .disabled(isSubmitting)
                .accessibilityHint("Press Return to add the reminder")

            if let due = selection.quickDue {
                Label {
                    Text(due.title)
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if lockedListID == nil {
                Picker("List", selection: listSelection) {
                    ForEach(state.snapshot.lists) { list in
                        Label {
                            Text(list.title)
                        } icon: {
                            ListColorDot.image(hex: list.colorHex)
                        }
                        .tag(list.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .help("Choose List")
                .disabled(isSubmitting)
            }

            Button(action: submit) {
                Image(systemName: isSubmitting ? "clock" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(!canSubmit)
            .accessibilityLabel("Add reminder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task { selectDefaultListIfNeeded() }
        .onChange(of: state.snapshot.lists) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: selection) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: focusRequest) { _, _ in
            selectDefaultListIfNeeded()
            focused = true
        }
    }

    private var lockedListID: String? {
        guard case .list(let id) = selection else { return nil }
        return id
    }

    /// Falls back to the default list until one is chosen, so the picker is filled in the first frame.
    private var listSelection: Binding<String> {
        Binding(
            get: { effectiveListID },
            set: { selectedListID = $0 }
        )
    }

    private var canSubmit: Bool {
        !isSubmitting && !title.trimmed.isEmpty && !effectiveListID.isEmpty
    }

    private var effectiveListID: String {
        if let lockedListID { return lockedListID }
        if state.snapshot.lists.contains(where: { $0.id == selectedListID }) { return selectedListID }
        return state.defaultListID ?? ""
    }

    private func selectDefaultListIfNeeded() {
        guard !state.snapshot.lists.contains(where: { $0.id == selectedListID }) else { return }
        selectedListID = state.defaultListID ?? state.snapshot.lists.first?.id ?? ""
    }

    private func submit() {
        let cleanTitle = title.trimmed
        let listID = effectiveListID
        guard !cleanTitle.isEmpty, !listID.isEmpty, !isSubmitting else { return }
        let due = selection.quickDue?.due()
        isSubmitting = true

        Task {
            let outcome = await state.createReminder(title: cleanTitle, listID: listID, due: due)
            if outcome.succeeded {
                title = ""
                onCreated(outcome.createdID)
            }
            isSubmitting = false
            focused = true
        }
    }
}

// MARK: - Status and onboarding

private struct SyncStatusView: View {
    let state: AppState

    var body: some View {
        Group {
            if state.isShowingCachedSnapshot {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
                .help("Showing reminders from your last session while Task Ferry syncs.")
            } else if state.isOffline, let last = state.lastSuccessfulSync {
                Label {
                    Text("Offline · updated \(last, style: .relative) ago")
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .help("Task Ferry can’t reach your bridge right now and will keep trying.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ConnectBridgeView: View {
    let state: AppState
    @State private var message: String?
    @State private var isSaving = false

    var body: some View {
        ContentUnavailableView {
            Label("Connect to Your Bridge", systemImage: "link.circle")
        } description: {
            VStack(spacing: 8) {
                Text("On the Mac that shares its reminders, open Task Ferry and choose Copy Connection Code. Then paste it here.")
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Button(isSaving ? "Connecting…" : "Paste Connection Code", action: paste)
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            SettingsLink { Text("Open Settings…") }
        }
    }

    private func paste() {
        guard let code = NSPasteboard.general.string(forType: .string) else {
            message = String(localized: "The clipboard doesn’t contain a connection code.")
            return
        }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await state.saveConnectionCode(code)
                if await state.refresh() {
                    message = nil
                } else {
                    message = state.errorMessage
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
