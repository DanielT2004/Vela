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
    // Per-clip 9:16 reframe (base clips only; overlays keep the default fill). 1 = aspect-fill baseline.
    var cropScale: Double = 1
    var cropOffsetX: Double = 0
    var cropOffsetY: Double = 0
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

/// A cleaned-voice audio file (from ElevenLabs Voice Isolator) mapped to a **proxy-time** range. The
/// editor addresses all base audio in proxy seconds (`AudioPiece.sourceStart`), so keying cleaned audio
/// the same way means cuts/splits/reorders/trims re-slice it automatically — no drift. `url`'s local
/// time 0 corresponds to `startProxy`. See `baseAudioPieces()` consumers in `PolishComposition` /
/// `EditPlanAssembler`, which swap to this file wherever a span fully covers a piece.
struct IsolatedAudioSpan: Equatable {
    let startProxy: Double   // proxy seconds where this cleaned audio begins
    let endProxy: Double     // proxy seconds where it ends
    let url: URL             // cleaned MP3; local time 0 == startProxy
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
    /// Segment lookup. Seeded from the immutable plan; imported (post-analysis) clips register synthetic
    /// segments here too, so every downstream lookup resolves them (`appendImportedSegments`).
    private(set) var segmentsById: [Int: Segment]

    /// Target fraction (0…1) of the final timeline to auto-cover with seeded B-roll — from the chosen
    /// style template (default 25%). A safety cap on seeding; Gemini also gets this target via the style
    /// block, so the prompt and the cap agree.
    private let brollCoverageTarget: Double

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
    /// Layer "Text": burned-in captions over the assembled timeline (preview + export).
    var textOverlays: [TextOverlay] = []

    /// Voice Isolation (Polish page): cleaned-voice files keyed by proxy-time range. Empty until the
    /// creator runs isolation. Session-only — the MP3s live in `temporaryDirectory` and are NOT
    /// persisted to `EditState`, so a resumed project starts un-isolated.
    var isolatedAudio: [IsolatedAudioSpan] = []
    /// Master Original ↔ Cleaned toggle. When true, base pieces fully covered by an `isolatedAudio`
    /// span read the cleaned file instead of the source; uncovered pieces still play the original.
    var useIsolatedAudio: Bool = false

