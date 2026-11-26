import SwiftUI
import Combine

struct FocusView: View {
    @Environment(TaskService.self) private var taskService
    @Environment(\.dismiss) private var dismiss

    let task: ScheduledTask

    @State private var elapsed = 0
    @State private var isPaused = false
    @State private var isRunning = false
    @State private var showCompletion = false
    @State private var showProductivity = false
    @State private var isSubmitting = false
    @State private var focusError: String?

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var targetSeconds: Int {
        max(60, (task.estimatedDuration ?? 45) * 60)
    }

    private var remaining: Int {
        max(0, targetSeconds - elapsed)
    }

    private var progress: Double {
        min(max(Double(elapsed) / Double(targetSeconds), 0), 1)
    }

    private var elapsedMinutes: Int? {
        elapsed >= 60 ? elapsed / 60 : nil
    }

    var body: some View {
        VStack(spacing: 40) {
            Spacer()

            VStack(spacing: 8) {
                Text(task.title)
                    .font(DesignPalette.screenTitle(22))
                    .foregroundStyle(DesignPalette.ink)
                    .multilineTextAlignment(.center)
                if let category = task.category, !category.isEmpty {
                    Text(category)
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                }
            }

            ZStack {
                Circle()
                    .stroke(DesignPalette.sage, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(DesignPalette.primary, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text(formatted(remaining))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(DesignPalette.ink)
                    Text(isPaused ? "Paused" : "Focusing")
                        .font(DesignPalette.body(12))
                        .foregroundStyle(DesignPalette.secondary)
                }
            }
            .frame(width: 240, height: 240)
            .padding()

            Spacer()

            VStack(spacing: 12) {
                if isRunning {
                    Button {
                        isPaused.toggle()
                    } label: {
                        Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AppPrimaryButtonStyle())
                    .disabled(isSubmitting)

                    Button {
                        showCompletion = true
                    } label: {
                        Text("Finish Early")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AppSecondaryButtonStyle())
                    .disabled(isSubmitting)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(DesignPalette.primary)
                }
            }
            .padding(.horizontal, DesignPalette.pagePadding)

            Spacer()
        }
        .appBackdrop()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: beginFocus)
        .onReceive(timer) { _ in
            guard isRunning, !isPaused else { return }
            elapsed += 1
            if elapsed >= targetSeconds {
                isPaused = true
                showCompletion = true
            }
        }
        .confirmationDialog(
            "Finish \(task.title)?",
            isPresented: $showCompletion,
            titleVisibility: .visible
        ) {
            Button("Yes, completed") {
                isPaused = true
                showProductivity = true
            }
            Button("Still working on it") {
                recordElapsed()
            }
            Button("Skip for now", role: .cancel) {
                dismiss()
            }
        }
        .confirmationDialog(
            "How did it go?",
            isPresented: $showProductivity,
            titleVisibility: .visible
        ) {
            ForEach(TaskProductivity.allCases) { productivity in
                Button(productivity.label) {
                    complete(productivity: productivity)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Something went wrong", isPresented: isPresentedError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(focusError ?? "")
        }
    }

    private func beginFocus() {
        guard !isRunning else { return }
        isRunning = true
        elapsed = 0
        isPaused = false

        Task {
            do {
                _ = try await taskService.startTask(id: task.id)
            } catch {
                isRunning = false
                focusError = error.localizedDescription
            }
        }
    }

    private func complete(productivity: TaskProductivity) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                _ = try await taskService.completeTask(
                    id: task.id,
                    minutes: elapsedMinutes,
                    productivity: productivity
                )
                dismiss()
            } catch {
                isSubmitting = false
                focusError = error.localizedDescription
            }
        }
    }

    private func recordElapsed() {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                if let minutes = elapsedMinutes {
                    _ = try await taskService.recordTime(id: task.id, minutes: minutes)
                }
                dismiss()
            } catch {
                isSubmitting = false
                focusError = error.localizedDescription
            }
        }
    }

    private var isPresentedError: Binding<Bool> {
        Binding(
            get: { focusError != nil },
            set: { if !$0 { focusError = nil } }
        )
    }

    private func formatted(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
