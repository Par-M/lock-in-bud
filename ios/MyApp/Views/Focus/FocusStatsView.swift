import SwiftUI

/// Frame-level colors for the Focus stats sheet (category swatches and tracks).
private enum FocusStatsPalette {
    static let track = Color(red: 228 / 255, green: 231 / 255, blue: 220 / 255)
    static let progressTrack = Color(red: 237 / 255, green: 241 / 255, blue: 230 / 255)

    private static let swatchNames: [String: String] = [
        "elec 221": "elec-221-color",
        "elec 226": "elec-226-color",
        "elec 271": "elec-271-color",
        "elec 231": "elec-231-color",
        "law 204": "law-204-color",
        "elec 290": "elec-290-color",
        "health & well being": "health-well-being-color",
        "technical projects": "technical-projects-color",
        "qec": "qec-color"
    ]

    private static let categoryColors: [String: Color] = [
        "elec 221": Color(red: 147 / 255, green: 185 / 255, blue: 103 / 255),
        "elec 226": Color(red: 73 / 255, green: 113 / 255, blue: 71 / 255),
        "elec 271": Color(red: 107 / 255, green: 130 / 255, blue: 100 / 255),
        "elec 231": Color(red: 185 / 255, green: 141 / 255, blue: 72 / 255),
        "law 204": Color(red: 105 / 255, green: 143 / 255, blue: 138 / 255),
        "elec 290": Color(red: 125 / 255, green: 135 / 255, blue: 96 / 255),
        "health & well being": Color(red: 101 / 255, green: 147 / 255, blue: 134 / 255),
        "technical projects": Color(red: 163 / 255, green: 152 / 255, blue: 101 / 255),
        "qec": Color(red: 113 / 255, green: 130 / 255, blue: 139 / 255)
    ]

