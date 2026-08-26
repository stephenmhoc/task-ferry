import SwiftUI

private enum ReminderSidebarSelection: Hashable {
    case today
    case tomorrow
    case all
    case list(String)

    init(storageValue: String) {
        switch storageValue {
        case "today":
            self = .today
        case "tomorrow":
            self = .tomorrow
        case "all":
            self = .all
        default:
            if storageValue.hasPrefix("list:") {
                self = .list(String(storageValue.dropFirst(5)))
            } else {
                self = .today
            }
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

    var rowContext: ReminderRowContext {
        switch self {
        case .today, .tomorrow: .day
        case .all: .all
        case .list: .list
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max.fill"
        case .tomorrow: "moon.stars.fill"
        case .all: "tray.full.fill"
        case .list: "square.grid.2x2.fill"
        }
    }

    var quickDueLabel: String? {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .all, .list: nil
        }
    }

    var emptyTitle: String {
        switch self {
        case .today: "A clear day"
        case .tomorrow: "Tomorrow is open"
        case .all: "Nothing left to do"
        case .list: "This list is ready"
        }
    }

    func title(listTitle: String?) -> String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .all: "All Tasks"
        case .list: listTitle ?? "List"
        }
    }

    func subtitle(today: Date, tomorrow: Date) -> String {
        switch self {
        case .today:
            today.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .tomorrow:
            tomorrow.formatted(.dateTime.weekday(.wide).month(.wide).day())
        case .all:
            "Everything still open in Apple Reminders"
        case .list:
            "A focused project from Apple Reminders"
        }
    }

    func color(listColorHex: String?) -> Color {
        switch self {
        case .today: TaskFerryPalette.coral
        case .tomorrow: TaskFerryPalette.seaGlass
        case .all: TaskFerryPalette.ocean
        case .list: Color(hex: listColorHex ?? TaskFerryPalette.defaultListHex)
        }
    }

    func quickDue(today: Date, tomorrow: Date) -> ReminderDue? {
        switch self {
        case .today: ReminderDue(date: today, includesTime: false)
        case .tomorrow: ReminderDue(date: tomorrow, includesTime: false)
        case .all, .list: nil
        }
    }
}

private enum ReminderRowContext {
    case day
    case all
    case list
}

private struct ReminderListGroup: Identifiable {
    let id: String
    let list: ReminderListRecord?
    let reminders: [ReminderRecord]
}

private struct ReminderBucket: Identifiable {
    let id: String
    let title: String?
    let listGroups: [ReminderListGroup]
}

struct RemindersWorkspaceView: View {
    @Bindable var state: AppState

