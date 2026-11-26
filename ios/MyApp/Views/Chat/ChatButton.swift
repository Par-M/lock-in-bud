import SwiftUI

struct ChatButton: View {
    @State private var showingChat = false

    var body: some View {
        Button {
            showingChat = true
        } label: {
            HStack {
                Label("Ask Assistant", systemImage: "bubble.left.and.bubble.right")
                    .font(DesignPalette.body(13).weight(.semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(DesignPalette.secondary)
            }
            .foregroundStyle(DesignPalette.ink)
            .padding()
            .frame(maxWidth: .infinity)
            .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
            .shadow(color: DesignPalette.ink.opacity(0.06), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingChat) {
            ChatView()
        }
    }
}
