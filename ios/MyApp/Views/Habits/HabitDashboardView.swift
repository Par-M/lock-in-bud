import Charts
import SwiftUI

struct HabitDashboardView: View {
    @Environment(HabitService.self) private var habitService
    @Environment(\.dismiss) private var dismiss

    private var scheduledThisWeek: Int {
        habitService.habits.reduce(0) { $0 + $1.scheduled7d }
    }

    private var completedThisWeek: Int {
        habitService.habits.reduce(0) { $0 + $1.completed7d }
    }

    private var weeklyPercent: Int {
        guard scheduledThisWeek > 0 else { return 0 }
        return Int(((Double(completedThisWeek) / Double(scheduledThisWeek)) * 100).rounded())
    }

    private var onTrackHabits: [HabitStats] {
        habitService.habits.filter { $0.completionRate30d >= 0.75 }
    }

    private var habitsToNurture: [HabitStats] {
        habitService.habits.filter { $0.completionRate30d < 0.75 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(
                        eyebrow: "HABIT DASHBOARD",
                        title: "No perfect pandas here."
                    ) {
                        Button {
                            dismiss()
                        } label: {
                            Image("close-icon-87fddea5")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 22, height: 22)
                                .frame(width: 44, height: 44)
                                .background(
                                    DesignPalette.card,
                                    in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Done")
                    }
                    .padding(.top, 8)

                    if let errorMessage = habitService.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(DesignPalette.body(12))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(
                                Color.orange.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius)
                            )
                    }

                    if habitService.habits.isEmpty {
                        emptyDashboardCard
                    } else {
                        weeklySummaryCard
                        onTrackCard

                        if !onTrackHabits.isEmpty {
                            ForEach(onTrackHabits) { stats in
                                HabitCard(stats: stats)
                            }
                        }

                        roomToGrowSection
                        insightCard
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.bottom, 24)
            }
            .navigationBarHidden(true)
            .refreshable {
                await habitService.loadDashboard()
            }
            .appBackdrop()
        }
        .presentationDetents([.large])
    }

    // MARK: - Weekly summary

    private var weeklySummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("THIS WEEK")
                        .font(DesignPalette.eyebrow())
                        .kerning(1.6)
                        .foregroundStyle(DesignPalette.primary)

                    Text("Day one energy.")
                        .font(DesignPalette.screenTitle(22))
                        .minimumScaleFactor(0.75)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(completedThisWeek) of \(scheduledThisWeek) scheduled")
                        Text("completions done")
                    }
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
                }

                Spacer(minLength: 4)

                ZStack {
                    Image("empty-completion-ring")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 86, height: 86)

                    Text("\(weeklyPercent)%")
                        .font(DesignPalette.screenTitle(21))
                        .foregroundStyle(DesignPalette.primary)
                }
                .frame(width: 86, height: 86)
                .accessibilityLabel("\(weeklyPercent) percent of scheduled completions done")
            }

            Text("Zero is a starting point. Not a personality.")
                .font(DesignPalette.body(11))
                .foregroundStyle(DesignPalette.primary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
    }

    // MARK: - On track

    private var onTrackCard: some View {
        AppCard(padding: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("On track")
                        .font(DesignPalette.body(15))
                        .fontWeight(.bold)
                    Text(
                        onTrackHabits.isEmpty
                            ? "No habits on track yet"
                            : "\(onTrackHabits.count) habit\(onTrackHabits.count == 1 ? "" : "s") on track"
                    )
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
                }

                Spacer(minLength: 4)

                HabitPandaArtwork(
                    size: 60,
                    bodyAsset: "body-fb589004",
                    feetAsset: "feet",
                    earsAsset: "ears-e2fd0773",
                    headAsset: "head-e30b7f64",
                    thumbsUpAsset: "thumbs-up-718f262a",
                    bambooAsset: "bamboo-9fadcca8",
                    holdingPawAsset: "holding-paw-7a173685"
                )
            }
        }
    }

    // MARK: - Room to grow

    private var roomToGrowSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center) {
                Text("Room to grow")
                    .font(DesignPalette.screenTitle(17))
                Spacer(minLength: 8)
                Text("\(habitsToNurture.count) habit\(habitsToNurture.count == 1 ? "" : "s")")
                    .font(DesignPalette.body(10))
                    .fontWeight(.bold)
                    .foregroundStyle(DesignPalette.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(DesignPalette.cream, in: Capsule())
            }

            if habitsToNurture.isEmpty {
                Text("Nothing to fix — great job!")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
            } else {
                ForEach(habitsToNurture) { stats in
                    HabitCard(stats: stats)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Supporting cards

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Missed a day? Don’t make it two.")
                .font(DesignPalette.body(14))
                .fontWeight(.bold)
            Text("Reset. Refocus. Keep the bamboo rolling.")
                .font(DesignPalette.body(11))
                .foregroundStyle(DesignPalette.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
    }

    private var emptyDashboardCard: some View {
        AppCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(DesignPalette.primary)
                Text("No data yet")
                    .font(DesignPalette.screenTitle(20))
                Text("Log a few completions to see your progress.")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(DesignPalette.secondary)
            }
        }
    }
}

