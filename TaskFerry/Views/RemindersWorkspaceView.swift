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
        case .today: "A Clear Day"
        case .tomorrow: "Tomorrow Is Open"
        case .all: "Nothing Left to Do"
        case .list: "No Reminders"
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

/// Which text field, or the reminder list itself, has keyboard focus in a workspace window.
enum WorkspaceFocus: Hashable {
    case sidebar
    case search
    case reminders
    /// A field in the row being edited: a reminder's, or the new row's, which a new reminder is
    /// typed into.
    case row(String, ReminderRowField)
    /// A list being renamed in the sidebar.
    case listName(String)

    var rowID: String? {
        if case .row(let id, _) = self { return id }
        return nil
    }
}

/// Where the floating + button would start a reminder if it were let go now.
enum NewReminderDropTarget: Equatable {
    case sidebar(ReminderSidebarSelection)
    /// The end of one list's section in the reminder list.
    case section(String)
    /// The end of the reminder list on screen.
    case list
}

/// The sidebar's width. Wide enough for list names such as "Groceries & Household" next to their
/// counts; TitlebarButtons may raise the minimum to clear the sidebar button.
enum SidebarWidth {
    static let minimum: CGFloat = 220
    static let ideal: CGFloat = 260
    static let maximum: CGFloat = 400
}

/// Where the sidebar rows and the reminder list's rows are, for the + button's drag. Global, like
/// the drag itself, because a split view's columns can't see a coordinate space named outside them.
/// It's a plain object, so scrolling updates it without redrawing anything.
final class NewReminderDropGeometry {
    var sidebar: CGRect = .null
    var sidebarRows: [ReminderSidebarSelection: CGRect] = [:]
    var reminderList: CGRect = .null
    /// Keyed by section and row, so a reminder in two places is two entries.
    var rows: [String: (section: String, frame: CGRect)] = [:]
}

/// What a search looks through.
enum WorkspaceSearchScope: Hashable {
    case all
    case current
}

struct RemindersWorkspaceView: View {
    /// Editing a reminder's title in its row, or its other details in Show Info.
    private enum EditingMode { case inline, info }

    @Bindable var state: AppState
    /// The left and right edge of everything in the reminder column.
    fileprivate static let margin: CGFloat = 16
    static let newRowID = "new-reminder-row"
    fileprivate static let dropTypes: [UTType] = [.taskFerryReminders, .plainText]

