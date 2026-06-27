import SwiftUI

/// The **"Column drift"** loading animation (Claude Design — Vela Loading 01, Option C): three vertical
/// lanes of the creator's footage thumbnails drifting up/down (alternating per column) at a calm
/// constant speed, the lanes revealing staggered as *real* progress grows, with a gold→terracotta
/// progress bar + % along the bottom. Tiles fall back to warm food-gradients when a thumbnail is
/// missing. Plays through both prepping (on-device compress) and analyzing (server) — paced to the real
/// pipeline `progress`, not a demo clock. View-based (not SwiftUI `Canvas`) so the drift is
/// GPU-composited and doesn't compete with the CPU-heavy export.
struct ColumnDriftLoader: View {
    /// The creator's footage frames, cycled across tiles. Empty → warm food-gradient fallback.
    let thumbnails: [UIImage]
    /// Real pipeline progress 0…1 — drives the lane reveal, the bar, and the %.
    var progress: Double
    var accent: Color = .veTerracotta

    private let columns = 3
    private let colGap: CGFloat = 9
    private let tileGap: CGFloat = 9
    private let speed: Double = 20            // pt/s — calm, deliberately slower than the design demo

    /// Warm food-gradient fallback pairs (the design's `foods` palette).
    private static let foods: [(Color, Color)] = [
        (Color(hex: 0xE8B65E), Color(hex: 0xC98B43)), (Color(hex: 0xCC6443), Color(hex: 0x9E3322)),
        (Color(hex: 0x8B9B5C), Color(hex: 0x566B3F)), (Color(hex: 0xECD9B0), Color(hex: 0xC9A269)),
        (Color(hex: 0xB36A66), Color(hex: 0x7E3B47)), (Color(hex: 0x9A7350), Color(hex: 0x5C4636)),
        (Color(hex: 0xD98E5A), Color(hex: 0xA65E32)), (Color(hex: 0x6E8B6A), Color(hex: 0x3F5C3B)),
    ]

    var body: some View {
        VStack(spacing: 12) {
            GeometryReader { geo in
                let laneW = (geo.size.width - colGap * CGFloat(columns - 1)) / CGFloat(columns)
                let tileH = laneW * 1.5
                // Fully qualified — the project has its own `TimelineView` (the editor timeline).
                SwiftUI.TimelineView(.animation) { timeline in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    HStack(spacing: colGap) {
                        ForEach(0..<columns, id: \.self) { c in
                            lane(c, laneW: laneW, tileH: tileH, laneH: geo.size.height, t: t)
                        }
                    }
                }
            }
            progressBar
        }
    }

    /// One vertical lane: tiles laid out every `period`, scrolled by a wrapping offset, clipped to a
    /// rounded lane, revealed (fade + slight slide) by progress.
    private func lane(_ c: Int, laneW: CGFloat, tileH: CGFloat, laneH: CGFloat, t: Double) -> some View {
        let period = tileH + tileGap
        let dir: Double = c % 2 == 0 ? 1 : -1                       // even cols drift down, odd up
        let m = (t * speed).truncatingRemainder(dividingBy: Double(period))
        let off = CGFloat(m < 0 ? m + Double(period) : m)
        let y0 = dir > 0 ? (off - period) : -off
        let cyc = Int((t * speed) / Double(period))
        let count = Int((laneH / period).rounded(.up)) + 3
        let reveal = max(0, min(1, (progress - Double(c) * 0.08) / 0.18))   // staggered, tied to real progress
        let e = 1 - pow(1 - reveal, 3)

        return ZStack(alignment: .top) {
            ForEach(Array(-1...count), id: \.self) { k in
                let kAbs = dir < 0 ? (k + cyc) : (k - cyc)
                tile(index: c * 7 + kAbs * 3, w: laneW, h: tileH)
                    .offset(y: y0 + CGFloat(k) * period)
            }
        }
        .frame(width: laneW, height: laneH, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .opacity(e)
        .offset(x: (1 - e) * (c == 0 ? -10 : (c == 2 ? 10 : 0)))   // gentle slide-in like the design
    }

    private func tile(index: Int, w: CGFloat, h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        return Group {
            if thumbnails.isEmpty {
                let pair = Self.foods[mod(index, Self.foods.count)]
                LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Image(uiImage: thumbnails[mod(index, thumbnails.count)]).resizable().scaledToFill()
            }
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        .overlay(alignment: .top) {                                 // subtle top highlight, matching the design
            LinearGradient(colors: [Color.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: h * 0.26)
        }
        .overlay(shape.stroke(Color.veCharcoal.opacity(0.05), lineWidth: 1))
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(VeFont.sans(12, weight: .semibold))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.veCharcoal.opacity(0.09))
                    Capsule()
                        .fill(LinearGradient(colors: [Color(hex: 0xE8B65E), accent],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * max(0, min(1, progress))))
                        .animation(.easeOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 3)
        }
    }

    /// Always-positive modulo so negative tile indices wrap cleanly.
    private func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }
}
