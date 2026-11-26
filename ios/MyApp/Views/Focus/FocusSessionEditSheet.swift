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
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "FOCUS", title: "Edit session.")

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "WHEN DID IT HAPPEN?")
                        AppCard(padding: 14) {
                            DatePicker("Started", selection: $startDate)
                                .font(DesignPalette.body(14))
                                .tint(DesignPalette.primary)
                            Divider().background(DesignPalette.cream)
                            DatePicker("Ended", selection: $endDate)
                                .font(DesignPalette.body(14))
                                .tint(DesignPalette.primary)
                        }
                    }

                    if !isValid {
                        AppCard(padding: 14) {
                            Label("End time must be after start time.", systemImage: "exclamationmark.triangle")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let saveError {
                        AppCard(padding: 14) {
                            Text(saveError)
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Edit focus session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
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