    @SceneStorage("TaskFerry.sidebar-selection") private var storedSelection = "today"
    @SceneStorage("TaskFerry.sidebar-hidden") private var sidebarHidden = false
    @State private var selection = Set<String>()
    @State private var editingSession: ReminderEditSession?
    @State private var editingMode = EditingMode.inline
    @State private var newReminder: ReminderEditSession?
    /// The view the new-reminder row was started in, so leaving that view finishes it.
    @State private var newReminderView: String?
    /// Bumped to give the new-reminder row focus when it's already on screen.
    @State private var newRowFocusRequest = 0
    /// A text field whose focus was given back after it went nowhere. It's given back only once,
    /// in case the field isn't on screen to take it.
    @State private var restoredFocus: WorkspaceFocus?
    /// Reminders waiting for Delete in an alert, because Undo can't bring all of them back.
    @State private var remindersPendingDeletion: [ReminderRecord] = []
    private var editingID: String? { editingSession?.original.id }
    @State private var searchText = ""
    @State private var searchScope = WorkspaceSearchScope.all
    @FocusState private var focus: WorkspaceFocus?
    @State private var scrollTarget: String?
    @State private var listEditor: ListEditorContext?
    @State private var newReminderAfterSheet = false
    @State private var listPendingDeletion: ReminderListRecord?
    @State private var renamingListID: String?
    @State private var listNameDraft = ""
    @State private var isDropTargeted = false
    @State private var sidebarDropTarget: ReminderSidebarSelection?
    @State private var dropGeometry = NewReminderDropGeometry()
    /// The date or time popover open on a row's editor.
    @State private var rowPopover: RowPopover?
    /// Where the + button would start a reminder while it's dragged.
    @State private var newReminderDrop: NewReminderDropTarget?
    @Environment(\.undoManager) private var undoManager
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        workspace
            .alert(
                remindersPendingDeletion.count == 1
                    ? Text("Delete “\(remindersPendingDeletion[0].title)”?")
                    : Text("Delete \(remindersPendingDeletion.count) reminders?"),
                isPresented: Binding(
                    get: { !remindersPendingDeletion.isEmpty },
                    set: { if !$0 { remindersPendingDeletion = [] } }
                )
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    let reminders = remindersPendingDeletion
                    remindersPendingDeletion = []
                    delete(reminders, confirmed: true)
                }
            } message: {
                Text(remindersPendingDeletion.count == 1
                    ? "Undo can’t bring back everything about this reminder, such as how it repeats or its alerts."
                    : "Undo can’t bring back everything about these reminders, such as how they repeat or their alerts.")
            }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: SidebarWidth.minimum, ideal: SidebarWidth.ideal,
                                                max: SidebarWidth.maximum)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 380)
        }
        // Over the split view, not in the detail column, which would hide it behind the sidebar.
        .overlay(alignment: .bottomTrailing) { floatingButton }
        // Fixed beside the traffic lights, so it doesn't move when the sidebar opens or closes.
        .background {
            TitlebarButtons(sidebarHidden: sidebarHidden, toggleSidebar: toggleSidebar)
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: Text("Search"))
        .searchScopes($searchScope) {
            Text("All Reminders").tag(WorkspaceSearchScope.all)
            if currentSelection != .all {
                Text(displayTitle).tag(WorkspaceSearchScope.current)
            }
        }
        .searchFocused($focus, equals: .search)
        .toolbar { ToolbarSpacer(.flexible) }
        .navigationTitle(displayTitle)
        .focusedSceneValue(\.workspaceActions, workspaceActions)
    }

    /// The window's layout, what it reacts to, and its sheets and alerts are kept apart, so none of
    /// them is one long expression to type-check.
    private var observingSplitView: some View {
        splitView
        .onDisappear {
            commitNewReminder(continuing: false)
            persistCurrentEditor()
            if let editingSession { state.openEdits[editingSession.id] = nil }
            if let newReminder { state.openEdits[newReminder.id] = nil }
        }
        // Quitting saves what's typed in either one, even before it's been left.
        .onChange(of: editingSession?.id) { previous, _ in
            if let previous { state.openEdits[previous] = nil }
            if let editingSession { state.openEdits[editingSession.id] = editingSession }
        }
        .onChange(of: newReminder?.id) { previous, _ in
            if let previous { state.openEdits[previous] = nil }
            if let newReminder { state.openEdits[newReminder.id] = newReminder }
        }
        // Switching to another window or app leaves the text field, as clicking elsewhere does.
        .onChange(of: controlActiveState) { _, active in
            guard active == .inactive else { return }
            // An empty new row stays, ready for when you come back.
            if newReminder?.isBlank == false { commitNewReminder(continuing: false) }
            if editingMode == .inline, editingSession != nil { endEditing() }
            commitRenaming()
        }
        .onChange(of: storedSelection) { _, _ in
            selection = []
            endEditing()
            if newReminder != nil, newReminderView != storedSelection {
                commitNewReminder(continuing: false)
            }
            if let renamingListID, storedSelection != ReminderSidebarSelection.list(renamingListID).storageValue {
                commitRenaming()
            }
            if currentSelection == .all { searchScope = .all }
        }
        .onChange(of: searchText) { _, _ in
            selection.formIntersection(displayedReminders.map(\.id))
        }
        .onChange(of: focus) { previous, current in
            focusDidChange(from: previous, to: current)
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
    }

    private var workspace: some View {
        observingSplitView
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
        if state.syncStatus != .notConfigured {
            FloatingNewReminderButton(
                lists: state.snapshot.lists,
                action: beginNewReminder,
                newReminderInList: { beginNewReminder(in: .list($0)) },
                onDragChanged: { showDropTarget(newReminderDropTarget(at: $0)) },
                onDragEnded: { point in
                    let target = newReminderDropTarget(at: point)
                    showDropTarget(nil)
                    guard let target else { return false }
                    startNewReminder(at: target)
                    return true
                },
                onDragFinished: { showDropTarget(nil) }
            )
            .padding(FloatingNewReminderButton.inset)
        }
    }

    /// What's under the pointer: a sidebar row, a list's section, or the reminder list itself.
    /// Rows reach a few points into the gaps between them, so there's no dead space.
    private func newReminderDropTarget(at point: CGPoint) -> NewReminderDropTarget? {
        guard !state.snapshot.lists.isEmpty else { return nil }
        let geometry = dropGeometry
        if !sidebarHidden, geometry.sidebar.contains(point) {
            return geometry.sidebarRows
                .first { $0.value.insetBy(dx: 0, dy: -3).contains(point) }
                .map { .sidebar($0.key) }
        }
        guard geometry.reminderList.contains(point), state.hasSnapshotToShow else { return nil }
        // Only the height matters: anywhere across a row is that row.
        let section = geometry.rows.values
            .first { $0.frame.minY - 1 <= point.y && point.y < $0.frame.maxY + 1 }?.section
        if let section, state.list(for: section) != nil, !showsSingleList {
            return .section(section)
        }
        return .list
    }

    private func showDropTarget(_ target: NewReminderDropTarget?) {
        let sidebar: ReminderSidebarSelection?
        if case .sidebar(let destination) = target { sidebar = destination } else { sidebar = nil }
        if sidebarDropTarget != sidebar { sidebarDropTarget = sidebar }
        if newReminderDrop != target { newReminderDrop = target }
    }

    /// The section that gets a line showing where the new row will go.
    private var newReminderDropSection: String? {
        switch newReminderDrop {
        case .section(let id): id
        case .list: showsSingleList ? "list" : state.newReminderListID
        case .sidebar, nil: nil
        }
    }

    /// The whole list is outlined when there's no section on screen to put the line under.
    private var outlinesListForNewReminder: Bool {
        guard newReminderDrop == .list else { return false }
        let section = newReminderDropSection
        let hasNewRow = newReminder != nil && newRowSectionID == section
        return !sections(for: displayedReminders).contains { $0.id == section && (!$0.reminders.isEmpty || hasNewRow) }
    }

    private func startNewReminder(at target: NewReminderDropTarget) {
        switch target {
        case .sidebar(let destination):
            beginNewReminder(in: destination)
        case .section(let listID):
            beginNewReminder(in: currentSelection, listID: listID)
        case .list:
            beginNewReminder()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                smartRow(.today, count: state.todayReminders.count)
                smartRow(.tomorrow, count: state.tomorrowReminders.count)
                smartRow(.all, count: state.allReminders.count)
            }

            Section("My Lists") {
                ForEach(state.snapshot.lists) { list in
                    listRow(list)
                }
            }
        }
        .listStyle(.sidebar)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dropGeometry.sidebar = $0 }
        .focused($focus, equals: .sidebar)
        .onDeleteCommand {
            if renamingListID == nil, let list = selectedList {
                listPendingDeletion = list
            }
        }
        // Return renames the selected list, as it renames a file in the Finder.
        .onKeyPress(.return) {
            guard renamingListID == nil, let list = selectedList else { return .ignored }
            beginRenaming(list)
            return .handled
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
            .help("Create a new list in Apple Reminders")
        }
    }

    private func listRow(_ list: ReminderListRecord) -> some View {
        Label {
            if renamingListID == list.id {
                TextField("List Name", text: $listNameDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .listName(list.id))
                    .onSubmit(commitRenaming)
                    .onExitCommand(perform: cancelRenaming)
            } else {
                Text(list.title).lineLimit(1)
            }
        } icon: {
            ZStack {
                Circle().fill(Color(hex: list.colorHex))
                Image(systemName: "list.bullet")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 20, height: 20)
        }
        .badge(state.reminders(in: list.id).count)
        .modifier(sidebarDrop(.list(list.id)))
        .tag(ReminderSidebarSelection.list(list.id))
        .contextMenu {
            Button("New Reminder") { beginNewReminder(in: .list(list.id)) }
            Divider()
            Button("Rename") { beginRenaming(list) }
            Button("Show List Info") { listEditor = .edit(list) }
            Divider()
            Button("Delete List…", role: .destructive) { listPendingDeletion = list }
        }
    }

    private func smartRow(_ destination: ReminderSidebarSelection, count: Int) -> some View {
        Label {
            Text(destination.title(listTitle: nil))
        } icon: {
            Image(systemName: destination.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(destination.color(listColorHex: nil))
        }
        .badge(count)
        .modifier(sidebarDrop(destination))
        .tag(destination)
    }

    private func sidebarDrop(_ destination: ReminderSidebarSelection) -> SidebarDropTarget {
        let shownIDs = destination == currentSelection ? Set(baseReminders.map(\.id)) : []
        return SidebarDropTarget(
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
            // All Reminders has no list or date to give a reminder, so dropping one there does nothing.
            acceptsReminders: destination != .all,
            shownIDs: shownIDs,
            onDrop: { acceptDrop($0, into: destination, shownIDs: shownIDs) },
            onFrame: { [dropGeometry] frame in dropGeometry.sidebarRows[destination] = frame }
        )
    }

    // MARK: - Detail

    private var detail: some View {
        let displayed = displayedReminders
        return VStack(spacing: 0) {
            header

            ForEach(failedDrafts) { draft in
                DraftBanner(
                    draft: draft,
                    canRetry: draft.isNew
                        ? state.list(for: draft.listID) != nil
                        : state.reminder(for: draft.original.id) != nil,
                    review: { review(draft) },
                    retry: { Task { await state.saveEdit(draft, undoManager: undoManager) } },
                    copy: { Pasteboard.copy([draft.title, draft.notes].filter { !$0.isEmpty }.joined(separator: "\n")) },
                    discard: { state.discardEdit(draft) }
                )
                .padding(.horizontal, Self.margin)
                .padding(.bottom, 10)
            }

            if let error = state.errorMessage {
                ErrorBanner(message: error, showsSettingsLink: state.errorNeedsSettings) { state.dismissError() }
                    .padding(.horizontal, Self.margin)
                    .padding(.bottom, 10)
            }

            Group {
                switch state.syncStatus {
                case .notConfigured:
                    ConnectBridgeView(state: state)
                case .loading:
                    // Never claim "nothing to do" before the first sync has answered.
                    ProgressView("Loading your reminders…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed where !state.hasSnapshotToShow:
                    LoadFailedView(state: state)
                case .failed, .updatingCachedCopy, .upToDate, .offline:
                    reminderList(sections(for: displayed))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { dropGeometry.reminderList = $0 }
            .onDrop(of: Self.dropTypes, delegate: ReminderListDropDelegate(
                shownIDs: Set(displayed.map(\.id)),
                // Search results from everywhere aren't the view on screen, so there's nowhere to
                // move a reminder to.
                acceptsReminders: !isSearchingAll && currentSelection != .all,
                isTargeted: $isDropTargeted,
                perform: { acceptDrop($0, into: currentSelection, shownIDs: Set(displayed.map(\.id))) }
            ))
            .overlay {
                if isDropTargeted || outlinesListForNewReminder {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var failedDrafts: [ReminderEditSession] {
        state.unsavedEdits.values
            .filter { $0.phase == .failed && $0.id != editingSession?.id && $0.id != newReminder?.id }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // A search of everything isn't limited to the view it started in.
                Text(isSearchingAll ? String(localized: "All Reminders") : displayTitle)
                    .font(.title.bold())
                    .lineLimit(1)
                if let subtitle = currentSelection.subtitle(today: state.currentDay), !isSearchingAll {
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
        if isSearching {
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
                                .modifier(RowFrame(geometry: dropGeometry, section: section.id, row: "header"))
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
            // Just enough room to scroll the last reminder clear of the floating button.
            .contentMargins(.bottom, FloatingNewReminderButton.clearance, for: .scrollContent)
            .overlay { if displayedReminders.isEmpty, newReminder == nil { emptyState } }
            .scrollContentBackground(.hidden)
            .focused($focus, equals: .reminders)
            .contextMenu(forSelectionType: String.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                beginEditing(ids, mode: .inline)
            }
            .onDeleteCommand {
                delete(selectedReminders)
            }
            // Inside a row, keys reach the list rather than the field, so the row's own Return
            // behaviour is here. Otherwise Return edits the selected reminder in place, as in Reminders.
            .onKeyPress(.return, phases: .down) { press in
                if case .row(let id, let field) = focus {
                    return handleReturn(inRow: id, field: field, command: press.modifiers.contains(.command))
                }
                guard editingID == nil, !selection.isEmpty else { return .ignored }
                beginEditing(selection, mode: .inline)
                return .handled
            }
            .onKeyPress(.escape) {
                guard editingID == nil, focus?.rowID != Self.newRowID, !selection.isEmpty else { return .ignored }
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
                // Choosing a reminder leaves the new row.
                if !newSelection.isEmpty { commitNewReminder(continuing: false) }
                if newSelection.count == 1, let id = newSelection.first {
                    withAnimation(reduceMotion ? nil : .default) {
                        proxy.scrollTo(id)
                    }
                }
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(target) }
                scrollTarget = nil
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
            if !section.reminders.isEmpty {
                Text(section.reminders.count, format: .number)
                    .font(.caption.monospacedDigit())
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(_ section: ReminderSection) -> some View {
        let hasNewRow = newReminder != nil && section.id == newRowSectionID
        ForEach(section.reminders) { reminder in
            ReminderRow(
                state: state,
                reminder: reminder,
                // List titles scroll away, so a row has to say where it belongs by itself.
                showsList: !showsSingleList,
                showsFullDate: currentSelection == .all || currentSelection.isList || section.isOverdue || isSearchingAll,
                isSelected: selection.contains(reminder.id),
                editing: editingMode == .inline && editingID == reminder.id ? editingSession : nil,
                focus: $focus,
                popover: $rowPopover,
                onComplete: { complete([reminder]) },
                onShowInfo: { beginEditing([reminder.id], mode: .info) },
                onEdit: { beginEditing([reminder.id], mode: .inline) },
                onSubmit: saveCurrentEditor,
                onCancel: cancelCurrentEditor
            )
            .overlay(alignment: .bottom) {
                if !hasNewRow, reminder.id == section.reminders.last?.id, newReminderDropSection == section.id {
                    NewRowIndicator()
                }
            }
            .itemProvider { dragProvider(for: reminder) }
            .popover(
                isPresented: infoPresented(for: reminder.id),
                attachmentAnchor: .point(UnitPoint(x: 0.3, y: 1)),
                arrowEdge: .bottom
            ) {
                if let session = editingSession {
                    ReminderForm(
                        state: state,
                        session: session,
                        onComplete: { complete([reminder]) },
                        onDelete: { delete([reminder]) },
                        onDone: saveCurrentEditor
                    )
                }
            }
            .modifier(RowFrame(geometry: dropGeometry, section: section.id, row: reminder.id))
            // The row stays selected while it's edited, so the list doesn't take the first click on
            // its fields, but the selection's colour would sit behind them, so it's covered.
            .listRowBackground(editingMode == .inline && editingID == reminder.id
                ? Color(nsColor: .textBackgroundColor) : nil)
            // Last, so the list's selection can see it.
            .tag(reminder.id)
            .id(reminder.id)
            .listRowSeparator(.hidden)
        }
        if let newReminder, hasNewRow {
            NewReminderRow(
                session: newReminder,
                lists: state.snapshot.lists,
                color: Color(hex: state.list(for: newReminder.listID)?.colorHex ?? TaskFerryPalette.defaultListHex),
                focus: $focus,
                popover: $rowPopover,
                focusRequest: newRowFocusRequest,
                onSubmit: { commitNewReminder(continuing: true) },
                onCancel: cancelNewReminder
            )
            .overlay(alignment: .bottom) {
                if newReminderDropSection == section.id { NewRowIndicator() }
            }
            .modifier(RowFrame(geometry: dropGeometry, section: section.id, row: Self.newRowID))
            .id(Self.newRowID)
            .selectionDisabled()
            .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<String>) -> some View {
        let reminders = state.snapshot.reminders.filter { ids.contains($0.id) }
        if reminders.isEmpty {
            // A click on empty space, below the last reminder.
            if !state.snapshot.lists.isEmpty {
                Button("New Reminder", action: beginNewReminder)
            }
        } else {
            if reminders.count == 1 {
                Button("Show Info") { beginEditing(ids, mode: .info) }
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
            Button("Delete", role: .destructive) { delete(reminders) }
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

    private var isSearching: Bool { !searchText.trimmed.isEmpty }

    /// A search looks through every reminder unless it's narrowed to the current view.
    private var isSearchingAll: Bool {
        isSearching && (searchScope == .all || currentSelection == .all)
    }

    /// One list on screen, with no section titles.
    private var showsSingleList: Bool { currentSelection.isList && !isSearchingAll }

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
        let searched = isSearchingAll ? state.allReminders : baseReminders
        return searched.filter { reminder in
            reminder.title.localizedStandardContains(query)
                || reminder.notes?.localizedStandardContains(query) == true
                || reminder.url?.absoluteString.localizedStandardContains(query) == true
                || state.list(for: reminder.listID)?.title.localizedStandardContains(query) == true
        }
    }

    private var selectedReminders: [ReminderRecord] {
        displayedReminders.filter { selection.contains($0.id) }
    }

    /// The section the new-reminder row goes at the end of.
    private var newRowSectionID: String? {
        guard let newReminder else { return nil }
        return showsSingleList ? "list" : newReminder.listID
    }

    private func sections(for reminders: [ReminderRecord]) -> [ReminderSection] {
        if showsSingleList {
            return [ReminderSection(id: "list", title: nil, color: nil, isOverdue: false, reminders: reminders)]
        }
        var result: [ReminderSection] = []
        var remaining = reminders
        if currentSelection == .today, !isSearchingAll {
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
            let items = byList[list.id] ?? []
            // A list with nothing here still gets a section while a new reminder is typed into it.
            guard !items.isEmpty || newReminder?.listID == list.id else { continue }
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

    private var displayTitle: String {
        currentSelection.title(listTitle: selectedList?.title)
    }

    private var workspaceActions: WorkspaceActions {
        WorkspaceActions(
            newReminder: beginNewReminder,
            newList: { listEditor = .create },
            sidebarHidden: sidebarHidden,
            toggleSidebar: toggleSidebar,
            find: { focus = .search },
            refresh: refresh,
            show: handle,
            lists: state.snapshot.lists,
            hasSelection: !selectedReminders.isEmpty,
            hasSingleSelection: selectedReminders.count == 1,
            selectedList: selectedList,
            showInfo: { beginEditing(Set(selectedReminders.map(\.id)), mode: .info) },
            completeSelection: { complete(selectedReminders) },
            rescheduleSelection: { reschedule(selectedReminders, to: $0) },
            moveSelection: { move(selectedReminders, to: $0) },
            showListInfo: { if let list = selectedList { listEditor = .edit(list) } },
            deleteList: { if let list = selectedList { listPendingDeletion = list } }
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
                focus = .reminders
            }
        default:
            if let target = ReminderSidebarSelection(destination) {
                storedSelection = target.storageValue
            }
        }
    }

    /// Leaving a text field keeps what was typed into it, as clicking away does in Reminders.
    ///
    /// Only a real departure counts. The list can take a field's focus as it redraws, such as
    /// when a reminder lands above the new row or a sync changes a row, and then focus goes nowhere
    /// or to the list itself without the user doing anything, so it's given back. Changing the view
    /// or the selection, switching windows, and closing the window are handled where they happen.
    private func focusDidChange(from previous: WorkspaceFocus?, to current: WorkspaceFocus?) {
        guard previous != current else { return }
        if current != nil, current == restoredFocus { restoredFocus = nil }
        // Moving between a row's own fields, such as from the title to the date, stays in the row.
        if let row = previous?.rowID, row == current?.rowID { return }
        let departed = current != nil && (current != .reminders || userJustMovedFocus)
        switch previous {
        case .row(let id, let field) where id == Self.newRowID:
            guard newReminder != nil else { return }
            if departed {
                commitNewReminder(continuing: false)
            } else if field.takesFocusBack {
                restoreFocus(.row(id, field))
            }
        case .row(let id, let field):
            guard editingMode == .inline, editingID == id else { return }
            if departed {
                endEditing()
            } else if field.takesFocusBack {
                restoreFocus(.row(id, field))
            }
        case .listName(let id):
            guard renamingListID == id else { return }
            if departed {
                commitRenaming()
            } else {
                restoreFocus(.listName(id))
            }
        case .sidebar, .search, .reminders, nil:
            break
        }
    }

    /// True when the user has just clicked, or pressed a key such as Tab, rather than the list
    /// moving focus by itself. Return doesn't count: it saves a row, and the list redraws after.
    private var userJustMovedFocus: Bool {
        guard let event = NSApp.currentEvent,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.5 else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown:
            return true
        case .keyDown:
            return event.keyCode != 36 && event.keyCode != 76 // Return and Enter
        default:
            return false
        }
    }

    /// Gives focus back once; if the field isn't on screen to take it, it's left alone. Focus also
    /// goes nowhere when a popover, such as the date picker's, takes the keyboard, and taking it
    /// back would close the popover, so that waits until AppKit has settled which window is key.
    private func restoreFocus(_ target: WorkspaceFocus) {
        guard restoredFocus != target else { return }
        DispatchQueue.main.async {
            guard focus == nil || focus == .reminders, let key = NSApp.keyWindow, key === NSApp.mainWindow else { return }
            restoredFocus = target
            focus = target
        }
    }

    /// Return inside a row: a line break in the notes, a save with ⌘, and the popover on the date
    /// or time control. Text being composed with an input method keeps its Return.
    private func handleReturn(inRow id: String, field: ReminderRowField, command: Bool) -> KeyPress.Result {
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        if editor?.hasMarkedText() == true { return .ignored }
        if command {
            if id == Self.newRowID {
                commitNewReminder(continuing: false)
            } else {
                saveCurrentEditor()
            }
            return .handled
        }
        switch field {
        case .notes:
            guard let editor else { return .ignored }
            editor.insertNewlineIgnoringFieldEditor(nil)
            return .handled
        case .date, .time:
            rowPopover = RowPopover(rowID: id, field: field)
            return .handled
        case .title, .list, .info:
            return .ignored
        }
    }

    private func beginNewReminder() {
        beginNewReminder(in: currentSelection)
    }

    /// Adds an empty row to type into, at the end of the list on screen or the one the + button was
    /// dropped on. In Today, Tomorrow, and All Reminders, it goes in the default list, unless the
    /// button was dropped on another list's section there.
    private func beginNewReminder(in target: ReminderSidebarSelection, listID preferredListID: String? = nil) {
        guard !state.snapshot.lists.isEmpty else {
            listEditor = .create
            return
        }
        var target = target
        let listID: String?
        if case .list(let id) = target {
            // Dropped on another list's section, as in a search of everything from inside a list:
            // that list, shown on its own.
            if let preferredListID, preferredListID != id { target = .list(preferredListID) }
            listID = preferredListID ?? id
        } else {
            listID = preferredListID ?? state.newReminderListID
        }
        guard let listID else { return }
        if let current = newReminder {
            if current.isBlank, current.listID == listID, newReminderView == target.storageValue {
                focusNewRow()
                return
            }
            commitNewReminder(continuing: false)
        }
        // Show where it's going.
        if target != currentSelection { storedSelection = target.storageValue }
        startNewRow(listID: listID, due: target.quickDue?.due(), view: target.storageValue)
    }

    private func startNewRow(listID: String, due: ReminderDue?, view: String) {
        endEditing()
        newReminderView = view
        searchText = ""
        selection = []
        newReminder = ReminderEditSession(newIn: listID, due: due, connectionRevision: state.connectionRevision)
        focusNewRow()
    }

    /// The row takes focus itself when it first appears; this is for one already on screen.
    private func focusNewRow() {
        scrollTarget = Self.newRowID
        newRowFocusRequest += 1
    }

    /// Return adds the reminder and starts the next one. Leaving the row adds it and stops. A row
    /// left empty just goes away. A reminder that fails to save comes back into the row if nothing
    /// has been typed there since, and otherwise waits in the draft banner, with its reason.
    private func commitNewReminder(continuing: Bool) {
        guard let session = newReminder, session.phase != .saving else { return }
        if session.isBlank {
            cancelNewReminder()
            return
        }
        // Notes or a date but no title: it stays, and says what it needs.
        if session.markIncomplete() {
            // Closing the window would lose it, so it waits in the draft banner too.
            state.unsavedEdits[session.id] = session
            return
        }
        let next = continuing
            ? ReminderEditSession(newIn: session.listID, due: session.original.due, connectionRevision: state.connectionRevision)
            : nil
        newReminder = next
        let undoManager = undoManager
        Task {
            let result = await state.saveNewReminder(session, undoManager: undoManager)
            if result.saved {
                let list = state.list(for: session.listID)?.title ?? ""
                AccessibilityNotification.Announcement(String(localized: "Added to \(list)")).post()
            } else if session.phase == .failed, newReminder == nil || newReminder === next,
                      newReminder?.isBlank ?? true {
                newReminder = session
                focusNewRow()
            }
        }
    }

    private func cancelNewReminder() {
        guard let session = newReminder else { return }
        let hadFocus = focus?.rowID == Self.newRowID
        if rowPopover?.rowID == Self.newRowID { rowPopover = nil }
        // A draft that failed to save and came back into the row is given up on here too.
        state.discardEdit(session)
        newReminder = nil
        if hadFocus { focus = .reminders }
    }

    private func infoPresented(for id: String) -> Binding<Bool> {
        Binding(
            get: { editingMode == .info && editingID == id },
            set: { presented in
                // However it closes, Show Info keeps its changes.
                guard !presented, editingMode == .info, editingID == id else { return }
                endEditing(restoreFocus: true)
            }
        )
    }

    private func beginEditing(_ ids: Set<String>, mode: EditingMode) {
        guard let id = ids.count == 1 ? ids.first : displayedReminders.first(where: { ids.contains($0.id) })?.id else { return }
        commitNewReminder(continuing: false)
        if editingID == id {
            withAnimation(rowAnimation) { editingMode = mode }
            return
        }
        persistCurrentEditor()
        // The row stays selected while it's edited: an unselected row would let the list take the
        // first click on one of its fields. Its selection colour is hidden instead, in ReminderRow.
        selection = [id]
        // The row grows into its editor the way a list row changes height.
        withAnimation(rowAnimation) {
            editingMode = mode
            editingSession = state.unsavedEdits.values.first(where: { $0.original.id == id })
                ?? state.reminder(for: id).map { ReminderEditSession($0, connectionRevision: state.connectionRevision) }
        }
        // The title field focuses itself as it appears.
    }

    /// Review opens a failed draft in Show Info, where every field it changed can be seen. A new
    /// reminder goes back into its row instead.
    private func review(_ draft: ReminderEditSession) {
        if draft.isNew {
            if let current = newReminder, current.isBlank { cancelNewReminder() }
            commitNewReminder(continuing: false)
            storedSelection = ReminderSidebarSelection.list(draft.listID).storageValue
            newReminderView = storedSelection
            searchText = ""
            selection = []
            newReminder = draft
            focusNewRow()
            return
        }
        storedSelection = ReminderSidebarSelection.list(draft.original.listID).storageValue
        searchText = ""
        Task { @MainActor in
            selection = [draft.original.id]
            editingMode = .info
            editingSession = draft
        }
    }

    private var rowAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.22)
    }

    private func endEditing(restoreFocus: Bool = false) {
        persistCurrentEditor()
        if rowPopover?.rowID == editingID { rowPopover = nil }
        withAnimation(rowAnimation) { editingSession = nil }
        if restoreFocus {
            Task { @MainActor in
                await Task.yield()
                focus = .reminders
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

    private func beginRenaming(_ list: ReminderListRecord) {
        storedSelection = ReminderSidebarSelection.list(list.id).storageValue
        listNameDraft = list.title
        renamingListID = list.id
        Task { @MainActor in
            await Task.yield()
            focus = .listName(list.id)
        }
    }

    private func commitRenaming() {
        guard let id = renamingListID else { return }
        finishRenaming()
        let title = listNameDraft.trimmed
        guard let list = state.list(for: id), !title.isEmpty, title != list.title else { return }
        Task { await state.renameList(list, title: title) }
    }

    private func cancelRenaming() {
        finishRenaming()
    }

    /// The sidebar keeps focus after Return or Esc, as the Finder does after renaming.
    private func finishRenaming() {
        let hadFocus = renamingListID.map { focus == .listName($0) } ?? false
        renamingListID = nil
        if hadFocus { focus = .sidebar }
    }

    /// AppState joins a sync that's already running, so pressing ⌘R again does no harm.
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

    /// Deletes straight away, as Reminders does, and Edit ▸ Undo brings the reminders back. When
    /// Undo couldn't bring all of one back, such as a reminder that repeats, or the bridge is too old
    /// to say, it asks first.
    private func delete(_ reminders: [ReminderRecord], confirmed: Bool = false) {
        guard !reminders.isEmpty else { return }
        guard confirmed || reminders.allSatisfy({ $0.hasUnrestorableDetails == false }) else {
            remindersPendingDeletion = reminders
            return
        }
        if let session = editingSession, reminders.contains(where: { $0.id == session.original.id }) {
            state.discardEdit(session)
            editingSession = nil
        }
        advanceSelection(past: reminders)
        let undoManager = undoManager
        Task {
            var deleted: [ReminderRecord] = []
            for reminder in reminders where await state.deleteReminder(reminder) {
                deleted.append(reminder)
            }
            if deleted.count < reminders.count {
                // Select what's still there, so it's clear which ones didn't go.
                let deletedIDs = Set(deleted.map(\.id))
                let remaining = reminders.map(\.id).filter { !deletedIDs.contains($0) && state.reminder(for: $0) != nil }
                if !remaining.isEmpty { selection = Set(remaining) }
            }
            guard !deleted.isEmpty else { return }
            ReminderUndo.registerDeletion(deleted, state: state, undoManager: undoManager)
            let message = deleted.count == 1
                ? String(localized: "Deleted \(deleted[0].title)")
                : String(localized: "Deleted \(deleted.count) reminders")
            AccessibilityNotification.Announcement(message).post()
        }
    }

    private func dragProvider(for reminder: ReminderRecord) -> NSItemProvider {
        let dragged = selection.contains(reminder.id) ? selectedReminders : [reminder]
        ReminderDragSession.ids = dragged.map(\.id)
        let item = ReminderDragItem(ids: dragged.map(\.id), titles: dragged.map(\.title))
        let provider = NSItemProvider()
        provider.register(item)
        return provider
    }

    /// Handles reminders dropped on a view (moving or rescheduling them), and text dropped from
    /// another app (creating one reminder per line). The + button has its own drag.
    private func acceptDrop(_ providers: [NSItemProvider], into target: ReminderSidebarSelection,
                            shownIDs shownHere: Set<String>) -> Bool {
        if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.taskFerryReminders.identifier) }) {
            guard target != .all else { return false }
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
        let undoManager = undoManager
        Task {
            var created: [String] = []
            for title in titles.prefix(100) {
                if let id = await state.createReminder(title: title, listID: listID, due: due).createdID {
                    created.append(id)
                }
            }
            ReminderUndo.registerCreation(created, state: state, undoManager: undoManager)
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
    let isSelected: Bool
    /// Set while the reminder is being edited in place.
    let editing: ReminderEditSession?
    var focus: FocusState<WorkspaceFocus?>.Binding
    @Binding var popover: RowPopover?
    let onComplete: () -> Void
    let onShowInfo: () -> Void
    let onEdit: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @State private var isHoveringCompletion = false
    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isCompleting: Bool { state.completingIDs.contains(reminder.id) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: complete) {
                ZStack {
                    Circle()
                        .strokeBorder(listColor, lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    if isCompleting {
                        Image(systemName: "checkmark.circle.fill")
                            .resizable()
                            .frame(width: 18, height: 18)
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
                if let editing {
                    InlineReminderEditor(
                        session: editing,
                        rowID: reminder.id,
                        lists: state.snapshot.lists,
                        focus: focus,
                        titlePrompt: "Title",
                        titleLabel: "Reminder title",
                        popover: $popover,
                        onShowInfo: onShowInfo,
                        onSubmit: onSubmit,
                        onCancel: onCancel
                    )
                    .transition(.opacity)
                } else {
                    Text(ReminderLinks.attributed(reminder.title))
                        .font(.body)
                        .lineLimit(2)

                    if let notes = reminder.notes?.trimmed, !notes.isEmpty {
                        Text(ReminderLinks.attributed(notes))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if let url = reminder.url {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.callout)
                            .lineLimit(1)
                    }
                }

                // While editing, the row's own controls show the date and list.
                if editing == nil, let metadata {
                    metadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // As in Reminders, ⓘ shows on the row under the pointer or the selected one.
            if editing == nil {
                Button(action: onShowInfo) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .help("Show Info")
                .opacity(isHovering || isSelected ? 1 : 0)
                .allowsHitTesting(isHovering || isSelected)
                // The row offers Show Info as an action instead, and ⌘I works anywhere.
                .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Its selection is covered while it's edited, so its text mustn't take the selection's colours.
        .transformEnvironment(\.backgroundProminence) { if editing != nil { $0 = .standard } }
        // While its title is edited, the field has to be reachable on its own.
        .accessibilityElement(children: editing == nil ? .ignore : .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Mark as Completed", complete)
        .accessibilityAction(named: "Show Info", onShowInfo)
        .accessibilityAction(named: "Edit", onEdit)
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

/// The empty row at the end of a list that a new reminder is typed into, as in Reminders. It's the
/// same editor as an existing reminder's, so a reminder gets its notes and date as it's made.
private struct NewReminderRow: View {
    @Bindable var session: ReminderEditSession
    let lists: [ReminderListRecord]
    let color: Color
    var focus: FocusState<WorkspaceFocus?>.Binding
    @Binding var popover: RowPopover?
    let focusRequest: Int
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .strokeBorder(color.opacity(0.6), lineWidth: 1.5)
                .frame(width: 18, height: 18)
                .frame(width: 28, height: 28)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                .accessibilityHidden(true)
            InlineReminderEditor(
                session: session,
                rowID: RemindersWorkspaceView.newRowID,
                lists: lists,
                focus: focus,
                titlePrompt: "New Reminder",
                titleLabel: "New reminder title",
                focusRequest: focusRequest,
                popover: $popover,
                onSubmit: onSubmit,
                onCancel: onCancel
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// Where the + button's new row will go, under the last row of a section.
private struct NewRowIndicator: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
        }
        // Lined up with the reminder titles.
        .padding(.leading, 34)
        .offset(y: 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reports a reminder-list row's frame, for the + button's drag, and forgets it once it's gone.
private struct RowFrame: ViewModifier {
    let geometry: NewReminderDropGeometry
    let section: String
    let row: String

    func body(content: Content) -> some View {
        let key = section + "/" + row
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                geometry.rows[key] = (section, frame)
            }
            .onDisappear { geometry.rows[key] = nil }
    }
}

/// Shows which row a drag will land on, which a sidebar doesn't do for `onDrop` by itself.
private struct SidebarDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    let acceptsReminders: Bool
    let shownIDs: Set<String>
    let onDrop: ([NSItemProvider]) -> Bool
    /// Where the row is, for the + button's drag; nil once it's gone.
    let onFrame: (CGRect?) -> Void

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFrame($0) }
            .onDisappear { onFrame(nil) }
            .onDrop(of: RemindersWorkspaceView.dropTypes, delegate: ReminderListDropDelegate(
                shownIDs: shownIDs,
                acceptsReminders: acceptsReminders,
                isTargeted: $isTargeted,
                perform: onDrop
            ))
            .background {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.25))
                        .padding(-4)
                }
            }
    }
}

/// A sidebar row or the reminder list as a drop target. Reminders dragged onto the view they're
/// already in, or somewhere they can't go, would do nothing, so the target neither highlights nor
/// accepts them.
private struct ReminderListDropDelegate: DropDelegate {
    let shownIDs: Set<String>
    var acceptsReminders = true
    @Binding var isTargeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    private static var types: [UTType] { RemindersWorkspaceView.dropTypes }

    @MainActor
    private func isNoOp(_ info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [.taskFerryReminders]) else { return false }
        guard acceptsReminders else { return true }
        let ids = ReminderDragSession.ids
        return !ids.isEmpty && Set(ids).isSubset(of: shownIDs)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { isTargeted = !isNoOp(info) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            isNoOp(info) ? DropProposal(operation: .forbidden) : DropProposal(operation: .copy)
        }
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { isTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            isTargeted = false
            guard !isNoOp(info) else { return false }
            return perform(info.itemProviders(for: Self.types))
        }
    }
}

// MARK: - Status and onboarding

private struct SyncStatusView: View {
    let state: AppState

    var body: some View {
        Group {
            switch state.syncStatus {
            case .updatingCachedCopy:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                }
                .help("Showing reminders from your last session while Task Ferry syncs.")
            case .offline(let lastSync):
                Label {
                    if let lastSync {
                        // Once a minute is often enough for "updated 5 minutes ago".
                        TimelineView(.everyMinute) { _ in
                            Text("Offline · updated \(Text(lastSync, format: .relative(presentation: .named)))")
                        }
                    } else {
                        Text("Offline")
                    }
                } icon: {
                    Image(systemName: "wifi.slash")
                }
                .help("Task Ferry can’t reach your bridge right now and will keep trying.")
            case .failed(let message) where state.hasSnapshotToShow:
                Label("Not syncing", systemImage: "exclamationmark.triangle")
                    .help(message)
            case .notConfigured, .loading, .upToDate, .failed:
                EmptyView()
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The first sync failed, so there is nothing to show yet. The error banner says why, and this
/// stays useful after the banner is dismissed.
private struct LoadFailedView: View {
    let state: AppState
    @State private var isRetrying = false

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t Load Your Reminders", systemImage: "exclamationmark.icloud")
        } description: {
            Text("Your reminders appear here once Task Ferry reaches your bridge.")
        } actions: {
            Button(isRetrying ? "Trying…" : "Try Again") {
                isRetrying = true
                Task {
                    await state.refresh()
                    isRetrying = false
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRetrying)
            if state.errorNeedsSettings {
                SettingsLink { Text("Open Settings…") }
            }
        }
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
