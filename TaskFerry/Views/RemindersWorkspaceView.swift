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
    /// The title of a reminder being renamed in its row.
    case title(String)
    /// The empty row a new reminder is typed into.
    case newReminder
    /// A list being renamed in the sidebar.
    case listName(String)
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
    fileprivate static let newRowID = "new-reminder-row"
    fileprivate static let dropTypes: [UTType] = [.taskFerryNewReminder, .taskFerryReminders, .plainText]

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

    private var workspace: some View {
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
            if newReminder?.title.trimmed.isEmpty == false { commitNewReminder(continuing: false) }
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
                newReminderInList: { beginNewReminder(in: .list($0)) }
            )
            .padding(FloatingNewReminderButton.inset)
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
            onDrop: { acceptDrop($0, into: destination, shownIDs: shownIDs) }
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
            .onDrop(of: Self.dropTypes, delegate: ReminderListDropDelegate(
                shownIDs: Set(displayed.map(\.id)),
                // Search results from everywhere aren't the view on screen, so there's nowhere to
                // move a reminder to.
                acceptsReminders: !isSearchingAll && currentSelection != .all,
                isTargeted: $isDropTargeted,
                perform: { acceptDrop($0, into: currentSelection, shownIDs: Set(displayed.map(\.id))) }
            ))
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
            // Return edits the selected reminder's title in place, as in Reminders.
            .onKeyPress(.return) {
                guard editingID == nil, focus != .newReminder, !selection.isEmpty else { return .ignored }
                beginEditing(selection, mode: .inline)
                return .handled
            }
            .onKeyPress(.escape) {
                guard editingID == nil, focus != .newReminder, !selection.isEmpty else { return .ignored }
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
        ForEach(section.reminders) { reminder in
            ReminderRow(
                state: state,
                reminder: reminder,
                // List titles scroll away, so a row has to say where it belongs by itself.
                showsList: !showsSingleList,
                showsFullDate: currentSelection == .all || currentSelection.isList || section.isOverdue || isSearchingAll,
                editing: editingMode == .inline && editingID == reminder.id ? editingSession : nil,
                focus: $focus,
                onComplete: { complete([reminder]) },
                onSubmit: saveCurrentEditor,
                onCancel: cancelCurrentEditor
            )
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
            .tag(reminder.id)
            .id(reminder.id)
            .listRowSeparator(.hidden)
        }
        if let newReminder, section.id == newRowSectionID {
            NewReminderRow(
                session: newReminder,
                color: Color(hex: state.list(for: newReminder.listID)?.colorHex ?? TaskFerryPalette.defaultListHex),
                focus: $focus,
                focusRequest: newRowFocusRequest,
                onSubmit: { commitNewReminder(continuing: true) },
                onCancel: cancelNewReminder
            )
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
        let departed = current != nil && (current != .reminders || userJustMovedFocus)
        switch previous {
        case .newReminder:
            guard newReminder != nil else { return }
            if departed {
                commitNewReminder(continuing: false)
            } else {
                restoreFocus(.newReminder)
            }
        case .title(let id):
            guard editingMode == .inline, editingID == id else { return }
            if departed {
                endEditing()
            } else {
                restoreFocus(.title(id))
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

    /// Gives focus back once; if the field isn't on screen to take it, it's left alone.
    private func restoreFocus(_ target: WorkspaceFocus) {
        guard restoredFocus != target else { return }
        restoredFocus = target
        focus = target
    }

    private func beginNewReminder() {
        beginNewReminder(in: currentSelection)
    }

    /// Adds an empty row to type into, at the end of the list on screen or the one the + button was
    /// dropped on. In Today, Tomorrow, and All Reminders, it goes in the default list.
    private func beginNewReminder(in target: ReminderSidebarSelection) {
        guard !state.snapshot.lists.isEmpty else {
            listEditor = .create
            return
        }
        let listID: String?
        if case .list(let id) = target {
            listID = id
        } else {
            listID = state.newReminderListID
        }
        guard let listID else { return }
        if let current = newReminder {
            if current.title.trimmed.isEmpty, current.listID == listID, newReminderView == target.storageValue {
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
        guard !session.title.trimmed.isEmpty else {
            cancelNewReminder()
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
                      newReminder?.title.trimmed.isEmpty ?? true {
                newReminder = session
                focusNewRow()
            }
        }
    }

    private func cancelNewReminder() {
        guard let session = newReminder else { return }
        let hadFocus = focus == .newReminder
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
            editingMode = mode
            return
        }
        persistCurrentEditor()
        selection = [id]
        editingMode = mode
        editingSession = state.unsavedEdits.values.first(where: { $0.original.id == id })
            ?? state.reminder(for: id).map { ReminderEditSession($0, connectionRevision: state.connectionRevision) }
        // The title field focuses itself as it appears.
    }

    /// Review opens a failed draft in Show Info, where every field it changed can be seen. A new
    /// reminder goes back into its row instead.
    private func review(_ draft: ReminderEditSession) {
        if draft.isNew {
            if let current = newReminder, current.title.trimmed.isEmpty { cancelNewReminder() }
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

    private func endEditing(restoreFocus: Bool = false) {
        persistCurrentEditor()
        editingSession = nil
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

    /// Handles the + button dropped on a view (starting a reminder there), reminders dropped on a
    /// view (moving or rescheduling them), and text dropped from another app (creating one
    /// reminder per line).
    private func acceptDrop(_ providers: [NSItemProvider], into target: ReminderSidebarSelection,
                            shownIDs shownHere: Set<String>) -> Bool {
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.taskFerryNewReminder.identifier) }) {
            beginNewReminder(in: target)
            return true
        }
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
    /// Set while the title is being edited in place.
    let editing: ReminderEditSession?
    var focus: FocusState<WorkspaceFocus?>.Binding
    let onComplete: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @State private var isHoveringCompletion = false
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
                    InlineTitleField(session: editing, id: reminder.id, focus: focus, onSubmit: onSubmit, onCancel: onCancel)
                } else {
                    Text(ReminderLinks.attributed(reminder.title))
                        .font(.body)
                        .lineLimit(2)
                }

                if let notes = reminder.notes?.trimmed, !notes.isEmpty {
                    Text(ReminderLinks.attributed(notes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let url = reminder.url {
                    Link(destination: url) {
                        Label(url.absoluteString, systemImage: "link")
                            .font(.callout)
                            .lineLimit(1)
                    }
                }

                if let metadata {
                    metadata
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        // While its title is edited, the field has to be reachable on its own.
        .accessibilityElement(children: editing == nil ? .ignore : .contain)
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

/// A reminder's title as a text field, in its own row. Return saves, Esc puts it back.
private struct InlineTitleField: View {
    @Bindable var session: ReminderEditSession
    let id: String
    var focus: FocusState<WorkspaceFocus?>.Binding
    let onSubmit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        // Read-only while it saves, rather than disabled, which would take its focus away.
        TextField("Title", text: Binding(
            get: { session.title },
            set: { if session.phase != .saving { session.title = $0 } }
        ), prompt: Text("Title"))
            .labelsHidden()
            .textFieldStyle(.plain)
            .font(.body)
            .focused(focus, equals: .title(id))
            .onSubmit(onSubmit)
            .onExitCommand(perform: onCancel)
            .onAppear { focus.wrappedValue = .title(id) }
            .accessibilityLabel("Reminder title")
        if let error = session.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - New reminders

/// The empty row at the end of a list that a new reminder is typed into, as in Reminders.
private struct NewReminderRow: View {
    @Bindable var session: ReminderEditSession
    let color: Color
    var focus: FocusState<WorkspaceFocus?>.Binding
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
            VStack(alignment: .leading, spacing: 3) {
                TextField("New Reminder", text: Binding(
                    get: { session.title },
                    set: { if session.phase != .saving { session.title = $0 } }
                ), prompt: Text("New Reminder"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused(focus, equals: .newReminder)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
                    // The row only exists once the list has drawn it, so it takes focus itself.
                    .onAppear { focus.wrappedValue = .newReminder }
                    .onChange(of: focusRequest) { _, _ in focus.wrappedValue = .newReminder }
                    .accessibilityLabel("New reminder title")
                if let error = session.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let due = session.original.due {
                    Text(due.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
    }
}

/// Click for a new reminder in the list on screen, or drag it onto a list in the sidebar to start
/// one there, like the Magic Plus button in Things.
private struct FloatingNewReminderButton: View {
    /// The button's diameter, and its distance from the window's corner.
    static let size: CGFloat = 48
    static let inset: CGFloat = 16
    /// How far the reminder list scrolls past its end, so the last row can clear the button.
    static var clearance: CGFloat { size + inset }

    let lists: [ReminderListRecord]
    let action: () -> Void
    let newReminderInList: (String) -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var glyph = AccentGlyph.current

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(glyph.color)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
        .overlay {
            if contrast == .increased {
                Circle().strokeBorder(.primary.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
            }
        }
        .draggable(NewReminderDragItem()) {
            Image(systemName: "plus")
                .font(.title2.weight(.semibold))
                .foregroundStyle(glyph.color)
                .frame(width: Self.size, height: Self.size)
                .background(Color.accentColor, in: Circle())
        }
        .help("New Reminder")
        .accessibilityLabel("New Reminder")
        .accessibilityHint("Drag onto a list in the sidebar to add the reminder there.")
        .accessibilityActions {
            ForEach(lists) { list in
                Button("New Reminder in \(list.title)") { newReminderInList(list.id) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSColor.systemColorsDidChangeNotification)) { _ in
            glyph = AccentGlyph.current
        }
    }
}

/// White on the accent color, as on other prominent buttons, but near-black on a light one like
/// Yellow, where white would wash out.
private enum AccentGlyph: Equatable {
    case light, dark

    static var current: Self {
        guard let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) else { return .light }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(accent.redComponent) + 0.7152 * linear(accent.greenComponent)
            + 0.0722 * linear(accent.blueComponent)
        // macOS puts white on every accent but the light ones, Yellow above all, where it washes out.
        return luminance > 0.45 ? .dark : .light
    }

    var color: Color {
        switch self {
        case .light: .white
        case .dark: Color.black.opacity(0.85)
        }
    }
}

/// Shows which row a drag will land on, which a sidebar doesn't do for `onDrop` by itself.
private struct SidebarDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    let acceptsReminders: Bool
    let shownIDs: Set<String>
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        content
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
