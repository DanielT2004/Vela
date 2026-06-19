import Foundation
import Observation

/// One **video** render slot: a contiguous stretch of the assembled main timeline showing a single
/// source. Audio is handled separately (see `AudioPiece`) so each clip can carry its own volume.
/// Both the live preview (`PolishComposition`) and the final export (`EditPlanAssembler`) consume
/// these so the preview matches the saved video.
struct RenderSlot: Equatable {
    let baseStart: Double        // start on the assembled (scaled) main timeline (seconds)
    let duration: Double         // timeline length of this slot (after speed scaling)
    let videoSegId: Int          // segment supplying video (overlay source, or the base segment)
    let videoSourceStart: Double // proxy seconds where the video slice begins
    let videoSpeed: Double       // 1 = normal; >1 faster, <1 slower (base clips only; overlays = 1)
    let isOverlay: Bool          // true when a B-roll overlay covers this slot
}

/// One clip's audio on a layer, used to build the audio tracks + `AVMutableAudioMix`. The base spine
/// (the voice) and the overlay layer become two mixed tracks; volume is applied per clip.
struct AudioPiece: Equatable {
    let segId: Int
    let baseStart: Double        // timeline start (seconds)
    let timelineDuration: Double // length on the timeline (after speed)
    let sourceStart: Double      // proxy seconds where the source audio begins
    let sourceDuration: Double   // source seconds consumed (= timelineDuration * speed)
    let volume: Float            // 0…1
    let speed: Double            // 1 = normal
}

/// The single source of truth for an editing session. The analysis produces the immutable
/// `EditPlan`; this store holds all *editable* state layered on top.
///
/// The main spine (`order`) is a list of **clip instances** (`Clip`) — slices of source segments with
/// their own in/out, speed, and volume — so one source can appear more than once (split) and a clip
/// can carry an arbitrary in-point. B-roll is a real **second layer**: clips designated B-roll live in
/// `brollClips` (Layer 2 source pool) and are placed over the timeline as `brollLane` overlays that
/// supply silent video while the base audio keeps playing. `renderSlots()` turns the two layers into a
/// flat slot list that both the preview and the exporter render identically.
@Observable
final class EditPlanStore {
    let plan: EditPlan
    private let segmentsById: [Int: Segment]

    /// The **main spine** (Layer 1), in play order — each clip carries its own video + audio.
    /// (Seeded from `final_edit_order`, with food close-ups split off onto the B-roll layer.)
    var order: [Clip]
    /// IDs designated **B-roll** (Layer 2 source pool) — pulled off the spine, placed via `brollLane`.
    var brollClips: [Int]
    /// IDs the creator cut — never deleted, restorable from the Cut Tray.
    var cutTray: [Int]
    /// The chosen opening segment (always on the main spine).
    var hookId: Int?
    /// The overlay layer: B-roll placements over the assembled main timeline.
    var brollLane: [OverlayClip]
    /// Legacy voiceover→food map, kept only as an init-time seed hint (no live UI uses it now).
    var brollSource: [Int: Int]
    /// Reason-note ids the creator dismissed.
    var dismissed: Set<Int> = []

