import AVFoundation
import CoreGraphics

/// The ONE place the 9:16 reframe math lives, so the live preview ([PolishComposition](FoodEditor/Services/PolishComposition.swift))
/// and the final export ([EditPlanAssembler](FoodEditor/Assembly/EditPlanAssembler.swift)) can't drift —
/// what you see is what you get.
///
/// Aspect-FILLS a source (after its orientation `preferred` transform) into `renderSize`, center-cropped,
/// then applies an optional per-clip **crop**: zoom by `cropScale` (≥1) about the frame center and pan by
/// `(cropOffsetX, cropOffsetY)` as a fraction of `renderSize`. Because it's a pure ratio of
/// natural→renderSize, the same normalized crop frames identically at any resolution (720p proxy preview
/// vs 1080×1920 export). With `cropScale == 1` and zero offset it reproduces the plain aspect-fill exactly.
enum ReframeTransform {
    static func fill(natural: CGSize,
                     preferred: CGAffineTransform,
                     into renderSize: CGSize,
                     cropScale: Double = 1,
                     cropOffsetX: Double = 0,
                     cropOffsetY: Double = 0) -> CGAffineTransform {
        let displayRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let baseScale = max(renderSize.width / max(displaySize.width, 1),
                            renderSize.height / max(displaySize.height, 1))
        let scale = baseScale * CGFloat(max(1, cropScale))
        let scaledW = displaySize.width * scale
        let scaledH = displaySize.height * scale
        // center, then pan (+offset moves the visible content right / down within the frame)
        let tx = (renderSize.width  - scaledW) / 2 + CGFloat(cropOffsetX) * renderSize.width
        let ty = (renderSize.height - scaledH) / 2 + CGFloat(cropOffsetY) * renderSize.height

        // CoreGraphics `a.concatenating(b)` = apply a, then b: orientation → normalize origin →
        // scale (aspect-fill × crop zoom) → translate (center + pan).
        var t = preferred
        t = t.concatenating(CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return t
    }
}