    private static func key(_ category: String) -> String {
        category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func swatchName(for category: String) -> String? {
        swatchNames[key(category)]
    }

    static func color(for category: String) -> Color {
        categoryColors[key(category)] ?? FocusChartColors.color(for: category)
    }
}

private struct FocusStatsRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(
                EdgeInsets(
                    top: 4,
                    leading: DesignPalette.pagePadding,
                    bottom: 4,
                    trailing: DesignPalette.pagePadding
                )
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

private extension View {
    func focusStatsRow() -> some View {
        modifier(FocusStatsRow())
    }
}

struct FocusStatsView: View {
    @Environment(FocusService.self) private var focus
    @Environment(\.dismiss) private var dismiss

    private enum Granularity: String, CaseIterable, Identifiable {
        case oneDay = "1 Day"
        case threeDays = "3 Days"
        case week = "1 Week"
        case twoWeeks = "2 Weeks"
        case fourWeeks = "4 Weeks"
        var id: String { rawValue }
    }

    @State private var granularity: Granularity = .fourWeeks
    @State private var editingSession: FocusSession?
    @State private var selectedCategory: String?

    private var sessions: [FocusSession] { focus.dailySessions }

    private var sorted: [FocusSession] {
        sessions.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        NavigationStack {
            List {
                if sessions.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No focus sessions yet",
                            systemImage: "timer",
                            description: Text("Start a focus session and it will show up here.")
                        )
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        encouragementCard
                            .focusStatsRow()
                    }

                    Section {
                        categorySpreadHeading
                            .focusStatsRow()
                    }

                    Section {
                        radarCard
                            .id(granularity)
                            .focusStatsRow()
                    }

                    Section {
                        categoryBreakdownCard
                            .focusStatsRow()
                    }

                    Section {
                        sessionsPerCategoryCard
                            .focusStatsRow()
                    }

                    Section {
                        insightCard
                            .focusStatsRow()
                    }

                    Section {
                        footerNote
                            .focusStatsRow()
                    }

                    Section {
                        if selectedCategory != nil {
                            Button {
                                withAnimation(.snappy(duration: 0.25)) {
                                    selectedCategory = nil
                                }
                            } label: {
                                Label("Show all sessions", systemImage: "xmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(DesignPalette.primary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(DesignPalette.sage, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(filteredSessions) { session in
                            Button {
                                editingSession = session
                            } label: {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(FocusStatsPalette.color(for: session.category ?? "Uncategorized"))
                                        .frame(width: 10, height: 10)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(Self.sessionFormatter.string(from: session.startedAt))
                                            .font(DesignPalette.body(13).weight(.medium))
                                            .foregroundStyle(DesignPalette.ink)
                                        Text(timeRange(for: session))
                                            .font(DesignPalette.body(11))
                                            .foregroundStyle(DesignPalette.secondary)
                                    }
                                    Spacer()
                                    Text("\(session.durationSeconds / 60) min")
                                        .font(DesignPalette.body(13).weight(.medium))
                                        .foregroundStyle(DesignPalette.secondary)
                                        .frame(minWidth: 56, alignment: .trailing)
                                }
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 15))
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(
                                EdgeInsets(
                                    top: 4,
                                    leading: DesignPalette.pagePadding,
                                    bottom: 4,
                                    trailing: DesignPalette.pagePadding
                                )
                            )
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("focusSessionRow")
                        }
                        .onDelete(perform: deleteSessions)
                    } header: {
                        Text(sessionSectionTitle)
                            .font(DesignPalette.sectionTitle(15))
                            .foregroundStyle(DesignPalette.ink)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(DesignPalette.background)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 20) {
                    header
                    if !sessions.isEmpty {
                        rangePicker
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .background(DesignPalette.background)
            }
            .navigationTitle("Focus stats")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .sheet(item: $editingSession) { session in
                FocusSessionEditSheet(session: session)
            }
        }
        .presentationDetents([.large])
        .appBackdrop()
    }

    private var header: some View {
        AppHeader(eyebrow: "FOCUS STATS", title: "Proof you showed up.") {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 0) {
                    Image("close-icon-f8ad2de4")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .foregroundStyle(DesignPalette.primary)
                    Text("Done")
                        .frame(width: 0, height: 0)
                        .opacity(0)
                }
                .frame(width: 44, height: 44)
                .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done")
            .accessibilityIdentifier("doneFocusStatsButton")
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 3) {
            ForEach(Granularity.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.35)) {
                        granularity = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(DesignPalette.body(9).weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(granularity == option ? .white : DesignPalette.secondary)
                .background(
                    granularity == option ? DesignPalette.primary : Color.clear,
                    in: RoundedRectangle(cornerRadius: 11)
                )
                .accessibilityLabel("\(option.rawValue) range")
                .accessibilityAddTraits(granularity == option ? .isSelected : [])
            }
        }
        .padding(4)
        .background(FocusStatsPalette.track, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("focusStatsGranularityPicker")
    }

    // MARK: - Encouragement

    private var encouragementCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("That’s solid work.")
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .foregroundStyle(DesignPalette.ink)
                        .minimumScaleFactor(0.8)
                    Text("Not bad for a species known for naps.")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FocusStatsPanda()
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(sessionHighlight?.count ?? 0)")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(DesignPalette.primary)
                        .minimumScaleFactor(0.7)
                    Text("\(sessionHighlight?.category ?? "No category") sessions")
                        .font(DesignPalette.body(10).weight(.semibold))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 4) {
                    Text("\(formattedMinutes(timeHighlight?.minutes ?? 0)) min")
                        .font(.system(size: 25, weight: .heavy, design: .rounded))
                        .foregroundStyle(DesignPalette.ink)
                        .minimumScaleFactor(0.7)
                    Text("\(timeHighlight?.category ?? "No category") focus time")
                        .font(DesignPalette.body(10).weight(.semibold))
                        .foregroundStyle(DesignPalette.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 7)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.sage, in: RoundedRectangle(cornerRadius: 20))
    }

    private var sessionHighlight: CategoryTotal? {
        perCategoryTotals.max { $0.count < $1.count }
    }

    private var timeHighlight: CategoryTotal? {
        perCategoryTotals.first
    }

    private func formattedMinutes(_ minutes: Int) -> String {
        minutes.formatted(.number)
    }

    private var categorySpreadHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Category spread")
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundStyle(DesignPalette.ink)
            Text("A clearer picture of where your focus went.")
                .font(DesignPalette.body(11))
                .foregroundStyle(DesignPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var insightCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Slow is fine. Keep moving.")
                .font(DesignPalette.body(14).weight(.bold))
                .foregroundStyle(DesignPalette.ink)
            Text("Focused minutes. Earned bamboo breaks.")
                .font(DesignPalette.body(11))
                .foregroundStyle(DesignPalette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(DesignPalette.cream, in: RoundedRectangle(cornerRadius: 20))
    }

    private var footerNote: some View {
        Text("Less scrolling. More bamboo.")
            .font(DesignPalette.body(10))
            .foregroundStyle(DesignPalette.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 4)
    }

    private var filteredSessions: [FocusSession] {
        guard let selectedCategory else { return sorted }
        return sorted.filter {
            ($0.category ?? "Uncategorized") == selectedCategory
        }
    }

    private var sessionSectionTitle: String {
        guard let selectedCategory else { return "All sessions" }
        return "\(selectedCategory) sessions"
    }

    private func deleteSessions(at offsets: IndexSet) {
        let toDelete = offsets.map { filteredSessions[$0] }
        Task {
            for session in toDelete {
                await delete(session)
            }
        }
    }

    @discardableResult
    private func delete(_ session: FocusSession) async -> Bool {
        await focus.deleteSession(id: session.id)
    }

    private static let sessionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private func timeRange(for session: FocusSession) -> String {
        "\(Self.timeOnlyFormatter.string(from: session.startedAt)) – \(Self.timeOnlyFormatter.string(from: session.endedAt))"
    }

    // MARK: - Radar card

    private var radarCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Time per category")
                    .font(DesignPalette.body(14).weight(.bold))
                    .foregroundStyle(FocusChartColors.primaryText)
                Spacer()
                Text(windowLabel)
                    .font(DesignPalette.body(10))
                    .foregroundStyle(FocusChartColors.secondaryText)
            }

            FocusRadarChart(
                entries: radarEntries,
                selectedCategory: selectedCategory
            ) { category in
                withAnimation(.snappy(duration: 0.25)) {
                    selectedCategory = category
                }
            }

            if let selectedCategory,
               let total = radarTotals[selectedCategory] {
                radarSelectionDetail(category: selectedCategory, minutes: total)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FocusChartColors.chartBackground, in: RoundedRectangle(cornerRadius: 20))
        .animation(.snappy(duration: 0.25), value: selectedCategory)
    }

    private func radarSelectionDetail(category: String, minutes: Int) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(FocusChartColors.color(for: category))
                .frame(width: 12, height: 12)
            Text(category)
                .font(DesignPalette.body(13).weight(.semibold))
                .foregroundStyle(FocusChartColors.primaryText)
                .lineLimit(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(minutes) min")
                    .font(DesignPalette.body(13).weight(.bold))
                    .foregroundStyle(FocusChartColors.primaryText)
                    .monospacedDigit()
                Text(windowLabel)
                    .font(DesignPalette.body(10))
                    .foregroundStyle(FocusChartColors.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(
            FocusChartColors.color(for: category).opacity(0.18),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    // MARK: - Category rows and sessions per category

    @ViewBuilder
    private func categorySwatch(_ category: String) -> some View {
        if let name = FocusStatsPalette.swatchName(for: category) {
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: 7, height: 7)
        } else {
            Circle()
                .fill(FocusStatsPalette.color(for: category))
                .frame(width: 7, height: 7)
        }
    }

    private var maxCategoryMinutes: Int {
        max(1, perCategoryTotals.first?.minutes ?? 1)
    }

    private var categoryBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(perCategoryTotals) { total in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedCategory = selectedCategory == total.category ? nil : total.category
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            categorySwatch(total.category)
                            Text(total.category)
                                .font(DesignPalette.body(12).weight(.bold))
                                .foregroundStyle(DesignPalette.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text("\(total.minutes) min")
                                .font(DesignPalette.body(11).weight(.bold))
                                .foregroundStyle(DesignPalette.ink)
                                .monospacedDigit()
                        }

                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(FocusStatsPalette.progressTrack)
                                Capsule()
                                    .fill(FocusStatsPalette.color(for: total.category))
                                    .frame(
                                        width: max(
                                            6,
                                            proxy.size.width * CGFloat(total.minutes) / CGFloat(maxCategoryMinutes)
                                        )
                                    )
                            }
                        }
                        .frame(height: 6)

                        Text("\(total.count) session\(total.count == 1 ? "" : "s")")
                            .font(DesignPalette.body(10))
                            .foregroundStyle(DesignPalette.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Show \(total.category) sessions")
                .accessibilityAddTraits(selectedCategory == total.category ? .isSelected : [])
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var sessionsPerCategoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions per category")
                .font(DesignPalette.sectionTitle(15))
            ForEach(perCategoryTotals, id: \.category) { total in
                HStack(spacing: 8) {
                    categorySwatch(total.category)
                    Text(total.category)
                        .font(DesignPalette.body(12).weight(.medium))
                        .foregroundStyle(DesignPalette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(total.count) session\(total.count == 1 ? "" : "s")")
                        .font(DesignPalette.body(11))
                        .foregroundStyle(DesignPalette.secondary)
                    Text("\(total.minutes) min")
                        .font(DesignPalette.body(11).weight(.semibold))
                        .foregroundStyle(DesignPalette.secondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Data

    private var usesDailyBuckets: Bool {
        switch granularity {
        case .oneDay, .threeDays, .week: true
        case .twoWeeks, .fourWeeks: false
        }
    }

    private var dayCount: Int {
        switch granularity {
        case .oneDay: 1
        case .threeDays: 3
        case .week: 7
        default: 0
        }
    }

    private var weekCount: Int {
        switch granularity {
        case .twoWeeks: 2
        case .fourWeeks: 4
        default: 0
        }
    }

    private struct CategoryTotal: Identifiable {
        let id = UUID()
        let category: String
        let count: Int
        let minutes: Int
    }

    private var perCategoryTotals: [CategoryTotal] {
        let grouped = Dictionary(grouping: sessions, by: { $0.category ?? "Uncategorized" })
        return grouped
            .map { group in
                CategoryTotal(
                    category: group.key,
                    count: group.value.count,
                    minutes: group.value.reduce(0) { $0 + $1.durationSeconds } / 60
                )
            }
            .sorted { $0.minutes > $1.minutes }
    }

    // MARK: - Radar data

    private var windowStart: Date {
        let calendar = Calendar.current
        let now = Date()
        if usesDailyBuckets {
            return calendar.date(
                byAdding: .day,
                value: -(dayCount - 1),
                to: calendar.startOfDay(for: now)
            ) ?? calendar.startOfDay(for: now)
        }
        let weekCount = self.weekCount
        guard weekCount > 0,
              let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
        else { return calendar.startOfDay(for: now) }
        return calendar.date(
            byAdding: .weekOfYear,
            value: -(weekCount - 1),
            to: thisWeek.start
        ) ?? thisWeek.start
    }

    private var windowLabel: String {
        switch granularity {
        case .oneDay: "Today"
        case .threeDays: "Last 3 days"
        case .week: "Last 7 days"
        case .twoWeeks: "Last 2 weeks"
        case .fourWeeks: "Last 4 weeks"
        }
    }

    private var radarTotals: [String: Int] {
        var totals: [String: Int] = [:]
        for session in sessions where session.startedAt >= windowStart {
            let category = session.category ?? "Uncategorized"
            totals[category, default: 0] += session.durationSeconds / 60
        }
        return totals
    }

    private var radarEntries: [FocusRadarEntry] {
        radarTotals
            .map { FocusRadarEntry(category: $0.key, minutes: $0.value) }
            .sorted { $0.minutes > $1.minutes }
    }
}

private struct FocusRadarEntry: Identifiable, Equatable {
    let category: String
    let minutes: Int
    var id: String { category }
}

/// Focus stats panda: its own seven exported layers, never shared with Focus.
private struct FocusStatsPanda: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Image("body-212a0198")
                .resizable().scaledToFit()
                .frame(width: 36.2, height: 29.1)
                .offset(x: 14.4, y: 28.6)
            Image("feet-b487e835")
                .resizable().scaledToFit()
                .frame(width: 40.7, height: 10.6)
                .offset(x: 11.2, y: 47.6)
            Image("ears-37ab26a5")
                .resizable().scaledToFit()
                .frame(width: 36.0, height: 9.8)
                .offset(x: 14.3, y: 6.0)
            Image("head-7a970e74")
                .resizable().scaledToFit()
                .frame(width: 35.5, height: 29.2)
                .offset(x: 14.9, y: 8.5)
            Image("thumbs-up-e5270999")
                .resizable().scaledToFit()
                .frame(width: 15.0, height: 17.4)
                .offset(x: 5.6, y: 26.1)
            Image("bamboo-22449151")
                .resizable().scaledToFit()
                .frame(width: 13.2, height: 26.8)
                .offset(x: 46.4, y: 25.1)
            Image("holding-paw-781a6ba0")
                .resizable().scaledToFit()
                .frame(width: 10.5, height: 9.4)
                .offset(x: 43.4, y: 35.7)
        }
        .frame(width: 64, height: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Panda cheering you on")
    }
}

// MARK: - Colors

enum FocusChartColors {
    static let chartBackground = DesignPalette.card
    static let primaryText = DesignPalette.ink
    static let secondaryText = DesignPalette.secondary
    static let skyBlue = Color(red: 147 / 255, green: 185 / 255, blue: 103 / 255)

    static let palette: [Color] = [
        Color(red: 0.93, green: 0.33, blue: 0.33), // coral red
        Color(red: 0.16, green: 0.63, blue: 0.60), // teal
        Color(red: 1.00, green: 0.84, blue: 0.20), // sunny yellow
        Color(red: 0.40, green: 0.45, blue: 0.87), // periwinkle
        Color(red: 1.00, green: 0.60, blue: 0.25), // orange
        Color(red: 0.75, green: 0.42, blue: 0.87), // orchid
        Color(red: 0.25, green: 0.78, blue: 0.45), // emerald
        Color(red: 0.92, green: 0.34, blue: 0.61), // magenta
        Color(red: 0.32, green: 0.66, blue: 0.93), // sky blue
        Color(red: 0.93, green: 0.78, blue: 0.55), // sand
        Color(red: 0.50, green: 0.37, blue: 0.30), // umber
        Color(red: 0.62, green: 0.83, blue: 0.44), // lime
        Color(red: 0.65, green: 0.36, blue: 0.55), // plum
        Color(red: 0.25, green: 0.55, blue: 0.82), // steel blue
        Color(red: 0.89, green: 0.47, blue: 0.67), // rose
        Color(red: 0.96, green: 0.68, blue: 0.35), // apricot
        Color(red: 0.38, green: 0.53, blue: 0.38), // olive
        Color(red: 0.50, green: 0.73, blue: 0.73), // seafoam
        Color(red: 0.73, green: 0.60, blue: 0.88), // lilac
        Color(red: 0.80, green: 0.74, blue: 0.40), // mustard
    ]

    static func color(for category: String) -> Color {
        let index = abs(category.hashValue) % palette.count
        return palette[index]
    }
}

// MARK: - Radar chart

private struct FocusRadarChart: View {
    let entries: [FocusRadarEntry]
    var selectedCategory: String? = nil
    var onSelect: (String) -> Void

    private let size: CGFloat = 280
    private let maxRadius: CGFloat = 88

    private var maxMinutes: Int {
        entries.map(\.minutes).max() ?? 1
    }

    var body: some View {
        let count = entries.count
        ZStack {
            if count > 0 {
                radarGrid(count: count)
                radarArea(count: count)
                radarPoints(count: count)
                axisLabels(count: count)
            } else {
                Text("No sessions in this window")
                    .font(DesignPalette.body(12))
                    .foregroundStyle(FocusChartColors.secondaryText)
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity)
    }

    private func point(count: Int, index: Int, radius: CGFloat) -> CGPoint {
        let angle = -Double.pi / 2
            + Double(index) * 2 * Double.pi / Double(max(count, 1))
        return CGPoint(
            x: size / 2 + radius * cos(angle),
            y: size / 2 + radius * sin(angle)
        )
    }

    private func radarGrid(count: Int) -> some View {
        ZStack {
            ForEach(1...4, id: \.self) { level in
                RadarGridPolygon(
                    count: count,
                    radius: maxRadius * CGFloat(level) / 4,
                    point: point
                )
                .stroke(
                    FocusChartColors.primaryText.opacity(level == 4 ? 0.22 : 0.1),
                    lineWidth: 1
                )
            }
            if count > 1 {
                ForEach(0..<count, id: \.self) { index in
                    Path { path in
                        path.move(to: CGPoint(x: size / 2, y: size / 2))
                        path.addLine(to: point(count: count, index: index, radius: maxRadius))
                    }
                    .stroke(FocusChartColors.primaryText.opacity(0.08), lineWidth: 1)
                }
            }
        }
    }

    private func radarArea(count: Int) -> some View {
        let points = entries.enumerated().map { index, entry in
            point(
                count: count,
                index: index,
                radius: maxRadius * CGFloat(entry.minutes) / CGFloat(maxMinutes)
            )
        }
        let isSelected = selectedCategory != nil

        return RadarArea(points: points)
            .fill(
                isSelected == false
                    ? LinearGradient(
                        colors: [
                            FocusChartColors.skyBlue.opacity(0.45),
                            FocusChartColors.skyBlue.opacity(0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    : LinearGradient(
                        colors: [
                            FocusChartColors.color(for: selectedCategory ?? "").opacity(0.4),
                            FocusChartColors.color(for: selectedCategory ?? "").opacity(0.12)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
            )
            .overlay(
                RadarArea(points: points)
                    .stroke(
                        isSelected == false
                            ? FocusChartColors.skyBlue.opacity(0.85)
                            : FocusChartColors.color(for: selectedCategory ?? "").opacity(0.9),
                        lineWidth: 1.8
                    )
            )
            .animation(.snappy(duration: 0.25), value: selectedCategory)
    }

    private func radarPoints(count: Int) -> some View {
        ForEach(entries) { entry in
            let index = entries.firstIndex(of: entry) ?? 0
            let radius = maxRadius * CGFloat(entry.minutes) / CGFloat(maxMinutes)
            let isSelected = selectedCategory == entry.category
            Button {
                onSelect(entry.category)
            } label: {
                Circle()
                    .fill(FocusChartColors.color(for: entry.category))
                    .frame(width: isSelected ? 14 : 10, height: isSelected ? 14 : 10)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                FocusChartColors.primaryText.opacity(isSelected ? 0.9 : 0.25),
                                lineWidth: isSelected ? 2 : 1
                            )
                    )
                    .shadow(color: FocusChartColors.color(for: entry.category).opacity(0.6), radius: 3)
            }
            .buttonStyle(.plain)
            .position(point(count: count, index: index, radius: radius))
            .accessibilityLabel("Show \(entry.category) sessions")
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
    }

    private func axisLabels(count: Int) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
            let angle = -Double.pi / 2
                + Double(index) * 2 * Double.pi / Double(max(count, 1))
            let labelRadius = maxRadius + 22
            let isSelected = selectedCategory == entry.category
            Button {
                onSelect(entry.category)
            } label: {
                Text(entry.category)
                    .font(DesignPalette.body(11).weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(
                        isSelected
                            ? FocusChartColors.color(for: entry.category)
                            : FocusChartColors.secondaryText
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            }
            .buttonStyle(.plain)
            .position(
                CGPoint(
                    x: size / 2 + labelRadius * cos(angle),
                    y: size / 2 + labelRadius * sin(angle)
                )
            )
            .accessibilityLabel("Show \(entry.category) sessions")
            .animation(.snappy(duration: 0.2), value: isSelected)
        }
    }
}

private struct RadarGridPolygon: Shape {
    let count: Int
    let radius: CGFloat
    var point: (Int, Int, CGFloat) -> CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard count > 1 else { return path }
        for index in 0..<count {
            let p = point(count, index, radius)
            if index == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        path.closeSubpath()
        return path
    }
}

private struct RadarArea: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() {
            path.addLine(to: p)
        }
        path.closeSubpath()
        return path
    }
}

#Preview {
    FocusStatsView()
        .environment(FocusService())
}
