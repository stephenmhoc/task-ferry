import SwiftUI

/// The due date as a small button reading "Today", "Tomorrow", "Friday", or "Nov 18", which opens a
/// popover of quick choices and a calendar, as in Reminders. With no date it reads "Add Date".
struct DueDateControl: View {
    @Bindable var session: ReminderEditSession
    /// Whether its popover is open. The row editor owns this, so Return can open it and Esc in the
    /// row closes it first.
    @Binding var isPresented: Bool

    var body: some View {
        let label = session.hasDue ? DueDayText.label(for: session.dueDate) : String(localized: "Add Date")
        Button { isPresented = true } label: {
            Label(label, systemImage: "calendar")
                .foregroundStyle(session.isOverdue() ? TaskFerryPalette.overdue : .primary)
        }
        .buttonStyle(.accessoryBar)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            DuePopover(session: session, isPresented: $isPresented)
        }
        .accessibilityLabel(session.hasDue ? Text("Due date") : Text("Add Date"))
        .accessibilityValue(session.hasDue ? Text(label) : Text(""))
        .help(session.hasDue ? "Change the date" : "Add a date")
    }
}

/// The time as a small button reading "5:00 PM", which opens quick times and a time picker. With no
/// time it reads "Add Time". Only shown once there's a date.
struct DueTimeControl: View {
    @Bindable var session: ReminderEditSession
    @Binding var isPresented: Bool

    var body: some View {
        let label = session.includesTime
            ? session.dueDate.formatted(date: .omitted, time: .shortened)
            : String(localized: "Add Time")
        Button { isPresented = true } label: {
            Label(label, systemImage: "clock")
                .foregroundStyle(session.includesTime && session.isOverdue() ? TaskFerryPalette.overdue : .primary)
        }
        .buttonStyle(.accessoryBar)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            TimePopover(session: session, isPresented: $isPresented)
        }
        .accessibilityLabel(session.includesTime ? Text("Time") : Text("Add Time"))
        .accessibilityValue(session.includesTime ? Text(label) : Text(""))
        .help(session.includesTime ? "Change the time" : "Add a time")
    }
}

/// Quick choices, a calendar, and Remove Date. Choosing a day closes it.
private struct DuePopover: View {
    @Bindable var session: ReminderEditSession
    @Binding var isPresented: Bool

    var body: some View {
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                QuickChoice("Today", systemImage: "calendar", detail: weekday(today)) { choose(today) }
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
                QuickChoice("Tomorrow", systemImage: "sunrise", detail: weekday(tomorrow)) { choose(tomorrow) }
                let weekend = DueDayText.nextWeekend(after: today)
                QuickChoice("Next Weekend", systemImage: "sofa", detail: shortDate(weekend)) { choose(weekend) }
                let week = DueDayText.nextWeek(after: today)
                QuickChoice("Next Week", systemImage: "arrow.right.circle", detail: shortDate(week)) { choose(week) }
            }
            Divider()
            MonthCalendar(selection: session.hasDue ? session.dueDate : nil, onChoose: choose)
            if session.hasDue {
                Divider()
                QuickChoice("Remove Date", systemImage: "xmark.circle", detail: "") {
                    session.removeDueDate()
                    isPresented = false
                }
            }
        }
        .padding(12)
        .frame(width: 264)
    }

    private func choose(_ day: Date) {
        session.setDueDay(day)
        isPresented = false
    }

    private func weekday(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated)) }
    private func shortDate(_ date: Date) -> String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
}

/// Quick times, a time picker, and Remove Time. A quick time closes it; the picker doesn't, since
/// it's typed into.
private struct TimePopover: View {
    @Bindable var session: ReminderEditSession
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                QuickChoice("Morning", systemImage: "sunrise", detail: clock(9)) { choose(9) }
                QuickChoice("Afternoon", systemImage: "sun.max", detail: clock(13)) { choose(13) }
                QuickChoice("Evening", systemImage: "moon", detail: clock(18)) { choose(18) }
            }
            Divider()
            DatePicker("Time", selection: Binding(
                get: { session.includesTime ? session.dueDate : session.proposedTime() },
                set: { time in
                    let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: time)
                    session.setDueTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
                }
            ), displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .padding(.horizontal, 6)
            if session.includesTime {
                Divider()
                QuickChoice("Remove Time", systemImage: "xmark.circle", detail: "") {
                    session.removeDueTime()
                    isPresented = false
                }
            }
        }
        .padding(12)
        .frame(width: 236)
    }

    private func choose(_ hour: Int) {
        session.setDueTime(hour: hour, minute: 0)
        isPresented = false
    }

    private func clock(_ hour: Int) -> String {
        let date = Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// One line of a date or time popover: an icon, a name, and what it means, such as "Sat, Nov 15".
private struct QuickChoice: View {
    let title: LocalizedStringKey
    let systemImage: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    init(_ title: LocalizedStringKey, systemImage: String, detail: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(detail)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A month of days that fills its popover, on a clear background, like the calendar in Reminders.
/// The system's graphical `DatePicker` has a fixed, small size and its own bezel, so it can't.
private struct MonthCalendar: View {
    let selection: Date?
    let onChoose: (Date) -> Void
    @State private var month: Date
    private let calendar = Calendar.autoupdatingCurrent

    init(selection: Date?, onChoose: @escaping (Date) -> Void) {
        self.selection = selection
        self.onChoose = onChoose
        let cal = Calendar.autoupdatingCurrent
        let start = cal.dateInterval(of: .month, for: selection ?? Date())?.start ?? Date()
        _month = State(initialValue: start)
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.headline)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous Month")
                    .accessibilityLabel("Previous Month")
                Button { month = startOfMonth(Date()) } label: { Image(systemName: "circle.fill").font(.system(size: 6)) }
                    .help("This Month")
                    .accessibilityLabel("This Month")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next Month")
                    .accessibilityLabel("Next Month")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)

            Grid(horizontalSpacing: 0, verticalSpacing: 2) {
                GridRow {
                    ForEach(weekdaySymbols.indices, id: \.self) { index in
                        Text(weekdaySymbols[index])
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(weeks.indices, id: \.self) { row in
                    GridRow {
                        ForEach(weeks[row], id: \.self) { day in
                            DayCell(
                                day: day,
                                inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                                isToday: calendar.isDateInToday(day),
                                isSelected: selection.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                            ) { onChoose(day) }
                        }
                    }
                }
            }
        }
    }

    private func step(_ months: Int) {
        month = calendar.date(byAdding: .month, value: months, to: month) ?? month
    }

    private func startOfMonth(_ date: Date) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// Very short weekday names, starting on the user's first day of the week.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Six weeks of days, so the popover keeps one height from month to month.
    private var weeks: [[Date]] {
        let weekday = calendar.component(.weekday, from: month)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let first = calendar.date(byAdding: .day, value: -lead, to: month) else { return [] }
        return (0..<6).map { week in
            (0..<7).compactMap { calendar.date(byAdding: .day, value: week * 7 + $0, to: first) }
        }
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(day.formatted(.dateTime.day()))
                .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(foreground)
                .frame(width: 26, height: 26)
                .background {
                    Circle().fill(isSelected ? Color.accentColor : isHovering ? Color.primary.opacity(0.08) : .clear)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(day.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foreground: Color {
        if isSelected { return .white }
        if isToday { return .accentColor }
        return inMonth ? .primary : .secondary.opacity(0.6)
    }
}
