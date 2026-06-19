import Foundation

/// One placement of a B-roll clip on the overlay layer (Layer 2). It plays **over** the main spine
/// for `[startOnBase, startOnBase + duration]` (assembled main-timeline seconds), supplying only
/// VIDEO — the base track's audio (the creator's voice) keeps playing underneath.
///
/// This is the generalized form of the legacy `EditPlanStore.brollSource` map: instead of a B-roll
/// being locked 1:1 to a voiceover slot, it can sit anywhere on the timeline and be freely dragged,
/// trimmed, added, or removed on the Polish page. The same lane drives both the live preview
/// (`PolishComposition`) and the final export (`EditPlanAssembler`), so what you see is what you get.
struct OverlayClip: Identifiable, Equatable, Codable {
    let id: UUID
    /// The B-roll source segment (∈ `EditPlanStore.brollClips`) whose video fills this window.
    var sourceSegmentId: Int
    /// Where the overlay begins along the assembled main timeline, in seconds.
    var startOnBase: Double
    /// How long it covers, in seconds. Clamped ≤ the source segment's length, so each window maps to
    /// a single contiguous source slice (no looping needed).
    var duration: Double
    /// Overlay audio volume, 0…1. Defaults to **0** (muted) — B-roll plays silently over the voice;
    /// raise it to mix the B-roll's own sound in.
    var volume: Float

    init(id: UUID = UUID(), sourceSegmentId: Int, startOnBase: Double, duration: Double, volume: Float = 0) {
        self.id = id
        self.sourceSegmentId = sourceSegmentId
        self.startOnBase = startOnBase
        self.duration = duration
        self.volume = volume
    }

    /// Exclusive end on the assembled main timeline.
    var endOnBase: Double { startOnBase + duration }
}
