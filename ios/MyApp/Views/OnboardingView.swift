import SwiftUI

struct OnboardingView: View {

    let onComplete: () -> Void

    @State private var step = 0
    @State private var showFirstTask = false

    private static let onboardedKey = "app.onboarded"

    static var isComplete: Bool {
        UserDefaults.standard.bool(forKey: onboardedKey)
    }

    init(onComplete: @escaping () -> Void = {}) {
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcomePage.tag(0)
                aiPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.default, value: step)

            HStack(spacing: 12) {
                if step > 0 {
                    Button("Back") { step -= 1 }
                        .buttonStyle(AppSecondaryButtonStyle())
                        .frame(width: 110)
                }
                Spacer(minLength: 8)
                Button(continueTitle) {
                    next()
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .frame(maxWidth: step > 0 ? .infinity : 180)
                .disabled(continueDisabled)
            }
            .padding()
        }
        .appBackdrop()
        .sheet(isPresented: $showFirstTask) {
            TaskFormView(mode: .add) { _ in
                complete()
            }
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        pageView {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 72))
                .foregroundStyle(DesignPalette.primary)
            Text("Lock In Bud")
                .font(DesignPalette.screenTitle(34))
                .foregroundStyle(DesignPalette.ink)
            Text("Start with one task.\nChoose what matters today and make a plan you can change.")
                .font(DesignPalette.body(14))
                .foregroundStyle(DesignPalette.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var aiPage: some View {
        pageView {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(DesignPalette.primary)
                .frame(width: 72, height: 72)
                .background(DesignPalette.sage, in: Circle())
            Text("How the AI works")
                .font(DesignPalette.screenTitle(24))
                .foregroundStyle(DesignPalette.ink)
            Text("The scheduler proposes times around your deadlines and fixed events. Review a plan before applying it. You can connect a calendar and enable reminders later in Settings.")
                .font(DesignPalette.body(13))
                .foregroundStyle(DesignPalette.secondary)
                .multilineTextAlignment(.center)

            Button {
                showFirstTask = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text("Create Your First Task")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Helpers

    private var continueTitle: String {
        switch step {
        case 0: "Get Started"
        case 1: "Start planning"
        default: "Continue"
        }
    }

    private var continueDisabled: Bool {
        false
    }

    private func next() {
        if step == 1 {
            complete()
        } else {
            step += 1
        }
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)
        onComplete()
    }

    private func pageView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 20) {
            content()
                .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(32)
    }
}

#Preview {
    OnboardingView()
        .environment(AuthenticationService())
        .environment(CalendarService())
        .environment(NotificationService.shared)
        .environment(ScheduleService())
}
