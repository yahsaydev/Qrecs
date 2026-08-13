import SwiftUI

struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                }
        }
    }
}

extension View {
    func qrecsGlass(cornerRadius: CGFloat = 18) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }
}

extension Color {
    init(ambientAccent: AmbientAccent) {
        self.init(
            red: Double((ambientAccent.hex >> 16) & 0xFF) / 255,
            green: Double((ambientAccent.hex >> 8) & 0xFF) / 255,
            blue: Double(ambientAccent.hex & 0xFF) / 255
        )
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
