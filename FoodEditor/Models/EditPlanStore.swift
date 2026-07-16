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
    let brollCoverageTarget: Double   // read by RetentionRead for the override-aware shortfall note

    /// When true (the two-call PERCEIVE→DECIDE pipeline), DECIDE owns the spine: `final_edit_order` is used as
    /// the spine EXACTLY — no food-closeup extraction, and kept-but-unordered shots (b-roll sources) go to the
    /// pool, NOT the spine. The monolith path keeps the legacy extraction. Set once in `init`.
    private let spineIsVerbatim: Bool

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

    /// Layer "Voiceover": narration takes recorded over the assembled timeline (preview + export).
    /// Timeline-anchored (spine edits don't ripple them) and overlap-free by construction.
    var narrationLane: [NarrationClip] = []
    /// Vestigial v1-duck fields, kept ONLY so older v4 saves decode (no live reads or writes).
    var originalAudioGain: Float = 1
    var lastNonZeroGain: Float = 1
    /// "Under voiceover" duck level: how loud the original bed (base clips + audible B-roll) stays
    /// while a take is playing. A mix-time envelope (`AudioDucking`) scoped to the takes — moving or
    /// deleting a take re-scopes it automatically; clip volumes are never written.
    var voDuckLevel: Float = 0.2
    /// CapCut-style track mute for ALL original footage audio (the gutter speaker at the Main lane).
    /// A non-destructive flag applied at mix time — per-clip volumes are untouched, so unmuting always
    /// returns the exact previous mix, across undo and relaunch alike.
    var originalAudioMuted: Bool = false
    /// First-take toast already shown for this project (see `noteFirstTake`).
    var didAutoDuck: Bool = false
    /// Where this project's narration files live (`Projects/<id>/narration/`). NOT persisted — set by
    /// `ProjectService` on resume / by the Polish page before the first take; `NarrationClip.fileName`s
    /// resolve against it.
    var narrationDirectory: URL?
    /// Takes dropped on resume because their file vanished — the Polish page shows a one-shot toast
    /// and resets this. Transient, never persisted.
    var prunedNarrationOnResume: Int = 0

    init(plan: EditPlan, brollCoverageTarget: Double = 0.25, spineIsVerbatim: Bool = false) {
        self.plan = plan
        self.brollCoverageTarget = max(0, min(1, brollCoverageTarget))
        self.spineIsVerbatim = spineIsVerbatim
        let byId: [Int: Segment] = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.segmentsById = byId
        func startOf(_ id: Int) -> Double { byId[id]?.startSeconds ?? 0 }
        func isFoodCloseup(_ id: Int) -> Bool { byId[id]?.sceneType == .foodCloseup }
        func clip(_ id: Int) -> Clip {
            let s = byId[id]
            return Clip(sourceSegmentId: id, inPoint: s?.startSeconds ?? 0,
                        outPoint: s?.trimToSeconds ?? s?.endSeconds ?? ((s?.startSeconds ?? 0) + 1))
        }

        // keep:true segments in the AI's final_edit_order, with any stragglers appended. We use the order
        // VERBATIM — the AI owns the narrative sequence (cold-open → intro → tasting → verdict); code no
        // longer re-sorts it (that section/topic re-sort is what scrambled the dishes + stranded the
        // verdict after another dish). Code only ASSERTS: warn if the AI buried the intro, never re-order.
        let keepIds: [Int] = plan.segments.filter { $0.keep }.map(\.id)
        let orderedKept: [Int] = plan.finalEditOrder.filter { keepIds.contains($0) }
        let sources: [Int] = keepIds.filter { !orderedKept.contains($0) }   // kept but not ordered = b-roll sources
        Self.warnIfIntroBuried(orderedKept, segmentsById: byId)

        // Legacy default b-roll for each voiceover candidate = highest-hook food-closeup elsewhere.
        var broll: [Int: Int] = [:]
        let brollCandidates = plan.segments
            .filter { $0.sceneType == .foodCloseup }
            .sorted { $0.hookScore > $1.hookScore }
        for seg in plan.segments where seg.voiceoverCandidate {
            if let best = brollCandidates.first(where: { $0.id != seg.id }) { broll[seg.id] = best.id }
        }
        self.brollSource = broll

        if spineIsVerbatim {
            // DECIDE owns the spine: `final_edit_order` IS the spine, EXACTLY. Kept-but-unordered shots are
            // b-roll SOURCES → the pool, never the spine. No food-closeup extraction (DECIDE already chose
            // spine-vs-overlay), no straggler-append — so the edit is precisely what DECIDE decided.
            self.order = orderedKept.map(clip)
            self.brollClips = TopicGrouping.groupedOrder(sources.sorted { startOf($0) < startOf($1) }, segmentsById: byId)
            self.hookId = orderedKept.first
        } else {
            // Monolith: append stragglers, then split food close-ups onto the B-roll layer (except the hook).
            let ordered = orderedKept + sources
            let hook = ordered.first
            let brollLayer: [Int] = ordered.filter { id in id != hook && isFoodCloseup(id) }
            self.order = ordered.filter { !brollLayer.contains($0) }.map(clip)
            self.brollClips = TopicGrouping.groupedOrder(brollLayer.sorted { startOf($0) < startOf($1) }, segmentsById: byId)
            self.hookId = hook
        }
        self.cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        self.brollLane = []
        // Auto-fill the overlay layer from Gemini's suggested placements (needs the stored props above).
        self.brollLane = seededLane(fromPlacements: plan.brollPlacements)
    }

    // MARK: - Order sanity (assert, never re-sort)

    /// The AI owns the play order — `final_edit_order` is used VERBATIM. This is a NON-MUTATING discipline
    /// check: if an `.intro` clip lands AFTER the tasting/verdict has begun (a `.middle`/`.end` clip), the
    /// narrative arc is broken (the old "restaurant intro buried in the middle"). We LOG it so a bad AI
    /// order is visible in the console — we NEVER re-sort (that re-sort is exactly what used to scramble the
    /// dishes + strand the verdict). A normal cold-open teaser is intro/unknown, so it never trips this.
    static func warnIfIntroBuried(_ ordered: [Int], segmentsById: [Int: Segment]) {
        func section(_ id: Int) -> VideoSection { segmentsById[id]?.section ?? .unknown }
        guard let firstBody = ordered.firstIndex(where: { section($0) == .middle || section($0) == .end })
        else { return }
        let buried = ordered[(firstBody + 1)...].filter { section($0) == .intro }
        guard !buried.isEmpty else { return }
        Log.gemini("⚠️ Order check — \(buried.count) intro clip(s) \(buried) play AFTER the tasting/verdict began (AI buried the intro). Using the AI's order verbatim anyway — not re-sorting.")
    }

    /// The export "did this feel like you?" verdict (nil = unanswered). Persisted via `snapshot()` so the
    /// future style-learning loop keeps the signal across kill / re-open.
    var exportFeedback: Bool?

    /// The Polish b-roll SOURCE POOL: the dedicated b-roll clips plus any set-aside (cut) VISUAL clips —
    /// a dropped food shot is supply, not trash. Computed, never persisted: `cutTray` stays the single
    /// live source of truth (every keep:false id, always — footage is never silently lost), so restoring
    /// a cut clip to the spine removes it from this pool with no stale entry to reconcile.
    var brollPool: [Int] {
        let fromTray = cutTray.filter { id in
            guard let s = segmentsById[id] else { return false }
            return s.isBrollSource && !brollClips.contains(id)
        }
        guard !fromTray.isEmpty else { return brollClips }
        let sorted = fromTray.sorted { (segmentsById[$0]?.startSeconds ?? 0) < (segmentsById[$1]?.startSeconds ?? 0) }
        return brollClips + TopicGrouping.groupedOrder(sorted, segmentsById: segmentsById)
    }

    /// True when the cut has NO b-roll to work with — both the source pool and the placed lane are empty
    /// (e.g. a single talking-head clip). Drives the Polish empty-B-roll-lane hint.
    var hasNoBrollAvailable: Bool { brollPool.isEmpty && brollLane.isEmpty }

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
        narrationLane      = state.narrationLane
        originalAudioGain  = state.originalAudioGain
        lastNonZeroGain    = state.lastNonZeroGain
        didAutoDuck        = state.didAutoDuck
        voDuckLevel        = state.voDuckLevel
        originalAudioMuted = state.originalAudioMuted
        exportFeedback     = state.exportFeedback
        normalizeOverlaySourceStarts()   // resolve legacy overlays (no stored in-point) to head-anchored
    }

    /// A Codable snapshot of all editable state — the "edit" half of a saved project.
    func snapshot() -> EditState {
        EditState(order: order, brollClips: brollClips, cutTray: cutTray, hookId: hookId,
                  brollLane: brollLane, brollSource: brollSource, dismissed: dismissed,
                  textOverlays: textOverlays, narrationLane: narrationLane,
                  originalAudioGain: originalAudioGain, lastNonZeroGain: lastNonZeroGain,
                  didAutoDuck: didAutoDuck, voDuckLevel: voDuckLevel,
                  originalAudioMuted: originalAudioMuted, exportFeedback: exportFeedback)
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
        narrationLane = s.narrationLane; originalAudioGain = s.originalAudioGain
        lastNonZeroGain = s.lastNonZeroGain; didAutoDuck = s.didAutoDuck
        voDuckLevel = s.voDuckLevel; originalAudioMuted = s.originalAudioMuted
        normalizeOverlaySourceStarts()   // legacy snapshots without a stored in-point → head-anchored
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
        clampNarrationIntoBounds()   // takes are timeline-anchored: only clamped, never rippled
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

    /// Sort's keep commit — the card's footage-bar toggle decides the kept window: Vela's trim
    /// (`makeClip` bounds) or the segment's FULL bounds. The window change ripples the overlay lane
    /// (a mid-spine clip growing/shrinking shifts everything after it).
    func keep(_ id: Int, fullClip: Bool) {
        keep(id)
        withRippledLane { setKeepWindow(id, fullClip: fullClip) }
    }

    /// Hook variant of the Sort keep commit (a hook is a keep with a crown).
    func setHook(_ id: Int, fullClip: Bool) {
        setHook(id)
        withRippledLane { setKeepWindow(id, fullClip: fullClip) }
    }

    /// Apply the Sort toggle to the segment's single spine instance. `fullClip` stretches it to the
    /// segment's full bounds (overriding the AI trim). `fullClip == false` shrinks it back to the AI
    /// trim ONLY when it currently spans the exact full bounds (undoing a previous toggle) — a custom
    /// trim the creator made on Polish is never clobbered. A split clip (multiple instances) is left
    /// alone entirely: their edit wins.
    private func setKeepWindow(_ id: Int, fullClip: Bool) {
        guard let s = segmentsById[id] else { return }
        let instances = order.indices.filter { order[$0].sourceSegmentId == id }
        guard instances.count == 1, let i = instances.first else { return }
        if fullClip {
            order[i].inPoint = s.startSeconds
            order[i].outPoint = s.endSeconds
        } else {
            let isFullSpan = abs(order[i].inPoint - s.startSeconds) < 0.05
                && abs(order[i].outPoint - s.endSeconds) < 0.05
            if isFullSpan {
                let ai = makeClip(id)
                order[i].inPoint = ai.inPoint
                order[i].outPoint = ai.outPoint
            }
        }
        clampNarrationIntoBounds()
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

    /// Frame-accurate two-edge trim on a base clip, clamped to the segment's real source bounds — the
    /// in-point can move, and a clip can grow back toward the AI's full bounds (this is how hidden
    /// trimmed footage is recovered on Polish). (These change `baseDuration` without rippling, so the
    /// narration clamp runs here too.)
    /// `minBound` / `maxBound` are the clip's reachable source range in merged-proxy seconds. The caller
    /// passes the ORIGINAL recording's `SourceSpan` bounds (not the ~15s segment), so a trim can drag past
    /// the segment to reveal the rest of the clip it was cut from (Meka #10).
    func setIn(_ cid: UUID, toSource newIn: Double, minBound: Double) {
        guard let i = clipIndex(cid) else { return }
        let snapped = (newIn * 30).rounded() / 30
        order[i].inPoint = max(minBound, min(snapped, order[i].outPoint - 1.0 / 30))
        clampNarrationIntoBounds()
    }
    func setOut(_ cid: UUID, toSource newOut: Double, maxBound: Double) {
        guard let i = clipIndex(cid) else { return }
        let snapped = (newOut * 30).rounded() / 30
        order[i].outPoint = min(maxBound, max(snapped, order[i].inPoint + 1.0 / 30))
        clampNarrationIntoBounds()
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
        // Speed re-times the FOOTAGE; takes keep their absolute position and are never speed-scaled —
        // but the timeline just grew/shrank, so clamp them into the new bounds.
        clampNarrationIntoBounds()
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
        guard let seg = segmentsById[sourceId] else { return }
        let clampedStart = max(0, min(start, max(0, baseDuration - 0.5)))
        let dur = min(sourceLength(sourceId), max(0.5, baseDuration - clampedStart))
        brollLane.append(OverlayClip(sourceSegmentId: sourceId, startOnBase: clampedStart,
                                     duration: max(0.3, dur), sourceStart: seg.startSeconds))
    }

    /// The resolved source in-point for an overlay — its stored `sourceStart`, or the segment's own start for
    /// a legacy/unset value. All reads of an overlay's in-point (render, audio, trim, split) go through here.
    func overlaySourceStart(_ o: OverlayClip) -> Double {
        o.sourceStart >= 0 ? o.sourceStart : (segmentsById[o.sourceSegmentId]?.startSeconds ?? 0)
    }

    /// Resolve any sentinel `sourceStart` to the segment start (head-anchored) — run after loading a lane from
    /// a plan seed or a persisted `EditState`, so old projects keep their exact behavior and every stored
    /// overlay carries a real in-point thereafter.
    private func normalizeOverlaySourceStarts() {
        for i in brollLane.indices where brollLane[i].sourceStart < 0 {
            brollLane[i].sourceStart = segmentsById[brollLane[i].sourceSegmentId]?.startSeconds ?? 0
        }
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

    /// Left-edge trim: move the overlay's start to `newStart`, keeping the RIGHT edge fixed and advancing the
    /// source in-point by the same amount — so the LATER source content plays (true left-crop, like the spine).
    /// Clamped to a 0.3s minimum, the timeline start, and the available source head/tail.
    func setOverlayLeftEdge(_ id: UUID, toStart newStart: Double) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }), let seg = segmentsById[brollLane[i].sourceSegmentId] else { return }
        let o = brollLane[i]
        let inNow = overlaySourceStart(o)
        let end = o.endOnBase
        let segStart = seg.startSeconds
        let headRoom = inNow - segStart                     // how far left we may extend (source before the in-point)
        let minStart = max(0, o.startOnBase - headRoom)     // can't pull in earlier source than exists / before t0
        let maxStart = end - 0.3                             // keep ≥0.3s of clip
        let s = min(max(newStart, minStart), maxStart)
        let delta = s - o.startOnBase                        // + = trimming head off; − = extending left
        brollLane[i].startOnBase = s
        brollLane[i].duration = max(0.3, end - s)
        brollLane[i].sourceStart = inNow + delta
    }

    /// Right-edge trim: move the overlay's end to `newEnd`, keeping the start + source in-point fixed (only the
    /// duration changes). Clamped to a 0.3s minimum, the base bounds, and the source tail after the in-point.
    func setOverlayRightEdge(_ id: UUID, toEnd newEnd: Double) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }), let seg = segmentsById[brollLane[i].sourceSegmentId] else { return }
        let o = brollLane[i]
        let inNow = overlaySourceStart(o)
        let segEnd = seg.startSeconds + sourceLength(o.sourceSegmentId)
        let maxEnd = min(baseDuration, o.startOnBase + (segEnd - inNow))   // can't run past the available source tail
        let e = max(min(newEnd, maxEnd), o.startOnBase + 0.3)
        brollLane[i].sourceStart = inNow                     // resolve any sentinel; in-point unchanged
        brollLane[i].duration = max(0.3, e - o.startOnBase)
    }

    func removeOverlay(_ id: UUID) { brollLane.removeAll { $0.id == id } }

    func swapOverlaySource(_ id: UUID, to sourceId: Int) {
        guard let i = brollLane.firstIndex(where: { $0.id == id }), let seg = segmentsById[sourceId] else { return }
        brollLane[i].sourceSegmentId = sourceId
        brollLane[i].sourceStart = seg.startSeconds         // new source → reset the in-point to its head
        trimOverlay(id, duration: brollLane[i].duration)    // re-clamp to the new source length
    }

    /// Split an overlay at assembled-timeline second `timelineT` into two independent overlays — the halves
    /// carry contiguous source slices (right's in-point continues where left's ended). No-op unless `timelineT`
    /// lands strictly inside the overlay (frame-margin). Returns the RIGHT half's id (to select after).
    @discardableResult
    func splitOverlay(_ id: UUID, at timelineT: Double) -> UUID? {
        guard let i = brollLane.firstIndex(where: { $0.id == id }) else { return nil }
        let o = brollLane[i]
        let eps = 1.0 / 30
        guard timelineT > o.startOnBase + eps, timelineT < o.endOnBase - eps else { return nil }
        pushUndo()
        let leftDur = timelineT - o.startOnBase
        let inNow = overlaySourceStart(o)
        let left = OverlayClip(sourceSegmentId: o.sourceSegmentId, startOnBase: o.startOnBase,
                               duration: leftDur, sourceStart: inNow, volume: o.volume)
        let right = OverlayClip(sourceSegmentId: o.sourceSegmentId, startOnBase: timelineT,
                                duration: o.endOnBase - timelineT, sourceStart: inNow + leftDur, volume: o.volume)
        brollLane.replaceSubrange(i...i, with: [left, right])
        return right.id
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

    // MARK: - Narration lane (Layer "Voiceover" — recorded takes over the assembled timeline)
    //
    // Takes are TIMELINE-anchored, unlike B-roll overlays (content-anchored via the ripple system):
    // narration is performed against the finished picture, so spine edits never slide it — a take only
    // gets clamped when the timeline shrinks past it. Changing a clip's speed re-times the FOOTAGE;
    // narration keeps its absolute position and is never pitch/speed-scaled.

    /// Where recording from `t` must stop: the next take's left edge, or the video's end.
    func narrationBoundary(after t: Double) -> Double {
        let next = narrationLane.map(\.startOnBase).filter { $0 > t + 0.05 }.min() ?? baseDuration
        return min(baseDuration, next)
    }

    /// Can a take start at `t`? Not inside an existing take, and with ≥0.5s of room before the boundary.
    func canRecord(at t: Double) -> Bool {
        guard baseDuration > 0, t < baseDuration - 0.1 else { return false }
        guard !narrationLane.contains(where: { t >= $0.startOnBase - 0.02 && t < $0.endOnBase - 0.02 }) else { return false }
        return narrationBoundary(after: t) - t >= NarrationRecorder.minTakeSeconds
    }

    /// Land a finished take on the lane, capped so it can't overlap the next take / run past the end.
    /// Caller pushes undo (same convention as `appendImportedSegments`).
    @discardableResult
    func addNarration(fileName: String, fileDuration: Double, at start: Double, cappedTo boundary: Double) -> NarrationClip {
        let out = min(fileDuration, max(0.1, boundary - start))
        let clip = NarrationClip(fileName: fileName, startOnBase: start,
                                 inPoint: 0, outPoint: out, fileDuration: fileDuration)
        narrationLane.append(clip)
        narrationLane.sort { $0.startOnBase < $1.startOnBase }
        return clip
    }

    func removeNarration(_ id: UUID) { narrationLane.removeAll { $0.id == id } }

    func setNarrationVolume(_ id: UUID, _ value: Float) {
        guard let i = narrationLane.firstIndex(where: { $0.id == id }) else { return }
        narrationLane[i].volume = max(0, min(1, value))
    }

    /// Move a take to `proposed`, clamped into the timeline and snapped OUT of any overlap with the
    /// other takes: an overlapping drop lands flush against the nearer side of the chip it hit (or the
    /// far side if that spot is taken). Reverts to its old position when no gap fits — the lane never
    /// holds a partial overlap.
    func moveNarration(_ id: UUID, toStart proposed: Double) {
        guard let i = narrationLane.firstIndex(where: { $0.id == id }) else { return }
        let dur = narrationLane[i].duration
        let maxStart = max(0, baseDuration - dur)
        let others = narrationLane.filter { $0.id != id }

        func overlaps(_ s: Double) -> Bool {
            others.contains { s < $0.endOnBase - 0.001 && $0.startOnBase + 0.001 < s + dur }
        }
        var start = max(0, min(proposed, maxStart))
        if overlaps(start) {
            guard let hit = others.first(where: { start < $0.endOnBase && $0.startOnBase < start + dur })
            else { return }
            let preferLeft = (start + dur / 2) < (hit.startOnBase + hit.endOnBase) / 2
            let candidates = preferLeft ? [hit.startOnBase - dur, hit.endOnBase]
                                        : [hit.endOnBase, hit.startOnBase - dur]
            guard let landed = candidates
                .map({ max(0, min($0, maxStart)) })
                .first(where: { !overlaps($0) }) else { return }   // no gap → revert
            start = landed
        }
        narrationLane[i].startOnBase = start
        narrationLane.sort { $0.startOnBase < $1.startOnBase }
    }

    /// Two-edge trim. The LEFT edge keeps **picture-sync**: pulling it right consumes file head
    /// (`inPoint` advances exactly with `startOnBase`) so the remaining words stay glued to the frames
    /// they were spoken over — trimming never slides the audio. It can re-extend left only as far as
    /// unused file head exists. The RIGHT edge just resizes the window into the file. Both edges clamp
    /// against the neighbor takes, the timeline end, and a 0.3s minimum.
    func setNarrationBounds(_ id: UUID, start: Double, end: Double) {
        guard let i = narrationLane.firstIndex(where: { $0.id == id }) else { return }
        var c = narrationLane[i]
        let others = narrationLane.filter { $0.id != id }
        let prevEnd = others.filter { $0.startOnBase < c.startOnBase }.map(\.endOnBase).max() ?? 0
        let nextStart = others.filter { $0.startOnBase > c.startOnBase }.map(\.startOnBase).min() ?? baseDuration

        let minStart = max(0, max(prevEnd, c.startOnBase - c.inPoint))
        let s = max(minStart, min(start, c.endOnBase - 0.3))
        c.inPoint += s - c.startOnBase
        c.startOnBase = s

        let maxEnd = min(min(nextStart, baseDuration), c.startOnBase + (c.fileDuration - c.inPoint))
        let e = min(maxEnd, max(end, c.startOnBase + 0.3))
        c.outPoint = c.inPoint + (e - c.startOnBase)
        narrationLane[i] = c
    }

    /// Split a take at assembled-timeline second `timelineT` into two adjacent takes — the halves carry
    /// contiguous slices of the SAME recording (right's `inPoint` continues where left's `outPoint` ended;
    /// narration plays 1:1 with the timeline, so the file-local split point is just `inPoint + leftDur`).
    /// Both halves reference the same file — safe because `removeNarration` never deletes the file on disk.
    /// No-op unless `timelineT` lands strictly inside the take (frame-margin). Returns the RIGHT half's id.
    @discardableResult
    func splitNarration(_ id: UUID, at timelineT: Double) -> UUID? {
        guard let i = narrationLane.firstIndex(where: { $0.id == id }) else { return nil }
        let c = narrationLane[i]
        let eps = 1.0 / 30
        guard timelineT > c.startOnBase + eps, timelineT < c.endOnBase - eps else { return nil }
        pushUndo()
        let splitIn = c.inPoint + (timelineT - c.startOnBase)
        let left = NarrationClip(fileName: c.fileName, startOnBase: c.startOnBase,
                                 inPoint: c.inPoint, outPoint: splitIn,
                                 fileDuration: c.fileDuration, volume: c.volume)
        let right = NarrationClip(fileName: c.fileName, startOnBase: timelineT,
                                  inPoint: splitIn, outPoint: c.outPoint,
                                  fileDuration: c.fileDuration, volume: c.volume)
        narrationLane.replaceSubrange(i...i, with: [left, right])
        narrationLane.sort { $0.startOnBase < $1.startOnBase }
        return right.id
    }

    /// Clamp takes into a (possibly shrunken) timeline after a spine edit: starts pull back inside,
    /// tails trim to fit, and neighbors never overlap. Takes are never dropped — worst case one
    /// renders very short near the end. (Growing the timeline never moves a take: they're
    /// timeline-anchored, not content-anchored like B-roll.)
    private func clampNarrationIntoBounds() {
        let total = baseDuration
        guard total > 0 else { narrationLane.removeAll(); return }
        var lastEnd = 0.0
        narrationLane.sort { $0.startOnBase < $1.startOnBase }
        for i in narrationLane.indices {
            var c = narrationLane[i]
            c.startOnBase = max(lastEnd, min(c.startOnBase, max(0, total - 0.3)))
            let maxOut = c.inPoint + max(0.05, total - c.startOnBase)
            c.outPoint = max(c.inPoint + 0.05, min(c.outPoint, min(c.fileDuration, maxOut)))
            narrationLane[i] = c
            lastEnd = c.endOnBase
        }
    }

    /// "Under voiceover" duck level (0…1) — how loud the original bed stays while a take plays.
    /// Applied at mix time by `AudioDucking`; never written into clip volumes.
    func setVoDuckLevel(_ value: Float) {
        voDuckLevel = max(0, min(1, value))
    }

    /// First-take bookkeeping: returns true exactly once per project (the view shows the "original
    /// audio dips under your voiceover" toast). No volume writes — the duck itself is always-on,
    /// scoped to takes, at `voDuckLevel`.
    func noteFirstTake() -> Bool {
        guard !didAutoDuck, narrationLane.count == 1 else { return false }
        didAutoDuck = true
        return true
    }

    /// Drop takes whose file no longer exists (resume after the app container changed / manual cleanup).
    /// Returns how many were removed so the view can mention it once.
    @discardableResult
    func pruneMissingNarration() -> Int {
        guard let dir = narrationDirectory, !narrationLane.isEmpty else { return 0 }
        let before = narrationLane.count
        narrationLane.removeAll { !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0.fileName).path) }
        let dropped = before - narrationLane.count
        if dropped > 0 { Log.audio("⚠️ Pruned \(dropped) narration take(s) with missing files.") }
        return dropped
    }

    /// Render-ready narration slices for BOTH compositors. Resolves file names against
    /// `narrationDirectory`, skips missing files (warn) and takes starting past the (possibly shrunken)
    /// timeline end. A slight overhang past `baseDuration` is fine — the assembler already freeze-frames
    /// the last instruction to cover an audio tail, and the preview simply ends.
    func narrationPieces() -> [NarrationPiece] {
        guard !narrationLane.isEmpty else { return [] }
        guard let dir = narrationDirectory else {
            Log.audio("⚠️ narrationPieces: no narration directory set — \(narrationLane.count) take(s) skipped.")
            return []
        }
        return narrationLane
            .filter { $0.startOnBase < baseDuration - 0.02 && $0.duration > 0.05 }
            .sorted { $0.startOnBase < $1.startOnBase }
            .compactMap { clip in
                let url = dir.appendingPathComponent(clip.fileName)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    Log.audio("⚠️ narration file missing on disk: \(clip.fileName) — skipped.")
                    return nil
                }
                return NarrationPiece(url: url, startOnBase: clip.startOnBase,
                                      fileIn: clip.inPoint, fileOut: clip.outPoint, volume: clip.volume)
            }
    }

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

        // ONE coverage semantic everywhere (style target, this cap, plannedBrollPct): the denominator is
        // the spine's TALKING-ON-CAMERA time, not the whole timeline — a food-heavy spine shouldn't
        // inflate the overlay budget. At seed time every clip is speed 1, so timelineDuration is exact.
        let talkingSecs = order.reduce(0.0) { acc, c in
            (segmentsById[c.sourceSegmentId]?.sceneType == .talkingHead) ? acc + c.timelineDuration : acc
        }
        let coverageCap = brollCoverageTarget * talkingSecs
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

            // Begin at the requested offset — floored by the shared reaction cover policy (belt-and-braces
            // mirror of the adapter's gate: bite/verdict never seed; a first_taste / peak_reaction keeps
            // its ~3s peak face-on — an offset pushed past the clip window just fails the dur guard below).
            let overKind = segmentsById[p.overSegmentId]?.reactionKind ?? ReactionKind.none
            guard let minOffset = overKind.minCoverOffset else { continue }      // never-cover reaction
            let offset = max(minOffset, min(p.startOffsetSeconds, max(0, clip.timelineDuration - 0.3)))
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
            // Variety net (mirrors the prompt's once-each VARY rule): an AI-seeded source appears at
            // most once — our overlays always replay a source from its start, so a repeat is identical
            // frames, not an edit. Manual placements in Polish are not constrained (deliberate
            // callbacks stay the creator's call).
            guard !lane.contains(where: { $0.sourceSegmentId == p.brollSegmentId }) else { continue }
            lane.append(OverlayClip(sourceSegmentId: p.brollSegmentId, startOnBase: start, duration: dur,
                                    sourceStart: src.startSeconds))
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
               segmentsById[o.sourceSegmentId] != nil {
                slots.append(RenderSlot(baseStart: a, duration: b - a,
                                        videoSegId: o.sourceSegmentId,
                                        videoSourceStart: overlaySourceStart(o) + (a - o.startOnBase),
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
    /// The voiceover duck + track mute are applied on top at mix time (`AudioDucking`), never here.
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
            guard o.volume > 0.001, segmentsById[o.sourceSegmentId] != nil else { return nil }
            return AudioPiece(segId: o.sourceSegmentId, baseStart: o.startOnBase, timelineDuration: o.duration,
                              sourceStart: overlaySourceStart(o), sourceDuration: o.duration, volume: o.volume, speed: 1)
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
        let orderedKept = plan.finalEditOrder.filter { keepIds.contains($0) }
        let sources = keepIds.filter { !orderedKept.contains($0) }   // kept but not ordered = b-roll sources

        // The AI's order, VERBATIM (same as the initial build) — "Accept Vela's picks" shows exactly the
        // AI's suggested sequence; code never re-sorts it, only warns if the intro got buried.
        Self.warnIfIntroBuried(orderedKept, segmentsById: segmentsById)

        if spineIsVerbatim {
            // DECIDE owns the spine: final_edit_order EXACTLY; b-roll sources → the pool, not the spine.
            order = orderedKept.map(makeClip)
            brollClips = TopicGrouping.groupedOrder(sources.sorted { rawStart($0) < rawStart($1) }, segmentsById: segmentsById)
            hookId = orderedKept.first
        } else {
            let ordered = orderedKept + sources
            hookId = ordered.first
            let currentHook = hookId
            let brollLayer: [Int] = ordered.filter { id in id != currentHook && isFoodCloseup(id) }
            order = ordered.filter { !brollLayer.contains($0) }.map(makeClip)
            brollClips = TopicGrouping.groupedOrder(brollLayer.sorted { rawStart($0) < rawStart($1) }, segmentsById: segmentsById)
        }
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
