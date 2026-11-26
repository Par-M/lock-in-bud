import SwiftUI

struct MissedReasonsView: View {
    @Environment(PlannerService.self) private var planner

    var body: some View {
        Group {
            if let response = planner.missedReasons {
                if response.byCategory.isEmpty {
                    ContentUnavailableView(
                        "No missed tasks",
                        systemImage: "checkmark.circle",
                        description: Text("Nothing missed so far. Great work!")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            ForEach(response.byCategory) { category in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        AppEyebrow(text: category.category)
                                        Spacer()
                                        Text("\(category.count)")
                                            .font(DesignPalette.body(12).weight(.semibold))
                                            .foregroundStyle(DesignPalette.primary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(DesignPalette.sage, in: Capsule())
                                    }
                                    AppCard(padding: 14) {
                                        ForEach(category.reasons) { miss in
                                            reasonRow(miss)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, DesignPalette.pagePadding)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
            } else if planner.isLoading {
                ProgressView("Loading…")
                    .tint(DesignPalette.primary)
            } else {
                ContentUnavailableView(
                    "No data",
                    systemImage: "chart.bar",
                    description: Text("Pull to refresh to load your missed-task history.")
                )
            }
        }
        .appBackdrop()
        .refreshable { await planner.loadMissedReasons() }
        .navigationTitle("Why Did I Miss Tasks?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DesignPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(DesignPalette.primary)
        .task { await planner.loadMissedReasons() }
    }

    private func reasonRow(_ miss: MissedTaskEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(miss.taskTitle)
                .font(DesignPalette.body(14).weight(.medium))
                .foregroundStyle(DesignPalette.ink)
            if let reason = miss.reason, !reason.isEmpty {
                Text(reason)
                    .font(DesignPalette.body(13))
                    .foregroundStyle(DesignPalette.secondary)
            }
            HStack(spacing: 12) {
                if let missed = miss.missedDeadline {
                    Label(
                        missed.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "calendar.badge.exclamationmark"
                    )
                }
                if let minutes = miss.minutesRemaining {
                    Label("\(minutes) min left", systemImage: "timer")
                }
                if let rescheduledTo = miss.rescheduledTo {
                    Label(
                        "Moved to \(rescheduledTo.formatted(date: .omitted, time: .shortened))",
                        systemImage: "arrow.right"
                    )
                }
            }
            .font(DesignPalette.body(11))
            .foregroundStyle(DesignPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

#Preview {
    NavigationStack {
        MissedReasonsView()
            .environment(PlannerService())
    }
}
