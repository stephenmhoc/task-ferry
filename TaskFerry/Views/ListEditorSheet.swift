import SwiftUI

enum ListEditorContext: Identifiable {
    case create
    case edit(ReminderListRecord)

    var id: String {
        switch self {
        case .create:
            "create"
        case .edit(let list):
            "edit:\(list.id)"
        }
    }

    var list: ReminderListRecord? {
        if case .edit(let list) = self { return list }
        return nil
    }
}

struct ListEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    let context: ListEditorContext
    let onDeleted: (ReminderListRecord) -> Void

    @State private var title: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @FocusState private var titleIsFocused: Bool

    init(
        state: AppState,
        context: ListEditorContext,
        onDeleted: @escaping (ReminderListRecord) -> Void
    ) {
        self.state = state
        self.context = context
        self.onDeleted = onDeleted
        _title = State(initialValue: context.list?.title ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: context.list == nil ? "plus" : "square.grid.2x2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 40, height: 40)
                    .background(accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.list == nil ? "New List" : "Edit List")
                        .font(.title2.weight(.semibold))
                    Text("Lists stay in sync with Apple Reminders.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NAME")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("List name", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($titleIsFocused)
                    .onSubmit(save)
            }

            Divider()

            HStack {
                if context.list != nil {
                    Button("Delete List…", role: .destructive) {
                        confirmingDelete = true
                    }
                    .disabled(isSaving || isDeleting)
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving || isDeleting)

                Button(isSaving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isDeleting || title.trimmed.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
        .task { titleIsFocused = true }
        .alert("Delete “\(context.list?.title ?? "this list")”?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: deleteList)
        } message: {
            Text("This also deletes every reminder in the list, including completed reminders. This can’t be undone.")
        }
    }

    private var accentColor: Color {
        Color(hex: context.list?.colorHex ?? "0A69D8")
    }

    private func save() {
        let cleanTitle = title.trimmed
        guard !cleanTitle.isEmpty, !isSaving, !isDeleting else { return }
        isSaving = true
        Task {
            let succeeded: Bool
            if let list = context.list {
                succeeded = await state.renameList(list, title: cleanTitle)
            } else {
                succeeded = await state.createList(title: cleanTitle)
            }

            if succeeded {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }

    private func deleteList() {
        guard let list = context.list, !isDeleting, !isSaving else { return }
        isDeleting = true
        Task {
            if await state.deleteList(list) {
                onDeleted(list)
                dismiss()
            } else {
                isDeleting = false
            }
        }
    }
}
