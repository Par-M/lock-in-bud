import SwiftUI
import FamilyControls
import ManagedSettings
import Combine

struct FocusLockView: View {
    @State private var lock = FocusLockService.shared
    @State private var picker = false
    @State private var reason = ""
    @State private var selectedApp: ApplicationToken?
    @State private var minutes = 2
    @State private var readyAt: Date?
    @State private var emergency = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            if let issue = lock.issue { Section { Text(issue).foregroundStyle(.orange) } }
            if let session = lock.session {
                Section("Focus Lock active · \(session.profile)") {
                    Text("Selected apps stay blocked even when the timer is paused. Blocking ends automatically after two hours.")
                    if let until = session.exceptionUntil, until > .now {
                        Text("Exception ends \(until, style: .time). iOS controls the timing of automatic reblocking.")
                        Button("Message sent? Return to focus") { lock.returnToFocus(); resetRequest() }
                    } else if session.canRequestException {
                        Text("Need an app for something important? Choose it below. Messages access permits the whole app, not a single conversation.")
                        ForEach(Array(session.selection.applicationTokens), id: \.self) { token in
                            Button { selectedApp = token; readyAt = nil } label: {
                                HStack { Label(token); Spacer(); if selectedApp == token { Image(systemName: "checkmark.circle.fill") } }
                            }.buttonStyle(.plain).frame(minHeight: 44)
                        }
                        TextField("Why do you need it?", text: $reason).onChange(of: reason) { readyAt = nil }
                        Picker("Access window", selection: $minutes) { Text("2 minutes").tag(2); Text("5 minutes").tag(5) }.onChange(of: minutes) { readyAt = nil }
                        if let readyAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let remaining = max(0, Int(ceil(readyAt.timeIntervalSince(context.date))))
                                Button(remaining > 0 ? "Take a breath · \(remaining)s" : "Unlock selected app") {
                                    guard let selectedApp, Date() >= readyAt else { return }
                                    lock.allow(selectedApp, minutes: minutes, reason: reason); resetRequest()
                                }.disabled(remaining > 0)
                            }
                        } else {
                            Button("Request short exception") { readyAt = .now.addingTimeInterval(session.strict ? 30 : 10) }.disabled(selectedApp == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if session.strict { Text("Strict mode: \(max(0, 2 - session.exceptionCount)) exceptions remaining.").font(.footnote) }
                    } else { Text("Your two exceptions have been used. You can still use the emergency exit.") }
                }
                Section { Button("Emergency exit · release blocked apps", role: .destructive) { emergency = true } }
            } else {
                Section("Set up Focus Lock") {
                    Button(lock.authorized ? "Screen Time access enabled" : "Enable Screen Time access") { Task { await lock.authorize() } }.disabled(lock.authorized)
                    Toggle("Use Focus Lock with the timer", isOn: $lock.enabled)
                    Picker("Profile", selection: $lock.profile) { ForEach(["Study", "Work", "Workout"], id: \.self) { Text($0).tag($0) } }.onChange(of: lock.profile) { lock.loadProfile() }
                    Button("Choose apps to block (\(lock.selection.applicationTokens.count))") { picker = true }.disabled(!lock.authorized)
                    Text("Select individual apps. Leave tools you need, such as Music for workouts, unselected. Categories and websites are not included.").font(.footnote)
                    Toggle("Strict mode", isOn: $lock.strict)
                    Text("Flexible: a 10-second pause before exceptions. Strict: 30 seconds and two exceptions per session. Emergency exit remains available.").font(.footnote)
                    if FocusTimerStarter.startedAt > 0 { Button("Activate for this session") { lock.start() }.disabled(!lock.enabled) }
                }
                Section { Text("Focus Lock needs Screen Time permission. You control that permission and can revoke it. It cannot determine whether a message is important. App selections stay on this device.") }
            }
        }
        .navigationTitle("Focus Lock")
        .familyActivityPicker(isPresented: $picker, selection: $lock.selection)
        .onChange(of: picker) { if !picker { lock.saveProfile() } }
        .task { lock.refresh() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            if let session = lock.session, session.expiresAt <= now || (session.exceptionToken != nil && session.exceptionUntil.map({ $0 <= now }) == true) { lock.refresh() }
        }
        .onChange(of: scenePhase) { if scenePhase == .active { lock.refresh(); resetRequest() } }
        .confirmationDialog("Release blocked apps? Your focus timer will continue.", isPresented: $emergency, titleVisibility: .visible) {
            Button("Release apps", role: .destructive) { lock.end(); resetRequest() }
        }
    }
    private func resetRequest() { readyAt = nil; reason = ""; selectedApp = nil }
}
