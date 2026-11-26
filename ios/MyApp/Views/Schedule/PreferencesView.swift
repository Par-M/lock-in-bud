import SwiftUI

struct PreferencesView: View {
    @Environment(ScheduleService.self) private var scheduleService
    @Environment(\.dismiss) private var dismiss

    @State private var workStart: Double = 9
    @State private var workEnd: Double = 17
    @State private var buffer = 15
    @State private var energy = 3
    @State private var maxDailyHours = 8
    @State private var defaultDuration = 30
    @State private var defaultPriority: TaskPriority = .medium
    @State private var isLoaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    AppHeader(eyebrow: "PREFERENCES", title: "Plan your day.")

                    settingSection("WORK HOURS") {
                        Stepper(value: $workStart, in: 0...24, step: 0.5) {
                            Text("Start: \(hourText(workStart))")
                                .font(DesignPalette.body(14))
                        }
                        .tint(DesignPalette.primary)
                        Divider().background(DesignPalette.cream)
                        Stepper(value: $workEnd, in: 0...24, step: 0.5) {
                            Text("End: \(hourText(workEnd))")
                                .font(DesignPalette.body(14))
                        }
                        .tint(DesignPalette.primary)
                        if !workHoursValid {
                            Divider().background(DesignPalette.cream)
                            Label("End must be after start", systemImage: "exclamationmark.triangle")
                                .font(DesignPalette.body(12))
                                .foregroundStyle(.orange)
                        }
                    }

                    settingSection("SCHEDULING") {
                        Stepper(value: $buffer, in: 0...120, step: 5) {
                            Text("Buffer: \(buffer) min")
                                .font(DesignPalette.body(14))
                        }
                        .tint(DesignPalette.primary)
                        Divider().background(DesignPalette.cream)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Energy Level")
                                .font(DesignPalette.body(13).weight(.semibold))
                            Picker("Energy Level", selection: $energy) {
                                ForEach(1...5, id: \.self) { level in
                                    Text("\(level)").tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(DesignPalette.primary)
                            .accessibilityLabel("Energy Level")
                        }
                        Divider().background(DesignPalette.cream)
                        Stepper(value: $maxDailyHours, in: 1...16) {
                            Text("Max daily hours: \(maxDailyHours)")
                                .font(DesignPalette.body(14))
                        }
                        .tint(DesignPalette.primary)
                        Divider().background(DesignPalette.cream)
                        Stepper(value: $defaultDuration, in: 5...480, step: 5) {
                            Text("Default task duration: \(defaultDuration) min")
                                .font(DesignPalette.body(14))
                        }
                        .tint(DesignPalette.primary)
                        Divider().background(DesignPalette.cream)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Default Priority")
                                .font(DesignPalette.body(13).weight(.semibold))
                            Picker("Default Priority", selection: $defaultPriority) {
                                ForEach(TaskPriority.allCases) { priority in
                                    Text(priority.label).tag(priority)
                                }
                            }
                            .pickerStyle(.segmented)
                            .tint(DesignPalette.primary)
                            .accessibilityLabel("Default Priority")
                        }
                    }

                    AppCard(padding: 14) {
                        Button {
                            Task { await save() }
                        } label: {
                            Text("Save Preferences")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(AppPrimaryButtonStyle())
                        .disabled(!isLoaded || !workHoursValid)
                    }
                }
                .padding(.horizontal, DesignPalette.pagePadding)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .appBackdrop()
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DesignPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(DesignPalette.primary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await scheduleService.loadPreferences()
                if let pref = scheduleService.preference {
                    workStart = pref.workHoursStart
                    workEnd = pref.workHoursEnd
                    buffer = pref.bufferMinutes
                    energy = pref.energyLevel
                    maxDailyHours = pref.maxDailyHours
                    defaultDuration = pref.defaultDurationMinutes
                    defaultPriority = TaskPriority(rawValue: pref.defaultPriority) ?? .medium
                }
                isLoaded = true
            }
        }
    }

    @ViewBuilder
    private func settingSection<Content: View>(
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

    private func hourText(_ value: Double) -> String {
        let hour = Int(value)
        let minutes = Int((value - Double(hour)) * 60)
        if hour >= 24 {
            return "24:00"
        }
        return String(format: "%d:%02d", hour, minutes)
    }

    private var workHoursValid: Bool {
        workEnd > workStart
    }

    private func save() async {
        let update = UserPreferenceUpdate(
            workHoursStart: workStart,
            workHoursEnd: workEnd,
            bufferMinutes: buffer,
            energyLevel: energy,
            maxDailyHours: maxDailyHours,
            defaultDurationMinutes: defaultDuration,
            defaultPriority: defaultPriority.rawValue
        )
        await scheduleService.updatePreferences(update)
        dismiss()
    }
}

#Preview {
    PreferencesView()
        .environment(ScheduleService())
}
