import SwiftUI

struct SessionCategorySheet: View {
    let categories: [String]
    var logSession: (String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var customCategory = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "FOCUS", title: "Nice work.")

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "WHAT DID YOU COMPLETE?")
                        AppCard(padding: 14) {
                            Button {
                                log(nil)
                            } label: {
                                HStack {
                                    Label("Skip for now", systemImage: "minus.circle")
                                        .font(DesignPalette.body(14))
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(DesignPalette.secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !categories.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            AppEyebrow(text: "CATEGORIES")
                            AppCard(padding: 12) {
                                ForEach(categories, id: \.self) { category in
                                    Button {
                                        log(category)
                                    } label: {
                                        HStack {
                                            Text(category)
                                                .font(DesignPalette.body(14))
                                                .foregroundStyle(DesignPalette.ink)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(DesignPalette.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        AppEyebrow(text: "OR ADD A NEW CATEGORY")
                        AppCard(padding: 14) {
                            HStack(spacing: 10) {
                                AppTextField(
                                    placeholder: "Add another category",
                                    text: $customCategory,
                                    font: DesignPalette.body(14)
                                )
                                    .submitLabel(.done)
                                    .onSubmit { log(customCategory) }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .background(DesignPalette.background, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))
                                if !customCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Button {
                                        log(customCategory)
                                    } label: {
                                        Image(systemName: "plus.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(DesignPalette.primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Log focus session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        log(nil)
                    }
                }
            }
            .disabled(isSaving)
        }
        .presentationDetents([.medium])
    }

    private func log(_ category: String?) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await logSession(category)
            dismiss()
        }
    }
}

#Preview {
    SessionCategorySheet(categories: ["Work", "Study", "Home"]) { _ in }
}
