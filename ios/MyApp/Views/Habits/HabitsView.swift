import SwiftUI
import UIKit

struct HabitsView: View {
    @Environment(HabitService.self) private var habitService
    @Environment(TaskService.self) private var taskService

    @State private var isAdding = false
    @State private var editingHabit: Habit?
    @State private var showingDashboard = false
    @State private var habitPendingDelete: Habit?
    @State private var isReordering = false

    private var weeklyScheduled: Int {
        habitService.habits.reduce(0) { $0 + $1.scheduled7d }
    }

    private var weeklyCompleted: Int {
        habitService.habits.reduce(0) { $0 + $1.completed7d }
    }

    private var weeklyProgress: Double {
        guard weeklyScheduled > 0 else { return 0 }
        return min(1, max(0, Double(weeklyCompleted) / Double(weeklyScheduled)))
    }

    var body: some View {
        NavigationStack {
            List {
                headerRow

                if habitService.habits.isEmpty && !habitService.isLoading {
                    emptyHabitsSection
                } else {
                    if let errorMessage = habitService.errorMessage {
                        errorRow(errorMessage)
                    }

                    encouragementRow
                    weekProgressRow
                    habitHeadingRow

                    ForEach(habitService.habits) { stats in
                        habitRow(stats)
                    }
                    .onMove { from, to in
                        var ids = habitService.habits.map(\.id)
                        ids.move(fromOffsets: from, toOffset: to)
                        Task { await habitService.reorderHabits(ids) }
                    }

                    addHabitRow

                    insightCard(
                        title: "Consistency > beast mode.",
                        caption: "Even pandas put in the reps. Then they nap."
                    )
                    .modifier(HabitRowSpacing(bottom: 24))
                }
            }
            .listStyle(.plain)
            .listRowSpacing(0)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(isReordering ? .active : .inactive))
            .refreshable {
                await habitService.loadDashboard()
            }
            .navigationBarHidden(true)
            .appBackdrop()
            .overlay {
                if habitService.isLoading && habitService.habits.isEmpty {
                    ProgressView()
                }
            }
            .task {
                await habitService.loadDashboard()
            }
            .onChange(of: taskService.dataVersion) { _, _ in
                Task { await habitService.loadDashboard() }
            }
        }
        .confirmationDialog(
            habitPendingDelete == nil ? "" : "Delete \(habitPendingDelete!.title)?",
            isPresented: Binding(
                get: { habitPendingDelete != nil },
                set: { if !$0 { habitPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let habit = habitPendingDelete {
                    Task { await habitService.deleteHabit(id: habit.id) }
                }
                habitPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                habitPendingDelete = nil
            }
        } message: {
            Text("This removes the habit and its history. This cannot be undone.")
        }
        .sheet(isPresented: $isAdding) {
            HabitFormView(mode: .add) { _ in
                isAdding = false
            }
        }
        .sheet(item: $editingHabit) { habit in
            HabitFormView(mode: .edit(habit))
        }
        .sheet(isPresented: $showingDashboard) {
            HabitDashboardView()
        }
    }

    private func log(_ stats: HabitStats) async {
        if stats.isDoneToday {
            await habitService.setHabitDayCount(id: stats.habit.id, count: 0)
        } else {
            await habitService.logHabit(id: stats.habit.id, count: 1)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: - Header

    private var headerRow: some View {
        AppHeader(
            eyebrow: "HABITS",
            title: habitService.habits.isEmpty
                ? "Start your panda era."
                : "Stay steady.\nStay a little wild."
        ) {
            if habitService.habits.isEmpty {
                headerIconButton(
                    "plus-icon",
                    label: "Add Habit",
                    identifier: "addHabitButton"
                ) {
                    isAdding = true
                }
            } else {
                headerIconButton(
                    "chart-icon-7119a2e9",
                    label: "Dashboard",
                    identifier: "habitDashboardButton"
                ) {
                    showingDashboard = true
                }
                .disabled(habitService.habits.isEmpty)
            }
        }
        .padding(.vertical, 8)
        .modifier(HabitRowSpacing(bottom: 14))
    }

    private func headerIconButton(
        _ asset: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(asset)
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
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func errorRow(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(DesignPalette.body(12))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
            .modifier(HabitRowSpacing(bottom: 12))
    }

    // MARK: - Populated state

    private var encouragementRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Built one day at a time.")
                    .font(DesignPalette.screenTitle(23))
                    .minimumScaleFactor(0.75)
                Text("Small reps. Real momentum.")
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
            }
            Spacer(minLength: 4)
            HabitPandaArtwork(
                size: 102,
                bodyAsset: "body-779db733",
                feetAsset: "feet-45c72b77",
                earsAsset: "ears",
                headAsset: "head-5be767d1",
                thumbsUpAsset: "thumbs-up-c461b94e",
                bambooAsset: "bamboo-db385a2e",
                holdingPawAsset: "holding-paw-33372343"
            )
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
        .modifier(HabitRowSpacing(bottom: 20))
    }

    private var weekProgressRow: some View {
        AppCard(padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Text("This week")
                        .font(DesignPalette.body(14))
                        .fontWeight(.bold)
                    Spacer(minLength: 8)
                    Text("\(weeklyCompleted) of \(weeklyScheduled) done")
                        .font(DesignPalette.body(10))
                        .fontWeight(.bold)
                        .foregroundStyle(DesignPalette.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DesignPalette.sage, in: Capsule())
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        DesignPalette.sage
                        DesignPalette.primary
                            .frame(width: proxy.size.width * CGFloat(weeklyProgress))
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())

                Text("First check-in. No heroic montage required.")
                    .font(DesignPalette.body(11))
                    .foregroundStyle(DesignPalette.secondary)
            }
        }
        .modifier(HabitRowSpacing(bottom: 20))
    }

