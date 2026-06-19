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

    init(id: UUID = UUID(), sourceSegmentId: Int, inPoint: Double, outPoint: Double,
         speed: Double = 1, volume: Float = 1) {
        self.id = id
        self.sourceSegmentId = sourceSegmentId
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.speed = speed
        self.volume = volume
    }

    var clampedSpeed: Double { max(0.25, min(4, speed)) }
    var clampedVolume: Float { max(0, min(1, volume)) }
    /// Source seconds consumed (before speed scaling) — the old `duration(id)`.
    var sourceDuration: Double { max(0.1, outPoint - inPoint) }
    /// Length on the assembled timeline after speed scaling — the old `timelineDuration(id)`.
    var timelineDuration: Double { sourceDuration / clampedSpeed }
}
