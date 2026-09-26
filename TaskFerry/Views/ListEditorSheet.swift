import SwiftUI

enum ListEditorContext: Identifiable {
    case create
    case edit(ReminderListRecord)

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let list): "edit:\(list.id)"
        }
    }

    var list: ReminderListRecord? {
        if case .edit(let list) = self { return list }
        return nil
    }
}

struct ListEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let state: AppState
    let context: ListEditorContext

    @State private var title: String
    @State private var colorHex: String
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var confirmingDelete = false
    @FocusState private var titleIsFocused: Bool

    init(state: AppState, context: ListEditorContext) {
        self.state = state
        self.context = context
        _title = State(initialValue: context.list?.title ?? "")
        _colorHex = State(initialValue: context.list?.colorHex.uppercased() ?? TaskFerryPalette.defaultListHex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(hex: colorHex))
                    .accessibilityHidden(true)
                Text(context.list == nil ? "New List" : "List Info")
                    .font(.title2.weight(.semibold))
            }

            if let error = state.errorMessage {
                ErrorBanner(message: error) { state.dismissError() }
            }

            Form {
                TextField("Name:", text: $title)
                    .focused($titleIsFocused)
                    .onSubmit(save)

                LabeledContent("Color:") {
                    HStack(spacing: 6) {
                        ForEach(TaskFerryPalette.listColors, id: \.hex) { option in
                            Button {
                                colorHex = option.hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: option.hex))
                                    .frame(width: 18, height: 18)
                                    .overlay {
                                        if colorHex == option.hex {
                                            Circle().strokeBorder(.primary, lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .help(Text(option.name))
                            .accessibilityLabel(Text(option.name))
                            .accessibilityAddTraits(colorHex == option.hex ? .isSelected : [])
                        }
                    }
                }
            }
            .formStyle(.columns)

            Text("Lists stay in sync with Apple Reminders.")
                .font(.callout)
                .foregroundStyle(.secondary)

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

                Button(isSaving ? "Saving…" : (context.list == nil ? "Create" : "Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || isDeleting || title.trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task { titleIsFocused = true }
        .alert(Text("Delete “\(context.list?.title ?? "")”?"), isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete List", role: .destructive, action: deleteList)
        } message: {
            Text("This also deletes every reminder in the list, including completed reminders. This can’t be undone.")
        }
    }

    private func save() {
        let cleanTitle = title.trimmed
        guard !cleanTitle.isEmpty, !isSaving, !isDeleting else { return }
        isSaving = true
        Task {
            let succeeded: Bool
            if let list = context.list {
                let color = colorHex == list.colorHex.uppercased() ? nil : colorHex
                succeeded = await state.renameList(list, title: cleanTitle, colorHex: color)
            } else {
                succeeded = await state.createList(title: cleanTitle, colorHex: colorHex).succeeded
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
                dismiss()
            } else {
                isDeleting = false
            }
        }
    }
}
