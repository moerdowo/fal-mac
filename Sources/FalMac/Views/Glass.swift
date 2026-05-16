import SwiftUI

// Liquid Glass design helpers. Since this app targets macOS 26+, we can use
// the `glassEffect()` API directly — no `#available` gating needed.

extension View {
    /// A rounded-rect glass surface, the workhorse for cards in the UI.
    func glassCard(cornerRadius: CGFloat = 14) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// A tinted rounded-rect glass surface — used for status-coloured cards
    /// (e.g. running run cards get a faint orange tint). Passing `.clear`
    /// skips the tint so the card reads as plain glass.
    @ViewBuilder
    func glassCard(tint: Color, cornerRadius: CGFloat = 14) -> some View {
        if tint == .clear {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.glassEffect(.regular.tint(tint.opacity(0.18)), in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// Interactive pill (hovers/presses respond visually). Used for the balance
    /// chip and similar small floating controls.
    func glassPill(tint: Color? = nil) -> some View {
        Group {
            if let tint {
                self.glassEffect(.regular.interactive().tint(tint.opacity(0.22)), in: .capsule)
            } else {
                self.glassEffect(.regular.interactive(), in: .capsule)
            }
        }
    }

    /// A thin glass strip — used for panel headers / footers where we want a
    /// hairline of glass without it competing with the content.
    func glassStrip() -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}
