import AVFoundation
import UIKit

/// Burns a `TextOverlay` into a `CALayer` for the export's `AVVideoCompositionCoreAnimationTool`.
///
/// The geometry mirrors `PolishView`'s SwiftUI preview overlay EXACTLY so what you see is what you get:
/// the caption is authored in normalized 9:16 space (center as a fraction, point size as a fraction of
/// frame height), so the same overlay maps onto the 720p preview and the 1080×1920 export. The only
/// differences here are CoreAnimation's bottom-left origin (Y is flipped) and rotation sense (negated).
enum TextOverlayRenderer {

    /// A CALayer showing the caption, gated to its `[startTime, endTime]` via opacity animations.
    static func layer(for o: TextOverlay, renderSize: CGSize) -> CALayer? {
        guard let img = image(for: o, renderSize: renderSize), let cg = img.cgImage else { return nil }
        let layer = CALayer()
        layer.contents = cg
        layer.contentsScale = img.scale
        let w = img.size.width, h = img.size.height
        let cx = CGFloat(o.centerX) * renderSize.width
        let cyBottom = renderSize.height - CGFloat(o.centerY) * renderSize.height   // flip Y (origin bottom-left)
        layer.frame = CGRect(x: cx - w / 2, y: cyBottom - h / 2, width: w, height: h)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(o.rotation)))  // negate for CoreAnimation

        // Hidden until startTime, shown through endTime. beginTime 0 is illegal → clamp to the AV epsilon.
        layer.opacity = 0
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0; appear.toValue = 1
        appear.beginTime = max(o.startTime, AVCoreAnimationBeginTimeAtZero)
        appear.duration = 0.05; appear.fillMode = .forwards; appear.isRemovedOnCompletion = false
        layer.add(appear, forKey: "appear")

        let disappear = CABasicAnimation(keyPath: "opacity")
        disappear.fromValue = 1; disappear.toValue = 0
        disappear.beginTime = max(o.endTime, AVCoreAnimationBeginTimeAtZero)
        disappear.duration = 0.05; disappear.fillMode = .forwards; disappear.isRemovedOnCompletion = false
        layer.add(disappear, forKey: "disappear")
        return layer
    }

    /// Render the styled caption to an image at export resolution (scale 1 — `renderSize` is already in
    /// target pixels). Matches the preview's font / color / alignment / background pill / outline.
    static func image(for o: TextOverlay, renderSize: CGSize) -> UIImage? {
        let text = o.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let pt = CGFloat(o.fontSize) * renderSize.height
        let font = o.font.uiFont(size: pt, weight: o.weight)
        let para = NSMutableParagraphStyle()
        para.alignment = o.alignment.nsTextAlignment
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: o.color.ui, .paragraphStyle: para]

        let ns = o.string as NSString
        let maxW = renderSize.width * 0.92
        let bounding = ns.boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
        let textSize = CGSize(width: ceil(bounding.width), height: ceil(bounding.height))

        let bgPadX = o.background ? pt * 0.42 : 0
        let bgPadY = o.background ? pt * 0.2 : 0
        let shadowRadius: CGFloat = o.outline ? pt * 0.07 : pt * 0.045
        let pad = ceil(shadowRadius * 2 + 6)
        let imgSize = CGSize(width: textSize.width + bgPadX * 2 + pad * 2,
                             height: textSize.height + bgPadY * 2 + pad * 2)

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1; fmt.opaque = false
        let renderer = UIGraphicsImageRenderer(size: imgSize, format: fmt)
        return renderer.image { rctx in
            let ctx = rctx.cgContext
            let textRect = CGRect(x: pad + bgPadX, y: pad + bgPadY, width: textSize.width, height: textSize.height)
            if o.background {
                let pill = textRect.insetBy(dx: -bgPadX, dy: -bgPadY)
                UIColor.black.withAlphaComponent(0.42).setFill()
                UIBezierPath(roundedRect: pill, cornerRadius: pt * 0.3).fill()
            }
            ctx.setShadow(offset: CGSize(width: 0, height: o.outline ? 0 : 1), blur: shadowRadius,
                          color: UIColor.black.withAlphaComponent(o.outline ? 0.8 : 0.3).cgColor)
            ns.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs, context: nil)
        }
    }
}
