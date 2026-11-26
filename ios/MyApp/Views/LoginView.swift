import SwiftUI

struct LoginView: View {
    @Environment(AuthenticationService.self) private var authService
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 64))
                .foregroundStyle(DesignPalette.primary)
                .frame(width: 104, height: 104)
                .background(DesignPalette.sage, in: Circle())

            VStack(spacing: 8) {
                Text("Lock In Bud")
                    .font(DesignPalette.screenTitle(34))
                    .foregroundStyle(DesignPalette.ink)
                Text("Sign in to continue")
                    .font(DesignPalette.body(14))
                    .foregroundStyle(DesignPalette.secondary)
            }

            Spacer()

            Button {
                Task { await signInWithGoogle() }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "g.circle.fill")
                    Text("Continue with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(AppPrimaryButtonStyle())
            .padding(.horizontal, DesignPalette.pagePadding)
            .disabled(isLoading)

            let devSignInEnabled = ProcessInfo.processInfo.arguments.contains("-uiTesting")
            if devSignInEnabled {
                Button("Development Sign In") {
                    Task { await signInDev() }
                }
                .font(DesignPalette.body(12).weight(.semibold))
                .foregroundStyle(DesignPalette.primary)
                .disabled(isLoading)
            }

            if isLoading {
                ProgressView()
                    .tint(DesignPalette.primary)
            }

            Spacer()
        }
        .appBackdrop()
        .alert(
            "Sign In Failed",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func signInWithGoogle() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.signInWithGoogle()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signInDev() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await authService.signInDev()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    LoginView()
        .environment(AuthenticationService())
}
