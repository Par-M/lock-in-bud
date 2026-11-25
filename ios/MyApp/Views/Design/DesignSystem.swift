import SwiftUI

/// Shared visual language for the Figma redesign. Colors mirror the design
/// file's palette; spacing and radii follow its 4pt grid.
enum DesignPalette {
    static let background = Color(hex: 0xF3F3EB)
    static let ink = Color(hex: 0x202923)
    static let primary = Color(hex: 0x3E663C)
    static let secondary = Color(hex: 0x667060)
    static let sage = Color(hex: 0xE1E9D5)
    static let cream = Color(hex: 0xE8E4D6)
    static let card = Color.white
    static let mutedInk = Color(hex: 0x667060).opacity(0.85)

    static let cardRadius: CGFloat = 18
    static let compactRadius: CGFloat = 12
    static let pagePadding: CGFloat = 24

    static func screenTitle(_ size: CGFloat = 27) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    static func sectionTitle(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold, design: .rounded)
    }

    static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .rounded)
    }

    static func eyebrow(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Light parchment canvas used by every redesigned screen.
struct AppBackdrop: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(DesignPalette.background)
            .foregroundStyle(DesignPalette.ink)
            .tint(DesignPalette.primary)
    }
}

extension View {
    func appBackdrop() -> some View {
        modifier(AppBackdrop())
    }
}

/// Uppercase section label with the wide tracking used in the design file.
struct AppEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DesignPalette.eyebrow())
            .kerning(1.6)
            .foregroundStyle(DesignPalette.secondary)
    }
}

/// Screen heading: small eyebrow above a large rounded title, with an
/// optional trailing control (settings, add, dashboard, ...).
struct AppHeader<Trailing: View>: View {
    let eyebrow: String
    let title: String
    let trailing: Trailing

    init(
        eyebrow: String,
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                AppEyebrow(text: eyebrow)
                Text(title)
                    .font(DesignPalette.screenTitle())
                    .foregroundStyle(DesignPalette.ink)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// White card with the soft shadow used throughout the Figma screens.
struct AppCard<Content: View>: View {
    let padding: CGFloat
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignPalette.card, in: RoundedRectangle(cornerRadius: DesignPalette.cardRadius))
            .shadow(color: DesignPalette.ink.opacity(0.06), radius: 10, y: 4)
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignPalette.body(15))
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(DesignPalette.primary, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct AppSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DesignPalette.body(14))
            .fontWeight(.semibold)
            .foregroundStyle(DesignPalette.primary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(DesignPalette.sage, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Round icon-only control (settings, plus, arrows) with a 44pt hit target.
struct AppIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DesignPalette.primary)
                .frame(width: 44, height: 44)
                .background(DesignPalette.sage, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}
