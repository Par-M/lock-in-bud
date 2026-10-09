import SwiftUI

struct FocusSessionEditSheet: View {
    @Environment(FocusService.self) private var focus
    @Environment(\.dismiss) private var dismiss

    let session: FocusSession

    @State private var startDate: Date
    @State private var endDate: Date
    @State private var isSaving = false
    @State private var saveError: String?

    init(session: FocusSession) {
        self.session = session
        _startDate = State(initialValue: session.startedAt)
        _endDate = State(initialValue: session.endedAt)
    }

    private var isValid: Bool {
        endDate > startDate
    }

    var body: some View {
        NavigationStack {
            Form {
                if let saveError {
                    Text(saveError).foregroundStyle(.red)
                }
                Section("When did it happen?") {
                    DatePicker("Started", selection: $startDate)
                    DatePicker("Ended", selection: $endDate)
                }

                if !isValid {
                    Section {
                        Label("End time must be after start time.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Edit focus session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(!isValid || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        saveError = nil
        if await focus.updateSession(id: session.id, startedAt: startDate, endedAt: endDate) != nil {
            dismiss()
        } else {
            saveError = focus.errorMessage
        }
    }
}