    init(plan: EditPlan) {
        self.plan = plan
        let byId: [Int: Segment] = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.segmentsById = byId
        func startOf(_ id: Int) -> Double { byId[id]?.startSeconds ?? 0 }
        func isFoodCloseup(_ id: Int) -> Bool { byId[id]?.sceneType == .foodCloseup }
        func clip(_ id: Int) -> Clip {
            let s = byId[id]
            return Clip(sourceSegmentId: id, inPoint: s?.startSeconds ?? 0,
                        outPoint: s?.trimToSeconds ?? s?.endSeconds ?? ((s?.startSeconds ?? 0) + 1))
        }

        // keep:true segments, ordered by final_edit_order, with any stragglers appended.
        let keepIds: [Int] = plan.segments.filter { $0.keep }.map(\.id)
        var ordered: [Int] = plan.finalEditOrder.filter { keepIds.contains($0) }
        for id in keepIds where !ordered.contains(id) { ordered.append(id) }
        let hook: Int? = ordered.first

        // Legacy default b-roll for each voiceover candidate = highest-hook food-closeup elsewhere.
        var broll: [Int: Int] = [:]
        let brollCandidates = plan.segments
            .filter { $0.sceneType == .foodCloseup }
            .sorted { $0.hookScore > $1.hookScore }
        for seg in plan.segments where seg.voiceoverCandidate {
            if let best = brollCandidates.first(where: { $0.id != seg.id }) { broll[seg.id] = best.id }
        }
        self.brollSource = broll

        // Split the spine: food close-ups become B-roll material (Layer 2), except the hook.
        let brollLayer: [Int] = ordered.filter { id in id != hook && isFoodCloseup(id) }
        self.order = ordered.filter { !brollLayer.contains($0) }.map(clip)
        self.brollClips = brollLayer.sorted { startOf($0) < startOf($1) }
        self.cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        self.hookId = hook
        self.brollLane = []
        // Auto-fill the overlay layer over the talking regions (needs the stored props above).
        self.brollLane = seededLane()
    }

    // MARK: - Persistence (save / resume)
    //
    // The on-disk `EditState` (schema v2) stores clip instances directly, so splits + per-instance in/out
    // survive save/resume. Old v1 saves are migrated forward on load (see `EditState.migrated`).

    /// Restore a saved session: seed from the plan, then overwrite editable state from the persisted
    /// `EditState`.
    convenience init(plan: EditPlan, restoring state: EditState) {
        self.init(plan: plan)
        order       = state.order
        brollClips  = state.brollClips
        cutTray     = state.cutTray
        hookId      = state.hookId
        brollLane   = state.brollLane
        brollSource = state.brollSource
        dismissed   = state.dismissed
    }

    /// A Codable snapshot of all editable state — the "edit" half of a saved project.
    func snapshot() -> EditState {
        EditState(order: order, brollClips: brollClips, cutTray: cutTray, hookId: hookId,
                  brollLane: brollLane, brollSource: brollSource, dismissed: dismissed)
    }

