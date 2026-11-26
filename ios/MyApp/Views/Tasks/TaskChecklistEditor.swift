import SwiftUI

struct TaskChecklistEditor: View {
    @Binding var items: [ChecklistItem]
    var onSave: () -> Void

    @State private var newItem = ""

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            HStack(spacing: 10) {
                Button {
                    items[index].done.toggle()
                    onSave()
                } label: {
                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(item.done ? DesignPalette.primary : DesignPalette.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.done ? "Mark as not done" : "Mark as done")

                AppTextField(
                    placeholder: "Checklist item",
                    text: Binding(
                        get: { items[index].text },
                        set: { items[index] = ChecklistItem(text: $0, done: items[index].done) }
                    ),
                    font: DesignPalette.body(14),
                    color: item.done ? DesignPalette.secondary : DesignPalette.ink
                )
                .strikethrough(item.done, color: DesignPalette.secondary)
                .onSubmit(onSave)
            }
            .padding(.vertical, 4)
            .swipeActions {
                Button("Delete", role: .destructive) {
                    items.remove(at: index)
                    onSave()
                }
            }
        }

        HStack(spacing: 10) {
            AppTextField(
                placeholder: "Add a checklist item…",
                text: $newItem,
                font: DesignPalette.body(14)
            )
                .submitLabel(.done)
                .onSubmit(commit)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
            Button(action: commit) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(DesignPalette.primary)
            }
            .buttonStyle(.plain)
            .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commit() {
        let trimmed = newItem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChecklistItem(text: trimmed))
        newItem = ""
        onSave()
    }
}