    private var habitHeadingRow: some View {
        HStack {
            Text("Your habits")
                .font(DesignPalette.screenTitle(17))
            Spacer(minLength: 8)
            Button {
                withAnimation {
                    isReordering.toggle()
                }
            } label: {
                Image("sort-icon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .frame(width: 44, height: 44)
                    .background(
                        isReordering ? DesignPalette.sage : DesignPalette.card,
                        in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isReordering ? "Done reordering" : "Reorder habits")
            .accessibilityIdentifier("reorderHabitsButton")
        }
        .modifier(HabitRowSpacing(bottom: 12))
    }

    private func habitRow(_ stats: HabitStats) -> some View {
        HabitRow(stats: stats) {
            await log(stats)
        }
        .onTapGesture {
            editingHabit = stats.habit
        }
        .accessibilityHint("Double tap to edit")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                habitPendingDelete = stats.habit
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingHabit = stats.habit
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .modifier(HabitRowSpacing(bottom: 12))
    }

    private var addHabitRow: some View {
        Button {
            isAdding = true
        } label: {
            HStack(spacing: 9) {
                Image("plus-icon-e3161e51")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text("Add a habit")
            }
        }
        .buttonStyle(AppPrimaryButtonStyle())
        .accessibilityIdentifier("addHabitButton")
        .modifier(HabitRowSpacing(bottom: 20))
    }

    // MARK: - Empty state

    private var emptyHabitsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 12) {
                HabitPandaArtwork(
                    size: 168,
                    bodyAsset: "body-8fd0910d",
                    feetAsset: "feet-7e95c224",
                    earsAsset: "ears-af87fdd3",
                    headAsset: "head",
                    thumbsUpAsset: "thumbs-up",
                    bambooAsset: "bamboo-bdab27ef",
                    holdingPawAsset: "holding-paw-e08be005"
                )

                Text("No habits. Yet.")
                    .font(DesignPalette.screenTitle(23))
                    .multilineTextAlignment(.center)

                Text("Start one habit. Your future self says thanks.")
                    .font(DesignPalette.body(13))
                    .foregroundStyle(DesignPalette.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    isAdding = true
                } label: {
                    HStack(spacing: 9) {
                        Image("plus-icon-1-bc007e5e")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 18, height: 18)
                        Text("Build your first habit")
                    }
                }
                .buttonStyle(AppPrimaryButtonStyle())
            }
            .padding(EdgeInsets(top: 30, leading: 24, bottom: 26, trailing: 24))
            .frame(maxWidth: .infinity)
            .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))

            VStack(alignment: .leading, spacing: 12) {
                Text("Pick your first small win.")
                    .font(DesignPalette.body(14))
                    .fontWeight(.bold)

                ViewThatFits {
                    HStack(spacing: 7) {
                        inspirationChip("Drink water")
                        inspirationChip("Read a page")
                        inspirationChip("Take a walk")
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        inspirationChip("Drink water")
                        inspirationChip("Read a page")
                        inspirationChip("Take a walk")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            insightCard(
                title: "Go small. Get consistent.",
                caption: "World domination can wait. Drink some water."
            )
        }
        .modifier(HabitRowSpacing(bottom: 24))
    }

    private func inspirationChip(_ title: String) -> some View {
        Text(title)
            .font(DesignPalette.body(10))
            .fontWeight(.bold)
            .foregroundStyle(DesignPalette.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DesignPalette.card, in: Capsule())
            .accessibilityLabel(title)
    }

    private func insightCard(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(DesignPalette.body(14))
                .fontWeight(.bold)
            Text(caption)
                .font(DesignPalette.body(11))
                .foregroundStyle(DesignPalette.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
    }
}

/// Layered panda artwork. Each screen supplies its own asset names so the
/// illustrations are never shared between frames.
struct HabitPandaArtwork: View {
    let size: CGFloat
    let bodyAsset: String
    let feetAsset: String
    let earsAsset: String
    let headAsset: String
    let thumbsUpAsset: String
    let bambooAsset: String
    let holdingPawAsset: String

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let insetX = width * 0.0875
            let insetY = height * 0.0933
            let artWidth = width * 0.8333
            let artHeight = height * 0.815

            ZStack {
                Color.clear

                layer(
                    bodyAsset,
                    x: insetX + artWidth * 0.2247,
                    y: insetY + artHeight * 0.4462,
                    width: artWidth * 0.5651,
                    height: artHeight * 0.4548
                )
                layer(
                    feetAsset,
                    x: insetX + artWidth * 0.1755,
                    y: insetY + artHeight * 0.7432,
                    width: artWidth * 0.6365,
                    height: artHeight * 0.1651
                )
                layer(
                    earsAsset,
                    x: insetX + artWidth * 0.2234,
                    y: insetY + artHeight * 0.0933,
                    width: artWidth * 0.5624,
                    height: artHeight * 0.1525
                )
                layer(
                    headAsset,
                    x: insetX + artWidth * 0.2097,
                    y: insetY + artHeight * 0.1040,
                    width: artWidth * 0.5775,
                    height: artHeight * 0.4882
                )
                layer(
                    thumbsUpAsset,
                    x: insetX + artWidth * 0.0875,
                    y: insetY + artHeight * 0.4076,
                    width: artWidth * 0.2340,
                    height: artHeight * 0.2724
                )
                layer(
                    bambooAsset,
                    x: insetX + artWidth * 0.6505,
                    y: insetY + artHeight * 0.3917,
                    width: artWidth * 0.2703,
                    height: artHeight * 0.4402
                )
                layer(
                    holdingPawAsset,
                    x: insetX + artWidth * 0.1584,
                    y: insetY + artHeight * 0.5575,
                    width: artWidth * 0.1636,
                    height: artHeight * 0.1467
                )
            }
            .frame(width: width, height: height)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layer(
        _ asset: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Image(asset)
            .resizable()
            .frame(width: width, height: height)
            .position(x: x + width / 2, y: y + height / 2)
    }
}

private struct HabitRowSpacing: ViewModifier {
    var bottom: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .listRowInsets(
                EdgeInsets(
                    top: 0,
                    leading: DesignPalette.pagePadding,
                    bottom: bottom,
                    trailing: DesignPalette.pagePadding
                )
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private struct HabitRow: View {
    @Environment(HabitService.self) private var habitService

    let stats: HabitStats
    let onLog: () async -> Void

    @State private var dragValue: Double?

    private var goal: Int { stats.habit.dailyGoal }
    private var completedCount: Int { stats.today?.completedCount ?? 0 }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { dragValue ?? Double(completedCount) },
            set: { dragValue = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                if goal > 1 {
                    Text("\(completedCount)/\(goal)")
                        .font(DesignPalette.body(10))
                        .fontWeight(.bold)
                        .foregroundStyle(DesignPalette.primary)
                        .frame(width: 28, height: 28)
                        .background(DesignPalette.sage, in: Circle())
                } else {
                    Button {
                        Task { await onLog() }
                    } label: {
                        Image("mark-test-complete")
                            .resizable()
                            .frame(width: 28, height: 28)
                            .overlay {
                                if stats.isDoneToday {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(DesignPalette.primary)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        stats.isDoneToday
                            ? "Mark \(stats.habit.title) not done today"
                            : "Check in \(stats.habit.title)"
                    )
                    .accessibilityIdentifier("logHabitButton")
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(stats.habit.title)
                        .font(DesignPalette.screenTitle(17))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(stats.habit.scheduleLabel) · goal \(goal)x")
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

                Image("right-icon-33b985d4")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 17, height: 17)
                    .accessibilityHidden(true)
            }

            HStack {
                Text("One check-in. That’s your move.")
                    .font(DesignPalette.body(10))
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignPalette.primary)
                Spacer(minLength: 4)
            }
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: DesignPalette.compactRadius))

            if goal > 1 {
                HStack(spacing: 10) {
                    Slider(value: sliderValue, in: 0...Double(goal), step: 1) { editing in
                        if !editing {
                            let value = Int(sliderValue.wrappedValue.rounded())
                            dragValue = nil
                            Task { await commit(value) }
                        }
                    }
                    .tint(DesignPalette.primary)
                    .accessibilityLabel("\(stats.habit.title) check-ins")
                    .accessibilityIdentifier("habitCountSlider")

                    Text("\(Int(sliderValue.wrappedValue.rounded()))/\(goal)")
                        .font(DesignPalette.body(11))
                        .monospacedDigit()
                        .foregroundStyle(DesignPalette.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
        .shadow(color: DesignPalette.ink.opacity(0.06), radius: 10, y: 4)
        .contentShape(Rectangle())
    }

    private func commit(_ value: Int) async {
        await habitService.setHabitDayCount(id: stats.habit.id, count: value)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
