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
    /// The left and right edge of everything in the reminder column.
    fileprivate static let margin: CGFloat = 16

    @SceneStorage("TaskFerry.sidebar-selection") private var storedSelection = "today"
    @SceneStorage("TaskFerry.sidebar-hidden") private var sidebarHidden = false
    @State private var selection = Set<String>()
    @State private var editingSession: ReminderEditSession?
    @State private var newReminder: ReminderEditSession?
    private var editingID: String? { editingSession?.original.id }
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var listEditor: ListEditorContext?
    @State private var newReminderAfterSheet = false
    @State private var remindersPendingDeletion: [ReminderRecord] = []
    @State private var listPendingDeletion: ReminderListRecord?
    @State private var isDropTargeted = false
    @State private var sidebarDropTarget: ReminderSidebarSelection?
    /// Where each sidebar row is, so the floating button can find the row it's dropped on.
    @State private var sidebarFrames: [ReminderSidebarSelection: CGRect] = [:]
    @FocusState private var listFocused: Bool
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate static let workspaceSpace = "workspace"

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 340)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 380)
        }
        // Over the split view, not in the detail column, which would hide it behind the sidebar.
        .overlay(alignment: .bottomTrailing) { floatingButton }
        .background {
            TitlebarButtons(
                canAddReminder: !needsConnection,
                toggleSidebar: toggleSidebar,
                newReminder: beginNewReminder
            )
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search"))
        .coordinateSpace(name: Self.workspaceSpace)
        .searchFocused($searchFocused)
        .toolbar { ToolbarSpacer(.flexible) }
        .navigationTitle(displayTitle)
        .focusedSceneValue(\.workspaceActions, workspaceActions)
        .onDisappear {
            persistCurrentEditor()
            if let editingSession { state.openEdits[editingSession.id] = nil }
        }
        .onChange(of: editingSession?.id) { previous, _ in
            if let previous { state.openEdits[previous] = nil }
            if let editingSession { state.openEdits[editingSession.id] = editingSession }
        }
        .onChange(of: storedSelection) { _, _ in
            selection = []
            endEditing()
        }
        .onChange(of: searchText) { _, _ in
            selection.formIntersection(displayedReminders.map(\.id))
        }
        .onChange(of: state.snapshot.lists) { _, _ in
            repairSelectionIfNeeded()
        }
        .onChange(of: state.snapshot.reminders) { _, reminders in
            let ids = Set(reminders.map(\.id))
            selection.formIntersection(ids)
            if let editingID, !ids.contains(editingID) {
                endEditing()
            }
        }
        .onChange(of: state.navigationRequest, initial: true) { _, request in
            consume(request)
        }
        .onChange(of: state.hasLoadedSnapshot) { _, _ in
            consume(state.navigationRequest)
        }
        .sheet(item: $listEditor, onDismiss: {
            if newReminderAfterSheet {
                newReminderAfterSheet = false
                beginNewReminder()
            }
        }) { context in
            ListEditorSheet(state: state, context: context) { id in
                storedSelection = ReminderSidebarSelection.list(id).storageValue
                newReminderAfterSheet = true
            }
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

    @ViewBuilder
    private var floatingButton: some View {
        if !needsConnection {
            FloatingNewReminderButton(
                action: beginNewReminder,
                onDrag: { point in
                    sidebarDropTarget = sidebarFrames.first { $0.value.contains(point) }?.key
                },
                onDrop: { point in
                    let target = sidebarFrames.first { $0.value.contains(point) }?.key
                    sidebarDropTarget = nil
                    if let target { beginNewReminder(in: target) }
                }
            )
            .popover(item: newReminderPopover, arrowEdge: .top) { session in
                ReminderForm(state: state, session: session, onSave: saveNewReminder, onCancel: cancelNewReminder)
            }
            .padding(20)
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

            Section("My Lists") {
                ForEach(state.snapshot.lists) { list in
                    Label {
                        HStack {
                            Text(list.title).lineLimit(1)
                            Spacer()
                            sidebarCount(state.reminders(in: list.id).count)
                        }
                    } icon: {
                        ZStack {
                            Circle().fill(Color(hex: list.colorHex))
                            Image(systemName: "list.bullet")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 20, height: 20)
                    }
                    .tag(ReminderSidebarSelection.list(list.id))
                    .modifier(sidebarDrop(.list(list.id)))
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
        .modifier(sidebarDrop(destination))
    }

    private func sidebarDrop(_ destination: ReminderSidebarSelection) -> SidebarDropTarget {
        SidebarDropTarget(
            isTargeted: Binding(
                get: { sidebarDropTarget == destination },
                set: { targeted in
                    if targeted {
                        sidebarDropTarget = destination
                    } else if sidebarDropTarget == destination {
                        sidebarDropTarget = nil
                    }
                }
            ),
            onDrop: { acceptDrop($0, into: destination) },
            onFrame: { sidebarFrames[destination] = $0 }
        )
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
            header

            ForEach(state.unsavedEdits.values.filter { $0.phase == .failed && $0.id != editingSession?.id }.sorted { $0.id.uuidString < $1.id.uuidString }) { draft in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Unsaved edit: \(draft.title)").lineLimit(2)
                    HStack {
                        Button("Review") {
                            storedSelection = ReminderSidebarSelection.list(draft.original.listID).storageValue
                            searchText = ""
                            Task { @MainActor in
                                selection = [draft.original.id]
                                editingSession = draft
                            }
                        }
                        .disabled(state.reminder(for: draft.original.id) == nil)
                        Button("Retry") { Task { await state.saveEdit(draft, undoManager: undoManager) } }
                            .disabled(state.reminder(for: draft.original.id) == nil)
                        Button("Copy Draft") {
                            Pasteboard.copy([draft.title, draft.notes].filter { !$0.isEmpty }.joined(separator: "\n"))
                        }
                        Button("Discard", role: .destructive) { state.discardEdit(draft) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(.callout).padding(.horizontal, Self.margin).padding(.bottom, 10)
            }

            if let error = state.errorMessage {
                ErrorBanner(message: error, showsSettingsLink: state.errorNeedsSettings) { state.dismissError() }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 10)
            }

            Group {
                if needsConnection {
                    ConnectBridgeView(state: state)
                } else if !state.hasLoadedSnapshot && !state.isShowingCachedSnapshot && state.errorMessage == nil {
                    // Never claim "nothing to do" before the first sync has answered.
                    ProgressView("Loading your reminders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.title.bold())
                    .lineLimit(1)
                if let subtitle = currentSelection.subtitle(today: state.currentDay) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            SyncStatusView(state: state)
        }
        .padding(.horizontal, Self.margin)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmed.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            ContentUnavailableView {
                Label(currentSelection.emptyTitle, systemImage: "checkmark.circle")
            } description: {
                Text("Press + when something comes up.")
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
                        // The title is a row, not a Section header: headers pin to the top as you
                        // scroll, which looks wrong on load and over a long list.
                        Section {
                            sectionHeader(title: title, section: section)
                                .padding(.top, 14)
                                .listRowSeparator(.hidden)
                                .selectionDisabled()
                            rows(section)
                        }
                        .listSectionSeparator(.hidden)
                    } else {
                        rows(section)
                    }
                }
            }
            .listStyle(.inset)
            // Room to scroll the last reminder clear of the floating button.
            .contentMargins(.bottom, 76, for: .scrollContent)
            .overlay { if displayedReminders.isEmpty { emptyState } }
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
        HStack(spacing: 7) {
            // A dot rather than coloured text: Yellow and Teal are unreadable as words on white.
            if !section.isOverdue, let color = section.color {
                Circle().fill(color).frame(width: 9, height: 9).accessibilityHidden(true)
            }
            Text(title)
                .foregroundStyle(section.isOverdue ? TaskFerryPalette.overdue : .primary)
            Spacer()
            Text(section.reminders.count, format: .number)
                .font(.caption.monospacedDigit())
                .fontWeight(.regular)
                .foregroundStyle(.tertiary)
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ section: ReminderSection) -> some View {
        ForEach(section.reminders) { reminder in
            ReminderRow(
                state: state,
                reminder: reminder,
                showsList: section.isOverdue || currentSelection == .all && section.title == nil,
                showsFullDate: currentSelection == .all || currentSelection.isList || section.isOverdue,
                onComplete: { complete([reminder]) }
            )
            .itemProvider { dragProvider(for: reminder) }
            .popover(
                isPresented: editorPresented(for: reminder.id),
                attachmentAnchor: .point(UnitPoint(x: 0.3, y: 1)),
                arrowEdge: .bottom
            ) {
                if let session = editingSession {
                    ReminderForm(
                        state: state,
                        session: session,
                        onComplete: { complete([reminder]) },
                        onDelete: { requestDelete([reminder]) },
                        onSave: saveCurrentEditor,
                        onCancel: cancelCurrentEditor
                    )
                }
            }
            .tag(reminder.id)
            .id(reminder.id)
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let reminders = state.snapshot.reminders.filter { ids.contains($0.id) }
        if !reminders.isEmpty {
            if reminders.count == 1 {
                Button("Show Info") { beginEditing(ids) }
                ReminderLinkMenu(urls: ReminderLinks.urls(for: reminders[0]))
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

    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .default) { sidebarHidden.toggle() }
    }

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
                || reminder.url?.absoluteString.localizedStandardContains(query) == true
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

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            newReminder: beginNewReminder,
            newList: { listEditor = .create },
            sidebarHidden: sidebarHidden,
            toggleSidebar: toggleSidebar,
            find: { searchFocused = true },
            refresh: refresh,
            show: handle,
            lists: state.snapshot.lists,
            hasSelection: !selectedReminders.isEmpty,
            editSelection: { beginEditing(Set(selectedReminders.map(\.id))) },
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
        beginNewReminder(in: currentSelection)
    }

    /// Starts in the list on screen, or the one dragged to, and otherwise in the default list.
    private func beginNewReminder(in target: ReminderSidebarSelection) {
        guard !state.snapshot.lists.isEmpty else {
            listEditor = .create
            return
        }
        guard newReminder == nil else { return }
        let listID: String?
        if case .list(let id) = target {
            listID = id
        } else {
            listID = state.newReminderListID
        }
        guard let listID else { return }
        endEditing()
        newReminder = ReminderEditSession(newIn: listID, due: target.quickDue?.due(), connectionRevision: state.connectionRevision)
    }

    /// Clicking away keeps what was written, as closing a Calendar event does. Esc doesn't.
    private var newReminderPopover: Binding<ReminderEditSession?> {
        Binding(
            get: { newReminder },
            set: { session in
                guard session == nil, newReminder != nil else { return }
                if reminderEscapeEventTimestamp() != nil {
                    cancelNewReminder()
                } else if newReminder?.title.trimmed.isEmpty == false {
                    saveNewReminder()
                } else {
                    cancelNewReminder()
                }
            }
        )
    }

    private func saveNewReminder() {
        guard let session = newReminder, !session.title.trimmed.isEmpty else { return }
        Task {
            let result = await state.saveNewReminder(session)
            // A failure has to keep the words, so it reopens if a click took the popover away.
            newReminder = result.saved ? nil : session
            if let id = result.id { selection = [id] }
        }
    }

    private func cancelNewReminder() {
        guard newReminder?.phase != .saving else { return }
        newReminder = nil
    }

    private func editorPresented(for id: String) -> Binding<Bool> {
        Binding(
            get: { editingID == id },
            set: { presented in
                guard !presented, editingID == id else { return }
                if reminderEscapeEventTimestamp() != nil {
                    cancelCurrentEditor()
                } else {
                    endEditing(restoreFocus: true)
                }
            }
        )
    }

    private func beginEditing(_ ids: Set<String>) {
        guard let id = ids.count == 1 ? ids.first : displayedReminders.first(where: { ids.contains($0.id) })?.id else { return }
        guard editingID != id else { return }
        persistCurrentEditor()
        selection = [id]
        editingSession = state.unsavedEdits.values.first(where: { $0.original.id == id })
            ?? state.reminder(for: id).map { ReminderEditSession($0, connectionRevision: state.connectionRevision) }
    }

    private func endEditing(restoreFocus: Bool = false) {
        persistCurrentEditor()
        editingSession = nil
        if restoreFocus {
            listFocused = false
            Task { @MainActor in
                await Task.yield()
                listFocused = true
            }
        }
    }

    private func persistCurrentEditor() {
        guard let session = editingSession else { return }
        state.saveEditWhenLeaving(session, undoManager: undoManager)
    }

    // Read the current @State session when invoked. AppKit can reuse a text field's
    // submit callback even after SwiftUI replaces the surrounding List row.
    private func saveCurrentEditor() {
        guard let session = editingSession else { return }
        Task {
            if await state.saveEdit(session, undoManager: undoManager), editingSession?.id == session.id {
                endEditing(restoreFocus: true)
            }
        }
    }

    private func cancelCurrentEditor() {
        guard let session = editingSession, session.phase != .saving else { return }
        state.discardEdit(session)
        endEditing(restoreFocus: true)
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
        if let session = editingSession, reminders.contains(where: { $0.id == session.original.id }) {
            guard await state.saveEdit(session, undoManager: undoManager) else { return false }
        }
        advanceSelection(past: reminders)
        if reminders.contains(where: { $0.id == editingID }) {
            editingSession = nil
        }
        let completed = await state.completeNow(reminders)
        guard !completed.isEmpty else { return false }
        ReminderUndo.registerCompletion(completed, completed: true, state: state, undoManager: undoManager)
        let message = completed.count == 1
            ? String(localized: "Completed \(reminders[0].title)")
            : String(localized: "Completed \(completed.count) reminders")
        AccessibilityNotification.Announcement(message).post()
        return completed.count == reminders.count
    }

    private func reschedule(_ reminders: [ReminderRecord], to option: QuickDueOption) {
        guard !reminders.isEmpty else { return }
        Task {
            if let session = editingSession, reminders.contains(where: { $0.id == session.original.id }) {
                guard await state.saveEdit(session, undoManager: undoManager) else { return }
                endEditing()
            }
            let reminders = reminders.compactMap { state.reminder(for: $0.id) }
            _ = await state.rescheduleReporting(reminders, to: option, undoManager: undoManager)
        }
    }

    private func move(_ reminders: [ReminderRecord], to listID: String) {
        let moving = reminders.filter { $0.listID != listID }
        guard !moving.isEmpty else { return }
        Task {
            if let session = editingSession, moving.contains(where: { $0.id == session.original.id }) {
                guard await state.saveEdit(session, undoManager: undoManager) else { return }
                endEditing()
            }
            let moving = moving.compactMap { state.reminder(for: $0.id) }
            _ = await state.moveReporting(moving, toList: listID, undoManager: undoManager)
        }
    }

    private func requestDelete(_ reminders: [ReminderRecord]) {
        guard !reminders.isEmpty else { return }
        remindersPendingDeletion = reminders
    }

    private func delete(_ reminders: [ReminderRecord]) {
        if let session = editingSession, reminders.contains(where: { $0.id == session.original.id }) {
            state.discardEdit(session)
            editingSession = nil
        }
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
    @Environment(\.openURL) private var openURL
    let state: AppState
    let reminder: ReminderRecord
    let showsList: Bool
    let showsFullDate: Bool
    let onComplete: () -> Void

    @State private var isHoveringCompletion = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompleting: Bool { state.completingIDs.contains(reminder.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: complete) {
                ZStack {
                    Circle()
                        .strokeBorder(isHoveringCompletion || isCompleting ? AnyShapeStyle(listColor) : AnyShapeStyle(.tertiary), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isCompleting {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(listColor)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                    } else if isHoveringCompletion {
                        Circle()
                            .fill(listColor.opacity(0.35))
                            .frame(width: 10, height: 10)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isCompleting)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCompletion = $0 }
            .help("Mark as Completed")
            .accessibilityHidden(true)
            .disabled(isCompleting)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }

            VStack(alignment: .leading, spacing: 3) {
                Text(ReminderLinks.attributed(reminder.title))
                    .font(.system(size: 14))
                    .lineLimit(2)

                if let notes = reminder.notes?.trimmed, !notes.isEmpty {
                    Text(ReminderLinks.attributed(notes))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let url = reminder.url {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.system(size: 13))
                            .lineLimit(1)
                    }
                }

                if let metadata {
                    metadata
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Mark as Completed", complete)
        .accessibilityActions {
            ForEach(ReminderLinks.urls(for: reminder), id: \.self) { url in
                Button("Open \(url.absoluteString)") { openURL(url) }
            }
        }
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
            text = Text("\(text) · \(part)")
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
        onComplete()
    }
}

// MARK: - New reminders

/// Click for a new reminder here, or drag it onto a list to start one there. The button itself
/// follows the pointer, and springs back if it isn't dropped on a list.
private struct FloatingNewReminderButton: View {
    let action: () -> Void
    let onDrag: (CGPoint) -> Void
    let onDrop: (CGPoint) -> Void

    @State private var offset: CGSize = .zero
    @State private var isDragging = false

    /// Not a Button, so that nothing else tracks the mouse while it's dragged.
    var body: some View {
        Image(systemName: "plus")
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 48, height: 48)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: .circle)
            .scaleEffect(isDragging ? 1.12 : 1)
            .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: 12, y: 6)
            .offset(offset)
            .onTapGesture(perform: action)
            .gesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(RemindersWorkspaceView.workspaceSpace))
                    .onChanged { value in
                        withAnimation(.snappy(duration: 0.15)) { isDragging = true }
                        offset = value.translation
                        onDrag(value.location)
                    }
                    .onEnded { value in
                        // Once it's home, because the new reminder's popover points at the button.
                        withAnimation(.spring(duration: 0.3, bounce: 0.2)) {
                            offset = .zero
                            isDragging = false
                        } completion: {
                            onDrop(value.location)
                        }
                    }
            )
            .help("New Reminder (⌘N). Drag onto a list to add it there.")
            .accessibilityElement()
            .accessibilityLabel("Add Reminder")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
}

/// Shows which row a drag will land on, which a sidebar doesn't do for `onDrop` by itself.
private struct SidebarDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    let onDrop: ([NSItemProvider]) -> Bool
    let onFrame: (CGRect) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(RemindersWorkspaceView.workspaceSpace)) } action: { onFrame($0) }
            .onDrop(of: [.taskFerryReminders, .plainText], isTargeted: $isTargeted, perform: onDrop)
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.25))
                        .padding(-4)
                }
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
