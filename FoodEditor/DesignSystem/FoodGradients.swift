import SwiftUI

/// Warm food-tone gradients ported from the mockup's `fg(food)` map. Used as placeholders and
/// empty-state art; real segment art comes from `AVAssetImageGenerator` frames once we have video.
enum FoodTone: String, CaseIterable {
    case cheese, tomato, herb, dough, char, berry, plate, talk

    var gradient: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var colors: [Color] {
        switch self {
        case .cheese: return [Color(hex: 0xE8B65E), Color(hex: 0xB5654A)]
        case .tomato: return [Color(hex: 0xCC6443), Color(hex: 0x9E3322)]
        case .herb:   return [Color(hex: 0x8B9B5C), Color(hex: 0x566B3F)]
        case .dough:  return [Color(hex: 0xECD9B0), Color(hex: 0xC9A269)]
        case .char:   return [Color(hex: 0x9A7350), Color(hex: 0x5C4636)]
        case .berry:  return [Color(hex: 0xB36A66), Color(hex: 0x7E3B47)]
        case .plate:  return [Color(hex: 0xE2D4BE), Color(hex: 0xBE9F79)]
        case .talk:   return [Color(hex: 0xCBBEA9), Color(hex: 0x9C8B73)]
        }
    }

    /// Deterministic tone for an integer key (so a segment id keeps a stable look).
    static func tone(for key: Int) -> FoodTone {
        let count = allCases.count
        return allCases[((key % count) + count) % count]
    }
}

/// A rounded gradient tile used wherever real imagery isn't available yet.
struct FoodTile: View {
    let tone: FoodTone
    var cornerRadius: CGFloat = 16

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tone.gradient)
    }
}
