import SwiftUI

struct ReminderRow: View {
    enum Context: Equatable {
        case day
        case list
    }

    @Bindable var state: AppState
    let reminder: ReminderRecord
    let context: Context
    @State private var isHoveringCompletion = false

    var body: some View {
        HStack(spacing: 11) {
            Button {
                Task { await state.complete(reminder) }
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(completionColor)
                    .frame(width: 28, height: 28)
                    .overlay {
                        if context == .day, isHoveringCompletion {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(completionColor)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(reminder.title)")
            .help("Mark as Complete")
            .onHover { isHoveringCompletion = $0 }

            NavigationLink {
                ReminderEditorView(state: state, reminder: reminder, defaultListID: reminder.listID)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(reminder.title)
                        .foregroundStyle(.primary)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Mark as Complete", systemImage: "checkmark") {
                Task { await state.complete(reminder) }
            }
        }
    }

    @ViewBuilder
    private var metadata: some View {
        switch context {
        case .day:
            HStack(spacing: 6) {
                Circle().fill(listColor).frame(width: 6, height: 6)
                Text(state.list(for: reminder.listID)?.title ?? "Unknown List")
                if let text = reminder.due?.displayText {
                    Text("·")
                    Text(text)
                        .foregroundStyle(reminder.due?.isBeforeDay(Date()) == true ? .red : .secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .list:
            if let due = reminder.due {
                Text(due.summary)
                    .font(.caption)
                    .foregroundStyle(due.isBeforeDay(Date()) ? .red : .secondary)
            }
        }
    }

    private var listColor: Color {
        Color(hex: state.list(for: reminder.listID)?.colorHex ?? "5E5CE6")
    }

    private var completionColor: Color {
        context == .day ? listColor : .indigo
    }
}