private struct HabitCard: View {
    let stats: HabitStats

    private var onTrack: Bool {
        stats.completionRate30d >= 0.75
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.habit.title)
                        .font(DesignPalette.screenTitle(18))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(stats.habit.scheduleLabel) · goal \(stats.habit.dailyGoal)x/day")
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                }

                Spacer(minLength: 4)

                if stats.currentStreak > 0 {
                    Label("\(stats.currentStreak)", systemImage: "flame.fill")
                        .font(DesignPalette.body(11))
                        .fontWeight(.semibold)
                        .foregroundStyle(.orange)
                }

                Image("right-icon-2f4de2af")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 7) {
                ForEach(stats.last7Days, id: \.self) { day in
                    VStack(spacing: 7) {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(DesignPalette.secondary)

                        ZStack {
                            Image("no-completion-recorded")
                                .resizable()
                                .frame(width: 29, height: 29)

                            if day.completedCount >= stats.habit.dailyGoal {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(DesignPalette.primary)
                            } else if day.completedCount > 0 {
                                Text("\(day.completedCount)")
                                    .font(DesignPalette.body(10))
                                    .foregroundStyle(DesignPalette.primary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(
                        "\(day.date.formatted(.dateTime.weekday(.wide))): \(day.completedCount) of \(stats.habit.dailyGoal) check-ins"
                    )
                }
            }
            .frame(maxWidth: .infinity)

            Chart(stats.last7Days, id: \.self) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Done", day.completedCount)
                )
                .foregroundStyle(barColor(day))
                .cornerRadius(3)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3))
            }
            .frame(height: 72)
            .accessibilityLabel("Daily check-ins for \(stats.habit.title)")

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int((stats.completionRate30d * 100).rounded()))%")
                        .font(DesignPalette.screenTitle(24))
                        .foregroundStyle(DesignPalette.primary)
                    Text("30-day rate")
                        .font(DesignPalette.body(10))
                        .foregroundStyle(DesignPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(stats.bestStreak) days")
                        .font(DesignPalette.screenTitle(24))
                        .foregroundStyle(DesignPalette.ink)
                    Text("Best streak")
                        .font(DesignPalette.body(10))
                        .foregroundStyle(DesignPalette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
        .shadow(color: DesignPalette.ink.opacity(0.06), radius: 10, y: 4)
    }

    private func barColor(_ day: HabitDayStats) -> Color {
        guard day.scheduled else { return Color(.systemGray5) }
        if day.completedCount >= stats.habit.dailyGoal {
            return .green
        }
        if day.completedCount > 0 {
            return .orange
        }
        return .red
    }
}
