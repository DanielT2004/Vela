import SwiftUI

/// Pixel-exact reproductions of the Claude Design "Polish Editor" mockup icons — the SVG paths are
/// drawn in a 24×24 space and stroked, so they match the mockup exactly rather than approximating with
/// SF Symbols. Stroke colour defaults to the mockup's `#A89F90` (`veFaintGray`).
private func strokeSeg(_ ctx: GraphicsContext, _ pts: [(Double, Double)], _ w: Double, k: CGFloat,
                       color: Color, closed: Bool = false, cap: CGLineCap = .round, join: CGLineJoin = .round) {
    func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
    var path = Path(); path.move(to: p(pts[0].0, pts[0].1))
    for q in pts.dropFirst() { path.addLine(to: p(q.0, q.1)) }
    if closed { path.closeSubpath() }
    ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w * k, lineCap: cap, lineJoin: join))
}

private func strokeCircle(_ ctx: GraphicsContext, _ cx: Double, _ cy: Double, _ r: Double, _ w: Double,
                          k: CGFloat, color: Color) {
    let rect = CGRect(x: (cx - r) * k, y: (cy - r) * k, width: 2 * r * k, height: 2 * r * k)
    ctx.stroke(Path(ellipseIn: rect), with: .color(color), style: StrokeStyle(lineWidth: w * k))
}

/// The little icon on the left of each timeline track (Text / Main / B-roll / Audio).
struct TrackIcon: View {
    enum Kind { case text, main, broll, audio }
    let kind: Kind
    var color: Color = .veFaintGray
    var side: CGFloat = 12

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 24
            switch kind {
            case .text:                                   // a "T": top bar + stem
                strokeSeg(ctx, [(5, 6), (19, 6)], 2, k: k, color: color)
                strokeSeg(ctx, [(12, 6), (12, 19)], 2, k: k, color: color)
            case .main:                                   // a video frame: rounded rect + top divider
                ctx.stroke(Path(roundedRect: CGRect(x: 3 * k, y: 6 * k, width: 18 * k, height: 12 * k), cornerRadius: 2 * k),
                           with: .color(color), style: StrokeStyle(lineWidth: 1.8 * k))
                strokeSeg(ctx, [(3, 10), (21, 10)], 1.3, k: k, color: color, cap: .butt)
            case .broll:                                  // stacked layers (diamond)
                strokeSeg(ctx, [(12, 3), (21, 8), (12, 13), (3, 8)], 1.6, k: k, color: color, closed: true)
                strokeSeg(ctx, [(3, 13), (12, 18), (21, 13)], 1.6, k: k, color: color)
            case .audio:                                  // equalizer: 5 bars
                strokeSeg(ctx, [(4, 10), (4, 14)], 1.8, k: k, color: color)
                strokeSeg(ctx, [(8, 7), (8, 17)], 1.8, k: k, color: color)
                strokeSeg(ctx, [(12, 9), (12, 15)], 1.8, k: k, color: color)
                strokeSeg(ctx, [(16, 5), (16, 19)], 1.8, k: k, color: color)
                strokeSeg(ctx, [(20, 10), (20, 14)], 1.8, k: k, color: color)
            }
        }
        .frame(width: side, height: side)
    }
}

/// The Polish bottom-toolbar icons (Split / Trim / Speed / Volume / Delete).
struct ToolIcon: View {
    enum Kind { case split, trim, speed, volume, delete }
    let kind: Kind
    var color: Color
    var side: CGFloat = 22

    var body: some View {
        Canvas { ctx, size in
            let k = size.width / 24
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * k, y: y * k) }
            switch kind {
            case .split:                                  // scissors
                strokeCircle(ctx, 6, 6, 2.4, 1.7, k: k, color: color)
                strokeCircle(ctx, 6, 18, 2.4, 1.7, k: k, color: color)
                strokeSeg(ctx, [(8, 7), (19, 17)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(8, 17), (19, 7)], 1.7, k: k, color: color)
            case .trim:                                   // trim brackets
                strokeSeg(ctx, [(7, 4), (7, 20)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(17, 4), (17, 20)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(7, 8), (17, 8)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(7, 16), (17, 16)], 1.7, k: k, color: color)
            case .speed:                                  // clock
                strokeCircle(ctx, 12, 12, 8, 1.7, k: k, color: color)
                strokeSeg(ctx, [(12, 8), (12, 12), (15, 14)], 1.7, k: k, color: color)
            case .volume:                                 // speaker + one wave
                strokeSeg(ctx, [(11, 5), (6, 9), (3, 9), (3, 15), (6, 15), (11, 19)], 1.7, k: k, color: color, closed: true)
                var wave = Path(); wave.move(to: p(16, 9)); wave.addQuadCurve(to: p(16, 15), control: p(19.5, 12))
                ctx.stroke(wave, with: .color(color), style: StrokeStyle(lineWidth: 1.7 * k, lineCap: .round))
            case .delete:                                 // trash can
                strokeSeg(ctx, [(5, 7), (19, 7)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(10, 7), (10, 5), (14, 5), (14, 7)], 1.7, k: k, color: color)
                strokeSeg(ctx, [(6, 7), (7, 20), (17, 20), (18, 7)], 1.7, k: k, color: color)
            }
        }
        .frame(width: side, height: side)
    }
}