    // MARK: - Undo / redo

    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private let maxUndo = 60

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Capture the current state before a mutation — call ONCE per user action/gesture.
    func pushUndo() {
        undoStack.append(snapshot())
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(prev)
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    private func apply(_ s: EditState) {
        order = s.order; brollClips = s.brollClips; cutTray = s.cutTray; hookId = s.hookId
        brollLane = s.brollLane; brollSource = s.brollSource; dismissed = s.dismissed
    }

    // MARK: - Lookups

    func segment(_ id: Int) -> Segment? { segmentsById[id] }
    private func clipIndex(_ cid: UUID) -> Int? { order.firstIndex { $0.id == cid } }
    private func makeClip(_ id: Int) -> Clip {
        let s = segmentsById[id]
        return Clip(sourceSegmentId: id, inPoint: s?.startSeconds ?? 0,
                    outPoint: s?.trimToSeconds ?? s?.endSeconds ?? ((s?.startSeconds ?? 0) + 1))
    }

    private func rawStart(_ id: Int) -> Double { segmentsById[id]?.startSeconds ?? 0 }
    private func isFoodCloseup(_ id: Int) -> Bool { segmentsById[id]?.sceneType == .foodCloseup }

    /// All food-closeup segments — the broad pool of swappable b-roll sources.
    var brollOptions: [Segment] {
        plan.segments.filter { $0.sceneType == .foodCloseup }.sorted { $0.hookScore > $1.hookScore }
    }

    /// Full length of one B-roll **source** segment (used to clamp overlay durations). Keyed by
    /// segment id, since b-roll sources live in the pool, not on the spine.
    func sourceLength(_ id: Int) -> Double {
        guard let s = segmentsById[id] else { return 0 }
        return max(0.1, (s.trimToSeconds ?? s.endSeconds) - s.startSeconds)
    }

    /// Output length = the assembled main timeline (overlays sit within it).
    var totalDuration: Double { order.reduce(0) { $0 + $1.timelineDuration } }
    /// Length of the assembled main timeline (Layer 1) — the axis overlays are positioned along.
    var baseDuration: Double { totalDuration }

    /// Where a main-spine clip begins on the assembled (scaled) timeline.
    func baseStart(of cid: UUID) -> Double {
        var t = 0.0
        for c in order { if c.id == cid { return t }; t += c.timelineDuration }
        return t
    }

    func isHook(_ id: Int) -> Bool { hookId == id }
    func isBroll(_ id: Int) -> Bool { brollClips.contains(id) }
    func isDismissed(_ id: Int) -> Bool { dismissed.contains(id) }

    // MARK: - Bucket mutations (source moves between order / brollClips / cutTray)
    //
    // These take a *source segment id* (the unit Triage / B-roll picker work in) and add/remove the
    // corresponding clip instance(s).

    func keep(_ id: Int) {
        cutTray.removeAll { $0 == id }
        brollClips.removeAll { $0 == id }
        removeOverlays(of: id)
        if !order.contains(where: { $0.sourceSegmentId == id }) { order.append(makeClip(id)) }
    }

    /// Move a clip onto the B-roll layer (Layer 2). Its instance(s) leave the main spine.
    func markBroll(_ id: Int) {
        cutTray.removeAll { $0 == id }
        order.removeAll { $0.sourceSegmentId == id }
        if !brollClips.contains(id) { brollClips.append(id) }
        if hookId == id { hookId = order.first?.sourceSegmentId }
    }

    /// Move a B-roll clip back onto the main spine, optionally at a specific index. Returns the new
    /// clip's id (for selection), or nil if it was already on the spine.
    @discardableResult
    func unmarkBroll(_ id: Int, at index: Int? = nil) -> UUID? {
        brollClips.removeAll { $0 == id }
        removeOverlays(of: id)
        guard !order.contains(where: { $0.sourceSegmentId == id }) else { return nil }
        let clip = makeClip(id)
        if let index { order.insert(clip, at: max(0, min(index, order.count))) }
        else { order.append(clip) }
        return clip.id
    }

    func cut(_ id: Int) {
        order.removeAll { $0.sourceSegmentId == id }
        brollClips.removeAll { $0 == id }
        removeOverlays(of: id)
        if !cutTray.contains(id) { cutTray.append(id) }
        if hookId == id { hookId = order.first?.sourceSegmentId }
    }

    func setHook(_ id: Int) {
        // The hook always opens the main spine.
        cutTray.removeAll { $0 == id }
        brollClips.removeAll { $0 == id }
        removeOverlays(of: id)
        order.removeAll { $0.sourceSegmentId == id }
        order.insert(makeClip(id), at: 0)
        hookId = id
    }

    func restore(_ id: Int) {
        cutTray.removeAll { $0 == id }
        if !order.contains(where: { $0.sourceSegmentId == id }) && !brollClips.contains(id) {
            order.append(makeClip(id))
        }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Reorder a single clip instance to an absolute index (used by the timeline drag).
    func reorder(cid: UUID, to index: Int) {
        guard let cur = clipIndex(cid) else { return }
        let clip = order.remove(at: cur)
        order.insert(clip, at: max(0, min(index, order.count)))
    }

    /// Set a clip's effective source duration (end trim), clamped to the raw segment's real length.
    func setSourceDuration(_ cid: UUID, seconds: Double) {
        guard let i = clipIndex(cid), let s = segmentsById[order[i].sourceSegmentId] else { return }
        let maxLen = s.endSeconds - s.startSeconds
        let clamped = max(0.5, min(seconds, maxLen))
        order[i].outPoint = order[i].inPoint + clamped
    }

    /// Frame-accurate two-edge trim on a base clip, clamped to the segment's real source bounds. Unlike
    /// `setSourceDuration` these let the in-point move and can grow a clip back toward the AI's bounds.
    func setIn(_ cid: UUID, toSource newIn: Double) {
        guard let i = clipIndex(cid), let s = segmentsById[order[i].sourceSegmentId] else { return }
        let snapped = (newIn * 30).rounded() / 30
        order[i].inPoint = max(s.startSeconds, min(snapped, order[i].outPoint - 1.0 / 30))
    }
    func setOut(_ cid: UUID, toSource newOut: Double) {
        guard let i = clipIndex(cid), let s = segmentsById[order[i].sourceSegmentId] else { return }
        let snapped = (newOut * 30).rounded() / 30
        order[i].outPoint = min(s.endSeconds, max(snapped, order[i].inPoint + 1.0 / 30))
    }

    /// Remove a single clip instance from the spine (keeps the source available elsewhere).
    func deleteClip(_ cid: UUID) {
        guard let i = clipIndex(cid) else { return }
        let srcId = order[i].sourceSegmentId
        order.remove(at: i)
        if hookId == srcId && !order.contains(where: { $0.sourceSegmentId == srcId }) {
            hookId = order.first?.sourceSegmentId
        }
    }

    /// Split the clip under `timelineT` (assembled-timeline seconds) into two adjacent instances at the
    /// nearest frame. No-op within ~1 frame of an edge. Total timeline length is unchanged, so overlay
    /// positions are unaffected. Returns the right half's id (for selection).
    @discardableResult
    func split(at timelineT: Double) -> UUID? {
        var acc = 0.0
        for (i, c) in order.enumerated() {
            let end = acc + c.timelineDuration
            if timelineT < end {
                // timeline offset within the clip → source seconds (honoring speed), frame-snapped
                let cutSource = ((c.inPoint + (timelineT - acc) * c.clampedSpeed) * 30).rounded() / 30
                guard cutSource > c.inPoint + 1.0 / 30, cutSource < c.outPoint - 1.0 / 30 else { return nil }
                pushUndo()
                let left = Clip(sourceSegmentId: c.sourceSegmentId, inPoint: c.inPoint, outPoint: cutSource,
                                speed: c.speed, volume: c.volume)
                let right = Clip(sourceSegmentId: c.sourceSegmentId, inPoint: cutSource, outPoint: c.outPoint,
                                 speed: c.speed, volume: c.volume)
                order.replaceSubrange(i...i, with: [left, right])
                return right.id
            }
            acc = end
        }
        return nil
    }

    func swapBroll(_ voiceoverId: Int, to sourceId: Int) { brollSource[voiceoverId] = sourceId }

    func dismiss(_ id: Int) { dismissed.insert(id) }

    // MARK: - Speed / volume (per clip instance)

    func setSpeed(_ cid: UUID, _ value: Double) {
        guard let i = clipIndex(cid) else { return }
        order[i].speed = max(0.25, min(4, value))
    }
    func setClipVolume(_ cid: UUID, _ value: Float) {
        guard let i = clipIndex(cid) else { return }
        order[i].volume = max(0, min(1, value))
    }
    func setOverlayVolume(_ id: UUID, _ value: Float) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }) else { return }
        brollLane[i].volume = max(0, min(1, value))
    }

    // MARK: - Overlay-layer mutations

    /// Add a B-roll overlay from `sourceId`, starting at `start` seconds on the base timeline.
    func addOverlay(sourceId: Int, at start: Double) {
        guard segmentsById[sourceId] != nil else { return }
        let clampedStart = max(0, min(start, max(0, baseDuration - 0.5)))
        let dur = min(sourceLength(sourceId), max(0.5, baseDuration - clampedStart))
        brollLane.append(OverlayClip(sourceSegmentId: sourceId, startOnBase: clampedStart, duration: max(0.3, dur)))
    }

    func moveOverlay(_ id: UUID, toStart start: Double) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }) else { return }
        let dur = brollLane[i].duration
        brollLane[i].startOnBase = max(0, min(start, max(0, baseDuration - dur)))
    }

    func trimOverlay(_ id: UUID, duration: Double) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }) else { return }
        let o = brollLane[i]
        let maxDur = min(sourceLength(o.sourceSegmentId), baseDuration - o.startOnBase)
        brollLane[i].duration = max(0.3, min(duration, maxDur))
    }

    /// Set an overlay's `[start, end]` directly (used by edge-trim handles), clamped to a 0.3s
    /// minimum, the source length, and the base bounds.
    func setOverlayBounds(_ id: UUID, start: Double, end: Double) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }) else { return }
        let srcLen = sourceLength(brollLane[i].sourceSegmentId)
        var s = max(0, start)
        var e = min(baseDuration, end)
        if e - s > srcLen { e = s + srcLen }
        if e - s < 0.3 { e = min(baseDuration, s + 0.3); s = max(0, e - 0.3) }
        brollLane[i].startOnBase = s
        brollLane[i].duration = max(0.3, e - s)
    }

    func removeOverlay(_ id: UUID) { brollLane.removeAll { $0.id == id } }

    func swapOverlaySource(_ id: UUID, to sourceId: Int) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }), segmentsById[sourceId] != nil else { return }
        brollLane[i].sourceSegmentId = sourceId
        trimOverlay(id, duration: brollLane[i].duration)   // re-clamp to the new source length
    }

    private func removeOverlays(of segmentId: Int) {
        brollLane.removeAll { $0.sourceSegmentId == segmentId }
    }

    /// Auto-fill: lay one (distinct) B-roll clip over each talking / voiceover region of the spine —
    /// the "B-roll covers the talking" default, now visible and freely editable.
    private func seededLane() -> [OverlayClip] {
        let sources = brollClips.sorted { (segmentsById[$0]?.hookScore ?? 0) > (segmentsById[$1]?.hookScore ?? 0) }
        guard !sources.isEmpty else { return [] }
        var lane: [OverlayClip] = []
        var t = 0.0
        var si = 0
        for c in order {
            guard let s = segmentsById[c.sourceSegmentId] else { continue }
            let d = c.sourceDuration
            if s.voiceoverCandidate || s.sceneType == .talkingHead {
                let srcId = sources[si % sources.count]; si += 1
                lane.append(OverlayClip(sourceSegmentId: srcId, startOnBase: t,
                                        duration: max(0.5, min(d, sourceLength(srcId)))))
            }
            t += d
        }
        return lane
    }

    // MARK: - Render slots (shared by preview + export)

    /// Flatten the layers into contiguous **video** slots: video is the covering overlay's source
    /// where one exists, otherwise the base clip's own video (carrying that clip's speed). Audio is
    /// built separately via `baseAudioPieces()` / `overlayAudioPieces()`.
    func renderSlots() -> [RenderSlot] {
        struct Win { let segId: Int; let start: Double; let end: Double; let srcStart: Double; let speed: Double }
        var base: [Win] = []
        var t = 0.0
        for c in order {
            let sp = c.clampedSpeed
            let tl = c.timelineDuration
            base.append(Win(segId: c.sourceSegmentId, start: t, end: t + tl, srcStart: c.inPoint, speed: sp))
            t += tl
        }
        let total = t
        guard total > 0 else { return [] }

        let overlays = brollLane
            .filter { $0.duration > 0.04 && $0.startOnBase < total }
            .sorted { $0.startOnBase < $1.startOnBase }

        var bounds: Set<Double> = [0, total]
        for w in base { bounds.insert(w.start); bounds.insert(w.end) }
        for o in overlays {
            bounds.insert(max(0, o.startOnBase))
            bounds.insert(min(total, o.endOnBase))
        }
        let pts = bounds.filter { $0 >= 0 && $0 <= total }.sorted()

        var slots: [RenderSlot] = []
        for i in 0..<max(0, pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            guard b - a > 0.02 else { continue }
            let mid = (a + b) / 2
            guard let bw = base.first(where: { mid >= $0.start && mid < $0.end }) else { continue }

            if let o = overlays.first(where: { mid >= $0.startOnBase && mid < $0.endOnBase }),
               let src = segmentsById[o.sourceSegmentId] {
                slots.append(RenderSlot(baseStart: a, duration: b - a,
                                        videoSegId: o.sourceSegmentId,
                                        videoSourceStart: src.startSeconds + (a - o.startOnBase),
                                        videoSpeed: 1, isOverlay: true))
            } else {
                // Source advances `speed`× faster than the timeline within a sped base clip.
                slots.append(RenderSlot(baseStart: a, duration: b - a,
                                        videoSegId: bw.segId,
                                        videoSourceStart: bw.srcStart + (a - bw.start) * bw.speed,
                                        videoSpeed: bw.speed, isOverlay: false))
            }
        }
        return slots
    }

    /// Base-spine audio (the voice), one piece per main clip, in order — each at its own volume/speed.
    func baseAudioPieces() -> [AudioPiece] {
        var t = 0.0
        var out: [AudioPiece] = []
        for c in order {
            let srcDur = c.sourceDuration
            let tl = c.timelineDuration
            out.append(AudioPiece(segId: c.sourceSegmentId, baseStart: t, timelineDuration: tl,
                                  sourceStart: c.inPoint, sourceDuration: srcDur,
                                  volume: c.clampedVolume, speed: c.clampedSpeed))
            t += tl
        }
        return out
    }

    /// Overlay audio — only the overlays the creator un-muted (volume > 0).
    func overlayAudioPieces() -> [AudioPiece] {
        brollLane.compactMap { o in
            guard o.volume > 0.001, let s = segmentsById[o.sourceSegmentId] else { return nil }
            return AudioPiece(segId: o.sourceSegmentId, baseStart: o.startOnBase, timelineDuration: o.duration,
                              sourceStart: s.startSeconds, sourceDuration: o.duration, volume: o.volume, speed: 1)
        }
    }

    /// Reset the working edit to the AI's full recommendation — "Accept Vela's picks". Re-derives the
    /// spine, the B-roll layer, trims, and the auto-filled overlays. Everything stays reversible.
    func applyAISuggestions() {
        let keepIds = plan.segments.filter { $0.keep }.map(\.id)
        var ordered = plan.finalEditOrder.filter { keepIds.contains($0) }
        for id in keepIds where !ordered.contains(id) { ordered.append(id) }

        // Open with the AI's strongest hook among the kept clips.
        if let bestHook = plan.segments
            .filter({ keepIds.contains($0.id) })
            .max(by: { $0.hookScore < $1.hookScore }) {
            ordered.removeAll { $0 == bestHook.id }
            ordered.insert(bestHook.id, at: 0)
            hookId = bestHook.id
        } else {
            hookId = ordered.first
        }

        let currentHook = hookId
        let brollLayer: [Int] = ordered.filter { id in id != currentHook && isFoodCloseup(id) }
        order = ordered.filter { !brollLayer.contains($0) }.map(makeClip)
        brollClips = brollLayer.sorted { rawStart($0) < rawStart($1) }
        cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        brollLane = seededLane()
    }

    // MARK: - Derived display

    private var averageClip: Double { order.isEmpty ? 0 : totalDuration / Double(order.count) }

    var pacingText: String {
        averageClip < 3.5 ? "punchy pacing" : (averageClip < 6 ? "good pacing" : "relaxed pacing")
    }

    var hookText: String {
        if let h = hookId, order.contains(where: { $0.sourceSegmentId == h }) { return "strong hook" }
        return "no hook yet"
    }

    /// The live vibe meter, e.g. "28s · strong hook · good pacing".
    var vibeText: String {
        "\(Int(totalDuration.rounded()))s · \(hookText) · \(pacingText)"
    }
}
