import Foundation
import Observation

/// The single source of truth for an editing session. The analysis produces the immutable
/// `EditPlan`; this store holds all *editable* state layered on top (order, cuts, hook, trims,
/// b-roll swaps, dismissed notes). Every view reads/mutates this; the assembler consumes it.
@Observable
final class EditPlanStore {
    let plan: EditPlan
    private let segmentsById: [Int: Segment]

    /// IDs currently in the edit, in play order (seeded from `final_edit_order`).
    var order: [Int]
    /// IDs the creator cut — never deleted, restorable from the Cut Tray.
    var cutTray: [Int]
    /// The chosen opening segment.
    var hookId: Int?
    /// Per-segment effective end time (seconds in the raw video). Seeded from `trim_to_seconds ?? end`.
    var trimEnd: [Int: Double]
    /// Voiceover segment id -> chosen b-roll source segment id (a food-closeup in the same video).
    var brollSource: [Int: Int]
    /// Reason-note ids the creator dismissed.
    var dismissed: Set<Int> = []

    init(plan: EditPlan) {
        self.plan = plan
        self.segmentsById = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // keep:true segments, ordered by final_edit_order, with any stragglers appended.
        let keepIds = plan.segments.filter { $0.keep }.map(\.id)
        var ordered = plan.finalEditOrder.filter { keepIds.contains($0) }
        for id in keepIds where !ordered.contains(id) { ordered.append(id) }

        self.order = ordered
        self.cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        self.hookId = ordered.first
        self.trimEnd = Dictionary(
            plan.segments.map { ($0.id, $0.trimToSeconds ?? $0.endSeconds) },
            uniquingKeysWith: { a, _ in a }
        )

        // Default b-roll for each voiceover candidate = highest-hook food-closeup elsewhere.
        var broll: [Int: Int] = [:]
        let brollCandidates = plan.segments
            .filter { $0.sceneType == .foodCloseup }
            .sorted { $0.hookScore > $1.hookScore }
        for seg in plan.segments where seg.voiceoverCandidate {
            if let best = brollCandidates.first(where: { $0.id != seg.id }) {
                broll[seg.id] = best.id
            }
        }
        self.brollSource = broll
    }

    // MARK: - Lookups

    func segment(_ id: Int) -> Segment? { segmentsById[id] }

    /// All food-closeup segments — the pool of swappable b-roll sources.
    var brollOptions: [Segment] {
        plan.segments.filter { $0.sceneType == .foodCloseup }.sorted { $0.hookScore > $1.hookScore }
    }

    /// Effective clip duration after any trim, in seconds.
    func duration(_ id: Int) -> Double {
        guard let s = segmentsById[id] else { return 0 }
        let end = trimEnd[id] ?? s.endSeconds
        return max(0.1, end - s.startSeconds)
    }

    var totalDuration: Double { order.reduce(0) { $0 + duration($1) } }

    func isHook(_ id: Int) -> Bool { hookId == id }
    func isDismissed(_ id: Int) -> Bool { dismissed.contains(id) }

    // MARK: - Mutations

    func keep(_ id: Int) {
        cutTray.removeAll { $0 == id }
        if !order.contains(id) { order.append(id) }
    }

    func cut(_ id: Int) {
        order.removeAll { $0 == id }
        if !cutTray.contains(id) { cutTray.append(id) }
        if hookId == id { hookId = order.first }
    }

    func setHook(_ id: Int) {
        keep(id)
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
        hookId = id
    }

    func restore(_ id: Int) {
        cutTray.removeAll { $0 == id }
        if !order.contains(id) { order.append(id) }
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        order.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    /// Reorder a single id to an absolute index (used by the timeline drag).
    func reorder(id: Int, to index: Int) {
        guard let cur = order.firstIndex(of: id) else { return }
        order.remove(at: cur)
        order.insert(id, at: max(0, min(index, order.count)))
    }

    /// Set an effective duration (seconds), clamped to the raw segment's real length.
    func setDuration(_ id: Int, seconds: Double) {
        guard let s = segmentsById[id] else { return }
        let maxLen = s.endSeconds - s.startSeconds
        let clamped = max(0.5, min(seconds, maxLen))
        trimEnd[id] = s.startSeconds + clamped
    }

    func swapBroll(_ voiceoverId: Int, to sourceId: Int) { brollSource[voiceoverId] = sourceId }

    func dismiss(_ id: Int) { dismissed.insert(id) }

    /// Reset the working edit to the AI's full recommendation — "Accept Vela's picks": keep the
    /// keeps, cut the cuts, open with the highest-`hook_score` kept clip, and restore the AI's
    /// suggested trims. Mirrors the init-seeding logic. Everything stays reversible (Cut Tray).
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

        order = ordered
        cutTray = plan.segments.filter { !$0.keep }.map(\.id)
        trimEnd = Dictionary(
            plan.segments.map { ($0.id, $0.trimToSeconds ?? $0.endSeconds) },
            uniquingKeysWith: { a, _ in a }
        )
    }

    // MARK: - Derived display

    private var averageClip: Double { order.isEmpty ? 0 : totalDuration / Double(order.count) }

    var pacingText: String {
        averageClip < 3.5 ? "punchy pacing" : (averageClip < 6 ? "good pacing" : "relaxed pacing")
    }

    var hookText: String {
        if let h = hookId, order.contains(h) { return "strong hook" }
        return "no hook yet"
    }

    /// The live vibe meter, e.g. "28s · strong hook · good pacing".
    var vibeText: String {
        "\(Int(totalDuration.rounded()))s · \(hookText) · \(pacingText)"
    }
}
