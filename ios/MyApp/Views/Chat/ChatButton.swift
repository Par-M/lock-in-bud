import SwiftUI

struct ChatButton: View {
    @State private var showingChat = false

    var body: some View {
        Button {
            showingChat = true
        } label: {
            HStack {
                Label("Ask Assistant", systemImage: "bubble.left.and.bubble.right")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingChat) {
            ChatView()
        }
    }
}
