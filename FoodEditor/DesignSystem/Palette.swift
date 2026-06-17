import SwiftUI

/// Warm Editorial palette — ported verbatim from the Claude Design mockup (Variation A).
/// Food imagery is the hero; the chrome recedes. No blue, no purple/AI gradients.
extension Color {
    /// #F7F3EC — cream base / chrome background.
    static let veCream = Color(hex: 0xF7F3EC)
    /// #EDE7DC — warm-gray secondary surface (cut-tray pill, chips).
    static let veSurface = Color(hex: 0xEDE7DC)
    /// #B5654A — muted terracotta, the appetite color. Primary actions / active hook.
    static let veTerracotta = Color(hex: 0xB5654A)
    /// #5F7355 — muted sage. Success / "done" / keep states.
    static let veSage = Color(hex: 0x5F7355)
    /// #2E2A26 — warm charcoal text (never pure black).
    static let veCharcoal = Color(hex: 0x2E2A26)
    /// #8A8178 — warm-gray secondary text.
    static let veWarmGray = Color(hex: 0x8A8178)
    /// #A89F90 — fainter warm gray (hints).
    static let veFaintGray = Color(hex: 0xA89F90)
    /// #FBF4EC — near-white tint used on terracotta surfaces.
    static let veOnTerracotta = Color(hex: 0xFBF4EC)
    /// #F4EFE6 — reason-note background.
    static let veNote = Color(hex: 0xF4EFE6)
    /// #6E665C — reason-note text.
    static let veNoteText = Color(hex: 0x6E665C)

    /// Build a Color from a 0xRRGGBB hex literal.
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
