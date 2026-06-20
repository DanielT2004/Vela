import SwiftUI
import UIKit

/// A burned-in text caption that plays over the video for `[startTime, endTime]` (assembled
/// main-timeline seconds). Everything spatial is stored in **normalized 9:16 space** (fractions of the
/// frame) so the SAME overlay maps identically onto the 720p preview and the 1080×1920 export — that's
/// the WYSIWYG contract for text. Both `PolishView`'s preview overlay and `EditPlanAssembler`'s
/// Core-Animation burn-in resolve geometry the same way.
struct TextOverlay: Identifiable, Equatable, Codable {
    let id: UUID
    var string: String
    /// Center of the text box, fractions of the frame (0…1). (0.5, 0.5) = dead center.
    var centerX: Double
    var centerY: Double
    /// Point size as a **fraction of frame height**, so it scales across resolutions (0.055 ≈ 5.5%).
    var fontSize: Double
    /// Rotation in radians (SwiftUI sense: +clockwise in the top-left/Y-down preview space).
    var rotation: Double
    var font: TextFontFamily
    var weight: TextWeight
    var color: RGBAColor
    var alignment: TextAlign
    var background: Bool          // a filled pill behind the text
    var outline: Bool            // a dark stroke/shadow for legibility over busy video
    var startTime: Double
    var endTime: Double

    init(id: UUID = UUID(), string: String = "Tap to edit",
         centerX: Double = 0.5, centerY: Double = 0.78, fontSize: Double = 0.055,
         rotation: Double = 0, font: TextFontFamily = .classic, weight: TextWeight = .bold,
         color: RGBAColor = .white, alignment: TextAlign = .center,
         background: Bool = false, outline: Bool = true,
         startTime: Double, endTime: Double) {
        self.id = id; self.string = string
        self.centerX = centerX; self.centerY = centerY; self.fontSize = fontSize; self.rotation = rotation
        self.font = font; self.weight = weight; self.color = color; self.alignment = alignment
        self.background = background; self.outline = outline
        self.startTime = startTime; self.endTime = endTime
    }

    var duration: Double { max(0, endTime - startTime) }
    func isVisible(at t: Double) -> Bool { t >= startTime && t < endTime }
}

// MARK: - Font families (curated iOS built-ins — no bundled .ttf files)

/// The five mockup "styles" mapped to fonts that ship with iOS, so the picker works with zero assets.
/// To match the mockup's exact faces later, drop the real TTFs in + register `UIAppFonts` and only the
/// PostScript names below need to change — both the preview (`swiftUIFont`) and the export (`uiFont`)
/// resolve through this one type, so they can't drift.
enum TextFontFamily: String, Codable, CaseIterable, Identifiable {
    case classic, impact, serif, casual, script
    var id: String { rawValue }

    /// Picker label under the "Ag" card.
    var label: String {
        switch self {
        case .classic: return "Classic"
        case .impact:  return "Impact"
        case .serif:   return "Serif"
        case .casual:  return "Casual"
        case .script:  return "Script"
        }
    }

    /// PostScript name for a given weight, or nil to use the system fallback.
    func postScriptName(_ weight: TextWeight) -> String? {
        switch self {
        case .classic: return ["AvenirNext-Medium", "AvenirNext-DemiBold", "AvenirNext-Heavy"][weight.rawValue]
        case .impact:  return ["Futura-CondensedMedium", "Futura-CondensedExtraBold", "Futura-CondensedExtraBold"][weight.rawValue]
        case .serif:   return ["Didot", "Didot", "Didot-Bold"][weight.rawValue]
        case .casual:  return ["Noteworthy-Light", "Noteworthy-Light", "Noteworthy-Bold"][weight.rawValue]
        case .script:  return ["SnellRoundhand", "SnellRoundhand", "SnellRoundhand-Bold"][weight.rawValue]
        }
    }

    /// System-font design used if a named face ever fails to resolve (keeps preview == export).
    private var fallbackDesign: UIFontDescriptor.SystemDesign {
        switch self {
        case .classic, .impact: return .default
        case .serif:            return .serif
        case .casual, .script:  return .rounded
        }
    }

    func uiFont(size: CGFloat, weight: TextWeight) -> UIFont {
        if let name = postScriptName(weight), let f = UIFont(name: name, size: size) { return f }
        let base = UIFont.systemFont(ofSize: size, weight: weight.uiWeight)
        if let d = base.fontDescriptor.withDesign(fallbackDesign) { return UIFont(descriptor: d, size: size) }
        return base
    }

    func swiftUIFont(size: CGFloat, weight: TextWeight) -> Font {
        if let name = postScriptName(weight), UIFont(name: name, size: size) != nil {
            return .custom(name, fixedSize: size)
        }
        let design: Font.Design = fallbackDesign == .serif ? .serif : (fallbackDesign == .rounded ? .rounded : .default)
        return .system(size: size, weight: weight.fontWeight, design: design)
    }
}

enum TextWeight: Int, Codable, CaseIterable, Identifiable {
    case light = 0, regular = 1, bold = 2
    var id: Int { rawValue }
    var label: String { ["Light", "Regular", "Bold"][rawValue] }
    var uiWeight: UIFont.Weight { [.light, .regular, .heavy][rawValue] }
    var fontWeight: Font.Weight { [.light, .regular, .heavy][rawValue] }
}

enum TextAlign: String, Codable, CaseIterable {
    case leading, center, trailing
    var swiftUI: TextAlignment {
        switch self { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
    /// Cycle through alignments for the toolbar's "Align" toggle.
    var next: TextAlign {
        switch self { case .leading: return .center; case .center: return .trailing; case .trailing: return .leading }
    }
    var sfSymbol: String {
        switch self { case .leading: return "text.alignleft"; case .center: return "text.aligncenter"; case .trailing: return "text.alignright" }
    }
    var nsTextAlignment: NSTextAlignment {
        switch self { case .leading: return .left; case .center: return .center; case .trailing: return .right }
    }
}

// MARK: - Codable RGBA color (bridges SwiftUI Color ⇄ UIColor for the picker, preview, and export)

struct RGBAColor: Codable, Equatable, Hashable {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: Color) {
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
        UIColor(color).getRed(&rr, green: &gg, blue: &bb, alpha: &aa)
        r = Double(rr); g = Double(gg); b = Double(bb); a = Double(aa)
    }

    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var ui: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    static let white     = RGBAColor(r: 1, g: 1, b: 1)
    static let cream     = RGBAColor(r: 0xFB / 255, g: 0xF4 / 255, b: 0xEC / 255)
    static let charcoal  = RGBAColor(r: 0x2E / 255, g: 0x2A / 255, b: 0x26 / 255)
    static let terracotta = RGBAColor(r: 0xB5 / 255, g: 0x65 / 255, b: 0x4A / 255)
    static let sage      = RGBAColor(r: 0x5F / 255, g: 0x73 / 255, b: 0x55 / 255)
    static let ochre     = RGBAColor(r: 0xE8 / 255, g: 0xB6 / 255, b: 0x5E / 255)
    static let deepRed   = RGBAColor(r: 0xC0 / 255, g: 0x49 / 255, b: 0x2F / 255)

    /// Swatch row in the Style tab (mockup Frame C).
    static let presets: [RGBAColor] = [.white, .charcoal, .terracotta, .sage, .ochre, .deepRed]
}