    @SceneStorage("TaskFerry.sidebar-selection") private var storedSelection = "today"
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var selectedReminderID: String?
    @State private var searchText = ""
    @State private var composerFocusRequest = 0
    @State private var listEditor: ListEditorContext?
    @State private var reminderPendingDeletion: ReminderRecord?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            taskList
        }
        .navigationSplitViewStyle(.balanced)
        .focusedSceneValue(
            \.newReminderAction,
            TaskFerryCommandAction(perform: beginNewReminder)
        )
        .focusedSceneValue(
            \.refreshRemindersAction,
            TaskFerryCommandAction(perform: refresh)
        )
        .task {
            await state.refresh()
            repairSelectionIfNeeded()
        }
        .onChange(of: storedSelection) { _, _ in
            selectedReminderID = nil
        }
        .onChange(of: state.snapshot.lists) { _, _ in
            repairSelectionIfNeeded()
        }
        .onChange(of: state.snapshot.reminders) { _, reminders in
            guard let selectedReminderID else { return }
            if !reminders.contains(where: { $0.id == selectedReminderID }) {
                self.selectedReminderID = nil
            }
        }
        .sheet(item: $listEditor) { context in
            ListEditorSheet(state: state, context: context)
        }
        .alert(
            "Delete Reminder?",
            isPresented: Binding(
                get: { reminderPendingDeletion != nil },
                set: { if !$0 { reminderPendingDeletion = nil } }
            ),
            presenting: reminderPendingDeletion
        ) { reminder in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                delete(reminder)
            }
        } message: { reminder in
            Text(ReminderDeletionCopy.message(for: reminder.title))
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Focus") {
                smartSidebarRow(
                    title: "Today",
                    symbol: "sun.max.fill",
                    color: TaskFerryPalette.coral,
                    count: state.todayReminders.count
                )
                .tag(ReminderSidebarSelection.today)

                smartSidebarRow(
                    title: "Tomorrow",
                    symbol: "moon.stars.fill",
                    color: TaskFerryPalette.seaGlass,
                    count: state.tomorrowReminders.count
                )
                .tag(ReminderSidebarSelection.tomorrow)

                smartSidebarRow(
                    title: "All Tasks",
                    symbol: "tray.full.fill",
                    color: TaskFerryPalette.ocean,
                    count: state.snapshot.reminders.count
                )
                .tag(ReminderSidebarSelection.all)
            }

            Section("Lists & Projects") {
                ForEach(state.snapshot.lists) { list in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(Color(hex: list.colorHex))
                            .frame(width: 9, height: 9)
                        Text(list.title)
                            .lineLimit(1)
                        Spacer()
                        sidebarCount(reminderCountsByList[list.id, default: 0])
                    }
                    .tag(ReminderSidebarSelection.list(list.id))
                    .contextMenu {
                        Button("Edit List…") {
                            listEditor = .edit(list)
                        }
                    }
                }

                Button {
                    listEditor = .create
                } label: {
                    Label("New List", systemImage: "plus")
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Creates a new list in Apple Reminders")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Task Ferry")
        .navigationSplitViewColumnWidth(min: 185, ideal: 215, max: 260)
        .toolbar {
            if columnVisibility != .detailOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh Reminders (⌘R)")
                    .accessibilityLabel("Refresh reminders")
                }
            }
        }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            workspaceHeader

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            if state.connectionState == .loading && state.snapshot.reminders.isEmpty {
                Spacer()
                ProgressView("Loading your reminders…")
                Spacer()
            } else if displayedReminders.isEmpty {
                EmptyWorkspaceView(
                    isSearching: !searchText.trimmed.isEmpty,
                    selection: currentSelection,
                    canCreate: !state.snapshot.lists.isEmpty,
                    create: beginNewReminder
                )
            } else {
                reminderList
            }

            QuickTaskComposer(
                state: state,
                selection: currentSelection,
                lists: state.snapshot.lists,
                contextTitle: displayTitle,
                dueLabel: quickDueLabel,
                lockedListID: selectedList?.id,
                focusRequest: composerFocusRequest
            ) { newReminderID in
                selectedReminderID = newReminderID
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(displayTitle)
        .navigationSplitViewColumnWidth(min: 560, ideal: 820, max: 1_200)
        .searchable(text: $searchText, prompt: "Search this view")
    }

    private var reminderList: some View {
        List {
            ForEach(reminderBuckets) { bucket in
                if let title = bucket.title {
                    Section {
                        listGroups(bucket.listGroups)
                    } header: {
                        HStack {
                            Text(title)
                            Spacer()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(title == "Overdue" ? TaskFerryPalette.coral : Color.secondary)
                        .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                    }
                } else {
                    listGroups(bucket.listGroups)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.22), value: selectedReminderID)
    }

    @ViewBuilder
    private func listGroups(_ groups: [ReminderListGroup]) -> some View {
        ForEach(groups) { group in
            if let list = group.list {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: list.colorHex))
                        .frame(width: 6, height: 6)
                    Text(list.title)
                        .lineLimit(1)
                    Spacer()
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.top, 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 63, bottom: 0, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityAddTraits(.isHeader)
            }
            reminderRows(group.reminders)
        }
    }

    private func reminderRows(_ reminders: [ReminderRecord]) -> some View {
        ForEach(reminders) { reminder in
            VStack(spacing: 0) {
                if selectedReminderID == reminder.id {
                    InlineReminderEditor(
                        state: state,
                        reminder: reminder,
                        onDeleteRequested: { reminderPendingDeletion = reminder }
                    ) {
                        withAnimation(.snappy(duration: 0.22)) {
                            selectedReminderID = nil
                        }
                    }
                    .id(reminder.id)
                    .transition(.opacity)
                } else {
                    WorkspaceReminderRow(
                        state: state,
                        reminder: reminder,
                        context: rowContext,
                        onToggle: { toggleDetails(for: reminder) }
                    )
                }

                Divider()
                    .padding(.leading, 39)
                    .opacity(0.55)
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .contextMenu {
                Button(selectedReminderID == reminder.id ? "Collapse Details" : "Expand Details") {
                    toggleDetails(for: reminder)
                }
                Button("Mark as Complete") {
                    complete(reminder)
                }
                Divider()
                Button("Delete…", role: .destructive) {
                    reminderPendingDeletion = reminder
                }
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: displaySymbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(displayColor)
                .frame(width: 42, height: 42)
                .background(displayColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.system(size: 31, weight: .bold, design: .rounded))
                Text(displaySubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(displayedReminders.count)")
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .accessibilityLabel("\(displayedReminders.count) open reminders")
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
    }

    private func smartSidebarRow(title: String, symbol: String, color: Color, count: Int) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
            Spacer()
            sidebarCount(count)
        }
    }

    @ViewBuilder
    private func sidebarCount(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
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

    private var baseReminders: [ReminderRecord] {
        switch currentSelection {
        case .today:
            state.todayReminders
        case .tomorrow:
            state.tomorrowReminders
        case .all:
            state.allReminders
        case .list(let id):
            state.reminders(in: id)
        }
    }

    private var displayedReminders: [ReminderRecord] {
        let query = searchText.trimmed
        guard !query.isEmpty else { return baseReminders }
        return baseReminders.filter { reminder in
            reminder.title.localizedCaseInsensitiveContains(query)
                || reminder.notes?.localizedCaseInsensitiveContains(query) == true
                || state.list(for: reminder.listID)?.title.localizedCaseInsensitiveContains(query) == true
        }
    }

    private var reminderBuckets: [ReminderBucket] {
        switch currentSelection {
        case .today:
            let overdue = displayedReminders.filter { $0.due?.isBeforeDay(Date()) == true }
            let everythingElse = displayedReminders.filter { $0.due?.isBeforeDay(Date()) != true }
            var buckets: [ReminderBucket] = []

            if !overdue.isEmpty {
                buckets.append(ReminderBucket(
                    id: "overdue",
                    title: "Overdue",
                    listGroups: groupByList(overdue)
                ))
            }

            if !everythingElse.isEmpty {
                buckets.append(ReminderBucket(
                    id: "everything",
                    title: overdue.isEmpty ? "Everything" : "Everything Else",
                    listGroups: groupByList(everythingElse)
                ))
            }

            return buckets
        case .tomorrow:
            return [ReminderBucket(
                id: "tomorrow",
                title: nil,
                listGroups: groupByList(displayedReminders)
            )]
        case .all, .list:
            return [ReminderBucket(
                id: "tasks",
                title: nil,
                listGroups: [ReminderListGroup(id: "tasks", list: nil, reminders: displayedReminders)]
            )]
        }
    }

    private func groupByList(_ reminders: [ReminderRecord]) -> [ReminderListGroup] {
        let remindersByList = Dictionary(grouping: reminders, by: \.listID)
        let knownGroups = state.snapshot.lists.compactMap { list -> ReminderListGroup? in
            guard let matching = remindersByList[list.id], !matching.isEmpty else { return nil }
            return ReminderListGroup(id: list.id, list: list, reminders: matching)
        }
        let knownListIDs = Set(state.snapshot.lists.map(\.id))
        let unknown = reminders.filter { !knownListIDs.contains($0.listID) }

        guard !unknown.isEmpty else { return knownGroups }
        return knownGroups + [ReminderListGroup(id: "unknown", list: nil, reminders: unknown)]
    }

    private var rowContext: ReminderRowContext {
        currentSelection.rowContext
    }

    private var displayTitle: String {
        currentSelection.title(listTitle: selectedList?.title)
    }

    private var displaySubtitle: String {
        currentSelection.subtitle(today: Date(), tomorrow: tomorrowDate)
    }

    private var displaySymbol: String {
        currentSelection.symbol
    }

    private var displayColor: Color {
        currentSelection.color(listColorHex: selectedList?.colorHex)
    }

    private var tomorrowDate: Date {
        Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    private var quickDueLabel: String? {
        currentSelection.quickDueLabel
    }

    private var reminderCountsByList: [String: Int] {
        state.snapshot.reminders.reduce(into: [:]) { counts, reminder in
            counts[reminder.listID, default: 0] += 1
        }
    }

    private func beginNewReminder() {
        guard !state.snapshot.lists.isEmpty else {
            listEditor = .create
            return
        }
        composerFocusRequest += 1
    }

    private func complete(_ reminder: ReminderRecord) {
        Task { await state.complete(reminder) }
    }

    private func toggleDetails(for reminder: ReminderRecord) {
        withAnimation(.snappy(duration: 0.22)) {
            selectedReminderID = selectedReminderID == reminder.id ? nil : reminder.id
        }
    }

    private func delete(_ reminder: ReminderRecord) {
        reminderPendingDeletion = nil
        Task { await state.deleteReminder(reminder) }
    }

    private func refresh() {
        Task { await state.refresh(showLoadingIndicator: false) }
    }

    private func repairSelectionIfNeeded() {
        guard state.hasLoadedSnapshot, case .list(let id) = currentSelection else { return }
        if !state.snapshot.lists.contains(where: { $0.id == id }) {
            storedSelection = ReminderSidebarSelection.today.storageValue
        }
    }
}

private struct WorkspaceReminderRow: View {
    let state: AppState
    let reminder: ReminderRecord
    let context: ReminderRowContext
    let onToggle: () -> Void

    @State private var isHoveringCompletion = false
    @State private var isCompleting = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: complete) {
                ZStack {
                    Circle()
                        .stroke(listColor, lineWidth: 1.7)
                        .frame(width: 19, height: 19)
                    if isHoveringCompletion || isCompleting {
                        Image(systemName: isCompleting ? "ellipsis" : "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(listColor)
                    }
                }
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHoveringCompletion = $0 }
            .help("Mark as Complete")
            .accessibilityLabel("Complete \(reminder.title)")
            .disabled(isCompleting)

            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)

                if let notes = reminder.notes?.trimmed, !notes.isEmpty {
                    Text(notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                metadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .accessibilityAction(named: "Expand Details", onToggle)
    }

    @ViewBuilder
    private var metadata: some View {
        switch context {
        case .day:
            HStack(spacing: 6) {
                listLabel
                if let text = reminder.due?.displayText {
                    Text("·")
                    Text(text)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .all:
            HStack(spacing: 6) {
                listLabel
                if let due = reminder.due {
                    Text("·")
                    Text(due.summary)
                        .foregroundStyle(isOverdue ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .list:
            if let due = reminder.due {
                Text(due.summary)
                    .font(.caption)
                    .foregroundStyle(isOverdue ? .red : .secondary)
            }
        }
    }

    private var listLabel: some View {
        HStack(spacing: 5) {
            Circle().fill(listColor).frame(width: 6, height: 6)
            Text(state.list(for: reminder.listID)?.title ?? "Unknown List")
        }
    }

    private var listColor: Color {
        Color(hex: state.list(for: reminder.listID)?.colorHex ?? TaskFerryPalette.defaultListHex)
    }

    private var isOverdue: Bool {
        reminder.due?.isBeforeDay(Date()) == true
    }

    private func complete() {
        guard !isCompleting else { return }
        isCompleting = true
        Task {
            let succeeded = await state.complete(reminder)
            if !succeeded {
                isCompleting = false
            }
        }
    }
}

private struct QuickTaskComposer: View {
    let state: AppState
    let selection: ReminderSidebarSelection
    let lists: [ReminderListRecord]
    let contextTitle: String
    let dueLabel: String?
    let lockedListID: String?
    let focusRequest: Int
    let onCreated: (String?) -> Void

    @State private var title = ""
    @State private var selectedListID = ""
    @State private var isSubmitting = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TaskFerryPalette.ocean)
                .frame(width: 25, height: 25)
                .background(TaskFerryPalette.ocean.opacity(0.10), in: Circle())

            TextField("New task in \(contextTitle)", text: $title)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .disabled(isSubmitting)
                .accessibilityHint("Press Return to add the reminder")

            if let dueLabel {
                Label(dueLabel, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }

            if lockedListID != nil {
                listLabel
            } else {
                Menu {
                    ForEach(lists) { list in
                        Button(list.title) { selectedListID = list.id }
                    }
                } label: {
                    listLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose List")
                .disabled(isSubmitting)
            }

            Button(action: submit) {
                Image(systemName: isSubmitting ? "clock" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSubmit ? TaskFerryPalette.ocean : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .accessibilityLabel("Add reminder")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .task { selectDefaultListIfNeeded() }
        .onChange(of: lists) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: selection) { _, _ in selectDefaultListIfNeeded() }
        .onChange(of: focusRequest) { _, _ in
            selectDefaultListIfNeeded()
            focused = true
        }
    }

    private var listLabel: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(selectedListColor)
                .frame(width: 7, height: 7)
            Text(selectedListTitle)
                .font(.caption)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }

    private var selectedListTitle: String {
        lists.first { $0.id == effectiveListID }?.title ?? "List"
    }

    private var selectedListColor: Color {
        Color(hex: lists.first { $0.id == effectiveListID }?.colorHex ?? TaskFerryPalette.defaultListHex)
    }

    private var canSubmit: Bool {
        !isSubmitting && !title.trimmed.isEmpty && !effectiveListID.isEmpty
    }

    private var effectiveListID: String {
        lockedListID ?? selectedListID
    }

    private var due: ReminderDue? {
        let today = Date()
        let tomorrow = Calendar.autoupdatingCurrent.date(byAdding: .day, value: 1, to: today) ?? today
        return selection.quickDue(today: today, tomorrow: tomorrow)
    }

    private func selectDefaultListIfNeeded() {
        if let lockedListID, lists.contains(where: { $0.id == lockedListID }) {
            selectedListID = lockedListID
            return
        }
        guard !lists.contains(where: { $0.id == selectedListID }) else { return }
        selectedListID = state.defaultListID ?? lists.first?.id ?? ""
    }

    private func submit() {
        let cleanTitle = title.trimmed
        let listID = effectiveListID
        guard !cleanTitle.isEmpty, !listID.isEmpty, !isSubmitting else { return }
        let previousIDs = Set(state.snapshot.reminders.map(\.id))
        let pendingDue = due
        isSubmitting = true

        Task {
            let succeeded = await state.createReminder(
                title: cleanTitle,
                listID: listID,
                due: pendingDue
            )
            if succeeded {
                title = ""
                let newReminderID = state.snapshot.reminders.first {
                    !previousIDs.contains($0.id)
                }?.id
                onCreated(newReminderID)
            }
            isSubmitting = false
            focused = true
        }
    }
}

private struct EmptyWorkspaceView: View {
    let isSearching: Bool
    let selection: ReminderSidebarSelection
    let canCreate: Bool
    let create: () -> Void

    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(TaskFerryPalette.seaGlass.opacity(0.11))
                    .frame(width: 68, height: 68)
                Image(systemName: isSearching ? "magnifyingglass" : "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(TaskFerryPalette.seaGlass)
            }

            Text(title)
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if canCreate && !isSearching {
                Button("New Reminder", action: create)
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        if isSearching { return "No matching tasks" }
        return selection.emptyTitle
    }

    private var message: String {
        if isSearching { return "Try a different title, note, or list name." }
        return "Add a reminder below when something comes up."
    }
}
