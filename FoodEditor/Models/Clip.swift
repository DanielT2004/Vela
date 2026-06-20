import Foundation

/// One **clip instance** on the main spine: a slice of a source segment with its own in/out points,
/// speed, and volume. Replacing the old "segment id is the atomic unit" model with instances is what
/// makes precise cutting possible — splitting a clip yields two instances of the same source, and a
/// clip can carry an arbitrary in-point (not just an end trim).
///
/// `inPoint`/`outPoint` are **absolute proxy seconds** — the same coordinate space as
/// `Segment.startSeconds` and `SourceSpan.startInMerged` — so the proxy→original export mapping needs
/// no translation. In M2 every clip's `inPoint` still equals its segment's `startSeconds` (behaviour is
/// unchanged); M3 adds split + two-edge trim that move it.
struct Clip: Identifiable, Equatable, Codable {
    let id: UUID
    let sourceSegmentId: Int
    var inPoint: Double            // absolute proxy seconds
    var outPoint: Double           // absolute proxy seconds; invariant: inPoint < outPoint
    var speed: Double              // 1 = normal; >1 faster, <1 slower
    var volume: Float              // 0…1
    // v3 — per-clip 9:16 reframe. cropScale 1 = aspect-fill baseline; offsets are a fraction of the frame.
    var cropScale: Double
    var cropOffsetX: Double
    var cropOffsetY: Double

    init(id: UUID = UUID(), sourceSegmentId: Int, inPoint: Double, outPoint: Double,
         speed: Double = 1, volume: Float = 1,
         cropScale: Double = 1, cropOffsetX: Double = 0, cropOffsetY: Double = 0) {
        self.id = id
        self.sourceSegmentId = sourceSegmentId
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.speed = speed
        self.volume = volume
        self.cropScale = cropScale
        self.cropOffsetX = cropOffsetX
        self.cropOffsetY = cropOffsetY
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceSegmentId, inPoint, outPoint, speed, volume, cropScale, cropOffsetX, cropOffsetY
    }

    /// Lenient decode so v2 saves (without crop keys) still open — crop defaults to the aspect-fill baseline.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceSegmentId = try c.decode(Int.self, forKey: .sourceSegmentId)
        inPoint = try c.decode(Double.self, forKey: .inPoint)
        outPoint = try c.decode(Double.self, forKey: .outPoint)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        cropScale = try c.decodeIfPresent(Double.self, forKey: .cropScale) ?? 1
        cropOffsetX = try c.decodeIfPresent(Double.self, forKey: .cropOffsetX) ?? 0
        cropOffsetY = try c.decodeIfPresent(Double.self, forKey: .cropOffsetY) ?? 0
    }

    var clampedSpeed: Double { max(0.25, min(4, speed)) }
    var clampedVolume: Float { max(0, min(1, volume)) }
    /// Source seconds consumed (before speed scaling) — the old `duration(id)`.
    var sourceDuration: Double { max(0.1, outPoint - inPoint) }
    /// Length on the assembled timeline after speed scaling — the old `timelineDuration(id)`.
    var timelineDuration: Double { sourceDuration / clampedSpeed }
}