    init(plan: EditPlan, brollCoverageTarget: Double = 0.25, openerCount: Int = 0) {
        self.plan = plan
        self.brollCoverageTarget = max(0, min(1, brollCoverageTarget))
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
        // COLD OPEN + section invariant. The first `openerCount` segments are the creator's chosen
        // opener (Gemini was told to place them at the top of final_edit_order): PIN them to the very
        // front — they play before the intro even if they're a mid-meal shot. The REST is stable-sorted
        // intro → middle → end so the body still flows in order. A STABLE sort keeps the model's
        // within-section order, so it only moves a mis-placed clip into its group. openerCount == 0 →
        // everything is section-sorted (Gemini's hook, an intro segment, leads naturally).
        func sectionRank(_ id: Int) -> Int {
            switch byId[id]?.section ?? .unknown {
            case .intro: return 0; case .middle: return 1; case .end: return 2; case .unknown: return 3
            }
        }
        let pinCount = min(max(0, openerCount), ordered.count)
        let pinned = Array(ordered.prefix(pinCount))
        let sortedRest = ordered.dropFirst(pinCount).enumerated()
            .sorted { a, b in
                let ra = sectionRank(a.element), rb = sectionRank(b.element)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
        // CONTENT SECTIONS — pull same-`topic` clips (a dish, the verdict, …) into contiguous sections
        // so the spine reads section-by-section. Sections order by upload appearance; the intro lead
        // (`sortedRest.first`) stays the hook and keeps its section first. A plan with <2 topics is
        // returned unchanged, so this preserves the section-sorted order above. See `TopicGrouping`.
        let groupedRest = TopicGrouping.groupedOrder(sortedRest, segmentsById: byId, leadId: sortedRest.first)
        ordered = pinned + groupedRest
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
        // Group the B-roll pool by content section too (start-sorted, then grouped) so it reads
        // section-by-section like the spine.
        self.brollClips = TopicGrouping.groupedOrder(brollLayer.sorted { startOf($0) < startOf($1) },
                                                     segmentsById: byId)
        self.cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        self.hookId = hook
        self.brollLane = []
        // Auto-fill the overlay layer from Gemini's suggested placements (needs the stored props above).
        self.brollLane = seededLane(fromPlacements: plan.brollPlacements)
    }

    // MARK: - Persistence (save / resume)
    //
    // The on-disk `EditState` (schema v2) stores clip instances directly, so splits + per-instance in/out
    // survive save/resume. Old v1 saves are migrated forward on load (see `EditState.migrated`).

    /// Restore a saved session: seed from the plan, then overwrite editable state from the persisted
    /// `EditState`.
    convenience init(plan: EditPlan, restoring state: EditState) {
        self.init(plan: plan)
        order        = state.order
        brollClips   = state.brollClips
        cutTray      = state.cutTray
        hookId       = state.hookId
        brollLane    = state.brollLane
        brollSource  = state.brollSource
        dismissed    = state.dismissed
        textOverlays = state.textOverlays
    }

    /// A Codable snapshot of all editable state — the "edit" half of a saved project.
    func snapshot() -> EditState {
        EditState(order: order, brollClips: brollClips, cutTray: cutTray, hookId: hookId,
                  brollLane: brollLane, brollSource: brollSource, dismissed: dismissed,
                  textOverlays: textOverlays)
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
        textOverlays = s.textOverlays
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

    // MARK: - B-roll lane ripple (keep overlays anchored to the spine across edits)
    //
    // Overlays store an ABSOLUTE base-timeline second (`startOnBase`). When a spine edit moves/removes a
    // clip, those positions go stale and overlays dangle past the new end. To make B-roll *follow the
    // content*, we anchor each overlay to the spine clip it sits over (clip id + offset into that clip),
    // run the edit, then re-derive `startOnBase` from the anchor clip's new position — dropping any overlay
    // whose anchor clip was removed (ripple-delete). Wrap any spine mutation in `withRippledLane`.

    private struct LaneAnchor { let clipId: UUID; let offset: Double }

    /// Like `baseStart(of:)` but `nil` when the clip is no longer on the spine.
    private func baseStartIfPresent(_ cid: UUID) -> Double? {
        var t = 0.0
        for c in order { if c.id == cid { return t }; t += c.timelineDuration }
        return nil
    }

    /// Anchor every overlay to the spine clip it currently sits over (+ offset into that clip).
    private func captureLaneAnchors() -> [UUID: LaneAnchor] {
        var spans: [(id: UUID, start: Double, end: Double)] = []
        var t = 0.0
        for c in order { let d = c.timelineDuration; spans.append((c.id, t, t + d)); t += d }
        var anchors: [UUID: LaneAnchor] = [:]
        for o in brollLane {
            if let s = spans.first(where: { o.startOnBase >= $0.start && o.startOnBase < $0.end }) {
                anchors[o.id] = LaneAnchor(clipId: s.id, offset: o.startOnBase - s.start)
            } else if let last = spans.last, o.startOnBase >= last.end {
                anchors[o.id] = LaneAnchor(clipId: last.id, offset: last.end - last.start)   // sits at the end
            }
            // else: starts before the first clip (shouldn't happen) → leave unanchored; kept + clamped below.
        }
        return anchors
    }

    /// Re-derive overlay positions from their anchors after a spine edit, then clamp into
    /// `[0, baseDuration]` (same bounds as `moveOverlay`/`trimOverlay`). Overlays whose anchor clip is
    /// gone (the clip was cut or turned into B-roll) are NOT dropped — they keep their spot and just get
    /// clamped in-bounds, so B-roll is never lost. (Only a fully empty spine clears the lane — overlays
    /// have nothing to sit on.)
    private func reapplyLaneAnchors(_ anchors: [UUID: LaneAnchor]) {
        let total = baseDuration
        guard total > 0 else { brollLane.removeAll(); return }
        brollLane = brollLane.map { o in
            var c = o
            if let a = anchors[o.id], let newStart = baseStartIfPresent(a.clipId) {
                c.startOnBase = newStart + a.offset                     // anchor clip survived → ripple with it
            }
            // else: anchor clip removed → keep the overlay where it is, clamped below (never dropped).
            c.startOnBase = max(0, min(c.startOnBase, max(0, total - 0.3)))
            c.duration = max(0.3, min(c.duration, total - c.startOnBase))
            return c
        }
    }

    /// Run a spine mutation while keeping the B-roll lane anchored to the content (ripple).
    private func withRippledLane(_ mutate: () -> Void) {
        let anchors = captureLaneAnchors()
        mutate()
        reapplyLaneAnchors(anchors)
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

    // MARK: - Imported clips (post-analysis append, no Gemini)

    /// Next free segment id — synthetic imported segments take ids above every existing one.
    var nextSegmentId: Int { (segmentsById.keys.max() ?? -1) + 1 }

    /// Every registered segment (plan + imported) — used by the UI to build thumbnails for all clips.
    var allSegments: [Segment] { Array(segmentsById.values) }

    /// Append imported clips to the END of the main spine, preserving all existing edits. Each synthetic
    /// segment is registered for lookup, then a fresh spine clip is appended in pick order. Appending at
    /// the end can't move existing overlays, so no ripple is needed. Caller pushes undo first.
    func appendImportedSegments(_ segs: [Segment]) {
        guard !segs.isEmpty else { return }
        for s in segs { segmentsById[s.id] = s }       // register for makeClip / renderSlots / sourceLength
        for s in segs { order.append(makeClip(s.id)) } // append to the spine in pick order
    }

    /// Move a clip onto the B-roll layer (Layer 2). Its instance(s) leave the main spine.
    func markBroll(_ id: Int) {
        withRippledLane {
            cutTray.removeAll { $0 == id }
            order.removeAll { $0.sourceSegmentId == id }
            if !brollClips.contains(id) { brollClips.append(id) }
            if hookId == id { hookId = order.first?.sourceSegmentId }
        }
    }

    /// Move a B-roll clip back onto the main spine, optionally at a specific index. Returns the new
    /// clip's id (for selection), or nil if it was already on the spine.
    @discardableResult
    func unmarkBroll(_ id: Int, at index: Int? = nil) -> UUID? {
        var newId: UUID?
        // Ripple: inserting onto the spine lengthens it, so keep the surviving overlays anchored to their
        // content (the source's own overlays are removed here as it rejoins the spine).
        withRippledLane {
            brollClips.removeAll { $0 == id }
            removeOverlays(of: id)
            guard !order.contains(where: { $0.sourceSegmentId == id }) else { return }
            let clip = makeClip(id)
            if let index { order.insert(clip, at: max(0, min(index, order.count))) }
            else { order.append(clip) }
            newId = clip.id
        }
        return newId
    }

    func cut(_ id: Int) {
        withRippledLane {
            order.removeAll { $0.sourceSegmentId == id }
            brollClips.removeAll { $0 == id }
            removeOverlays(of: id)
            // Stack semantics: most-recently-cut clip sits on top of the Cut Tray.
            if !cutTray.contains(id) { cutTray.insert(id, at: 0) }
            if hookId == id { hookId = order.first?.sourceSegmentId }
        }
    }

    func setHook(_ id: Int) {
        // The hook always opens the main spine.
        withRippledLane {
            cutTray.removeAll { $0 == id }
            brollClips.removeAll { $0 == id }
            removeOverlays(of: id)
            order.removeAll { $0.sourceSegmentId == id }
            order.insert(makeClip(id), at: 0)
            hookId = id
        }
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
        guard clipIndex(cid) != nil else { return }
        withRippledLane {
            guard let i = clipIndex(cid) else { return }
            let srcId = order[i].sourceSegmentId
            order.remove(at: i)
            if hookId == srcId && !order.contains(where: { $0.sourceSegmentId == srcId }) {
                hookId = order.first?.sourceSegmentId
            }
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

    // MARK: - Per-clip crop (9:16 reframe)

    /// Set a Main clip's zoom + pan, clamping scale to 1…4 and the pan so the zoomed content can't pull
    /// past the frame edges (max offset = (scale−1)/2 of the frame on each axis).
    func setCrop(_ cid: UUID, scale: Double, offsetX: Double, offsetY: Double) {
        guard let i = clipIndex(cid) else { return }
        let s = max(1, min(scale, 4))
        let m = Self.maxOffset(forScale: s)
        order[i].cropScale = s
        order[i].cropOffsetX = max(-m, min(offsetX, m))
        order[i].cropOffsetY = max(-m, min(offsetY, m))
    }
    /// At scale `s` the content overhangs the frame by (s−1)/2 on each side — the max pannable offset.
    static func maxOffset(forScale s: Double) -> Double { max(0, (s - 1) / 2) }

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

    // MARK: - Text-overlay mutations (Layer "Text")

    /// Add a caption starting at `start` (assembled-timeline seconds), default ~2.5s long. Returns its id.
    @discardableResult
    func addTextOverlay(at start: Double) -> UUID {
        let s = max(0, min(start, max(0, baseDuration - 0.5)))
        let end = min(max(s + 0.5, baseDuration), s + 2.5)
        let overlay = TextOverlay(startTime: s, endTime: max(s + 0.5, end))
        textOverlays.append(overlay)
        return overlay.id
    }

    /// Mutate one overlay in place (font / color / size / string / position …).
    func updateTextOverlay(_ id: UUID, _ mutate: (inout TextOverlay) -> Void) {
        guard let i = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        mutate(&textOverlays[i])
    }

    /// Set a caption's `[start, end]` (edge-trim), clamped to a 0.3s minimum and the base bounds.
    func setTextBounds(_ id: UUID, start: Double, end: Double) {
        guard let i = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let s = max(0, min(start, max(0, baseDuration - 0.3)))
        textOverlays[i].startTime = s
        textOverlays[i].endTime = max(s + 0.3, min(end, baseDuration))
    }

    /// Move a caption to a new start, preserving its duration (clamped to the base bounds).
    func moveTextOverlay(_ id: UUID, toStart start: Double) {
        guard let i = textOverlays.firstIndex(where: { $0.id == id }) else { return }
        let dur = textOverlays[i].duration
        let s = max(0, min(start, max(0, baseDuration - dur)))
        textOverlays[i].startTime = s
        textOverlays[i].endTime = s + dur
    }

    func deleteTextOverlay(_ id: UUID) { textOverlays.removeAll { $0.id == id } }

    /// Auto-fill the overlay lane from Gemini's `broll_placements` — each anchored to a spine segment +
    /// offset (NOT timeline seconds; the spine doesn't exist until now). Sparse, contextual, varied: the
    /// old cover-everything heuristic is gone. Entries are validated and clamped; if none map (or Gemini
    /// suggested none), the lane stays empty and the creator places B-roll by hand on the Polish page.
    ///
    /// Why this is exact at seed time: every fresh spine clip has `speed == 1`, so a placement's
    /// proxy-second offset equals a timeline-second offset → `startOnBase = baseStart(clip) + offset`.
    /// Later spine edits keep these anchored via the ripple system, like any hand-placed overlay.
    private func seededLane(fromPlacements placements: [BrollPlacement]) -> [OverlayClip] {
        let total = baseDuration
        guard total > 0, !placements.isEmpty else { return [] }

        // The over-segment (the talking clip we cover) must be live on the spine. The B-roll source can be
        // any kept, visual (non-talking-head) segment — the food-closeup pool, but also a plating/pour or
        // other food shot Gemini judged the best match — as long as it isn't the over-segment itself.
        var spineClipBySeg: [Int: Clip] = [:]
        for c in order where spineClipBySeg[c.sourceSegmentId] == nil { spineClipBySeg[c.sourceSegmentId] = c }

        let coverageCap = brollCoverageTarget * total
        var lane: [OverlayClip] = []
        var covered = 0.0

        for p in placements {
            guard let clip = spineClipBySeg[p.overSegmentId] else { continue }   // over-seg not on spine
            guard let src = segmentsById[p.brollSegmentId], src.keep,            // source exists & is kept…
                  p.brollSegmentId != p.overSegmentId,                          // …a different clip…
                  src.sceneType != .talkingHead else { continue }               // …and a visual, not a face
            let srcLen = sourceLength(p.brollSegmentId)
            let segStart = baseStart(of: clip.id)
            let segEnd = segStart + clip.timelineDuration

            // Begin at the requested offset, clamped to sit inside the over-clip's window.
            let offset = max(0, min(p.startOffsetSeconds, max(0, clip.timelineDuration - 0.3)))
            var start = segStart + offset
            var dur = min(p.durationSeconds, srcLen, segEnd - start, total - start)

            // Never overlap an already-placed overlay: walk existing entries low→high and push past them.
            for o in lane.sorted(by: { $0.startOnBase < $1.startOnBase })
            where start < o.endOnBase && o.startOnBase < start + dur {
                start = o.endOnBase
                dur = min(p.durationSeconds, srcLen, segEnd - start, total - start)
            }

            guard dur >= 0.3 else { continue }                                   // too short / pushed out
            guard covered + dur <= coverageCap else { continue }                 // template coverage cap
            lane.append(OverlayClip(sourceSegmentId: p.brollSegmentId, startOnBase: start, duration: dur))
            covered += dur
        }
        return lane.sorted { $0.startOnBase < $1.startOnBase }
    }

    // MARK: - Render slots (shared by preview + export)

    /// Flatten the layers into contiguous **video** slots: video is the covering overlay's source
    /// where one exists, otherwise the base clip's own video (carrying that clip's speed). Audio is
    /// built separately via `baseAudioPieces()` / `overlayAudioPieces()`.
    func renderSlots() -> [RenderSlot] {
        struct Win { let segId: Int; let start: Double; let end: Double; let srcStart: Double; let speed: Double
                     let cropScale: Double; let cropOffsetX: Double; let cropOffsetY: Double }
        var base: [Win] = []
        var t = 0.0
        for c in order {
            let sp = c.clampedSpeed
            let tl = c.timelineDuration
            base.append(Win(segId: c.sourceSegmentId, start: t, end: t + tl, srcStart: c.inPoint, speed: sp,
                            cropScale: c.cropScale, cropOffsetX: c.cropOffsetX, cropOffsetY: c.cropOffsetY))
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
                                        videoSpeed: bw.speed, isOverlay: false,
                                        cropScale: bw.cropScale, cropOffsetX: bw.cropOffsetX, cropOffsetY: bw.cropOffsetY))
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

    /// The cleaned-voice span (if any) that **fully covers** a base piece's source range — used by the
    /// audio builders to swap in the isolated file. Returns `nil` when isolation is off or no span fully
    /// covers `[sourceStart, sourceStart + duration]` (partial coverage falls back to the original).
    func isolatedSpan(forSourceStart sourceStart: Double, duration: Double) -> IsolatedAudioSpan? {
        guard useIsolatedAudio else { return nil }
        let end = sourceStart + duration
        return isolatedAudio.first { $0.startProxy <= sourceStart + 0.01 && $0.endProxy >= end - 0.01 }
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

        // Pull same-`topic` clips into contiguous content sections (hook's section stays first). A plan
        // with <2 topics is returned unchanged, preserving the hook-first order above.
        ordered = TopicGrouping.groupedOrder(ordered, segmentsById: segmentsById, leadId: hookId)

        let currentHook = hookId
        let brollLayer: [Int] = ordered.filter { id in id != currentHook && isFoodCloseup(id) }
        order = ordered.filter { !brollLayer.contains($0) }.map(makeClip)
        brollClips = TopicGrouping.groupedOrder(brollLayer.sorted { rawStart($0) < rawStart($1) },
                                                segmentsById: segmentsById)
        cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        brollLane = seededLane(fromPlacements: plan.brollPlacements)

        // Keep imported (post-analysis) clips: they aren't in `plan.segments`, so re-append them to the
        // end of the spine rather than silently dropping them when resetting to the AI's picks.
        let planIds = Set(plan.segments.map(\.id))
        for id in segmentsById.keys.filter({ !planIds.contains($0) }).sorted()
        where !order.contains(where: { $0.sourceSegmentId == id }) {
            order.append(makeClip(id))
        }
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
