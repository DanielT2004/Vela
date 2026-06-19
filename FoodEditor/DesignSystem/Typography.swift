import SwiftUI

/// The mockup pairs Newsreader (serif display) with Hanken Grotesk (sans body).
/// For a self-contained build we map them to the closest system designs. Dropping in the
/// real Google Font TTFs later is a small swap: add the .ttf files to the FoodEditor folder,
/// register `UIAppFonts` in Info.plist, and change `.serif`/`.default` to the custom names.
enum VeFont {
    /// Newsreader-style serif display (titles, hero captions).
    static func serif(_ size: CGFloat, weight: Font.Weight = .medium, italic: Bool = false) -> Font {
        let base = Font.system(size: size, weight: weight, design: .serif)
        return italic ? base.italic() : base
    }

    /// Hanken-Grotesk-style sans (body, labels, buttons).
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }

    /// JetBrains-Mono-style monospace (timecode, status labels, frame counts).
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced)
    }
}
