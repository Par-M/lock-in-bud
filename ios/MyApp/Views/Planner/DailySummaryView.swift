import SwiftUI

struct DailySummaryView: View {
    @Environment(PlannerService.self) private var planner

    var body: some View {
        Group {
            if let summary = planner.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        AppHeader(eyebrow: "PLANNER", title: "Today in review.")

                        summarySection("OVERVIEW") {
                            valueRow("Date", summary.date.formatted(date: .abbreviated, time: .omitted))
                            Divider().background(DesignPalette.cream)
                            valueRow("Hours worked", formattedHours(summary.hoursWorked))
                            Divider().background(DesignPalette.cream)
                            valueRow("Tasks remaining", "\(summary.tasksRemaining)")
                            Divider().background(DesignPalette.cream)
                            valueRow("Tasks rescheduled", "\(summary.tasksMoved)")
                            Divider().background(DesignPalette.cream)
                            valueRow(
                                "Schedule adherence",
                                summary.scheduleAdherence.formatted(.percent.precision(.fractionLength(0)))
                            )
                            ProgressView(value: min(max(summary.scheduleAdherence, 0), 1))
                                .tint(DesignPalette.primary)
                        }

                        if !summary.missedToday.isEmpty {
                            summarySection("MISSED TODAY") {
                                ForEach(summary.missedToday) { miss in
                                    missedRow(miss)
                                }
                            }
                        }

                        AppCard(padding: 14) {
                            NavigationLink {
                                MissedReasonsView()
                            } label: {
                                HStack {
                                    Text("Why did I miss tasks?")
                                        .font(DesignPalette.body(14).weight(.medium))
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

                        if !summary.completed.isEmpty {
                            summarySection("COMPLETED") {
                                ForEach(summary.completed) { task in
                                    summaryRow(task, icon: "checkmark.circle.fill", tint: DesignPalette.primary)
                                }
                            }
                        }

                        if !summary.inProgress.isEmpty {
                            summarySection("IN PROGRESS") {
                                ForEach(summary.inProgress) { task in
                                    summaryRow(task, icon: "clock.fill", tint: DesignPalette.secondary)
                                }
                            }
                        }

                        if !summary.pending.isEmpty {
                            summarySection("PENDING") {
                                ForEach(summary.pending) { task in
                                    summaryRow(task, icon: "circle", tint: DesignPalette.secondary)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DesignPalette.pagePadding)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            } else {
                ContentUnavailableView(
                    "No summary yet",
                    systemImage: "chart.bar",
                    description: Text("Pull to refresh to see today's progress.")
                )
            }
        }
        .appBackdrop()
        .refreshable { await planner.loadSummary() }
        .navigationTitle("Daily Summary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(DesignPalette.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(DesignPalette.primary)
        .task { await planner.loadSummary() }
    }

    @ViewBuilder
    private func summarySection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppEyebrow(text: title)
            AppCard(padding: 14) {
                content()
            }
        }
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(DesignPalette.body(13))
                .foregroundStyle(DesignPalette.mutedInk)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missedRow(_ miss: MissedTaskEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignPalette.body(14))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(miss.taskTitle)
                    .font(DesignPalette.body(14).weight(.medium))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(1)
                if let reason = miss.reason, !reason.isEmpty {
                    Text(reason)
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func summaryRow(_ task: ScheduledTask, icon: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(DesignPalette.body(14))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(DesignPalette.body(14).weight(.medium))
                    .foregroundStyle(DesignPalette.ink)
                    .lineLimit(1)
                if let duration = task.actualDuration ?? task.estimatedDuration {
                    Text("\(duration) min")
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                }
            }
            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private func formattedHours(_ hours: Double) -> String {
        if hours < 0.01 { return "0 min" }
        if hours >= 1 {
            return "\(hours.formatted(.number.precision(.fractionLength(1)))) h"
        }
        return "\(Int((hours * 60).rounded())) min"
    }
}

#Preview {
    NavigationStack {
        DailySummaryView()
            .environment(PlannerService())
    }
}
