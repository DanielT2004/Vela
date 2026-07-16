import Foundation

/// Pure, honest "reads" of a finished first cut — the single place that turns raw Edit-Plan fields into
/// the banded, credible language the results recap (`FirstCutView`) shows. **No view code, no fabricated
/// metrics.** Every value maps to a real field and is framed as "our read of THIS footage", never an
/// audience prediction.
///
/// Bands over numbers on purpose: a raw `hookScore` decimal or a precise b-roll % would read as false
/// precision, so we surface qualitative bands (strong / solid / workable, light / moderate / heavy) and
/// real seconds. `hookScore` is kept only to drive the visual `HookScoreMeter` — never rendered as text.
struct RetentionRead {

    // MARK: - Bands

    /// The winning opener's scroll-stop strength, from the raw hookScore (not the rounded meter count).
    enum ScrollStop { case strong, solid, workable, none
        /// The ONE place score → band lives, shared by this read and `HookScoreMeter`'s text so the
        /// two can't drift (the meter must never render the raw number — bands, not scores).
        init(score: Double?) {
            guard let score else { self = .none; return }
            if score >= 8      { self = .strong }
            else if score >= 5 { self = .solid }
            else               { self = .workable }
        }
        var label: String {
            switch self {
            case .strong:   return "a strong scroll-stopper"
            case .solid:    return "a solid opener"
            case .workable: return "a workable open — worth testing an alternative"
            case .none:     return "no clear hook yet"
            }
        }
        /// Short band word for the compact viral-read cell.
        var shortLabel: String {
            switch self {
            case .strong: return "Strong"; case .solid: return "Solid"
            case .workable: return "Workable"; case .none: return "—"
            }
        }
    }

    /// The video's heartbeat, from average clip length on the spine.
    enum Pace { case punchy, good, relaxed, unknown
        var word: String {
            switch self {
            case .punchy: return "Punchy"; case .good: return "Good"
            case .relaxed: return "Relaxed"; case .unknown: return "—"
            }
        }
        var line: String {
            switch self {
            case .punchy:  return "Shots turn over fast enough to keep resetting attention."
            case .good:    return "An even, easy-to-follow rhythm through the middle."
            case .relaxed: return "A slower, let-it-breathe pace — a style choice, not a flaw."
            case .unknown: return ""
            }
        }
    }

    /// Length vs the food-review completion sweet spot (~25–35s). "Built to be finished", never a promise.
    enum Length { case sweet, short, long, unknown
        var line: String {
            switch self {
            case .sweet:   return "Right in the range where food videos tend to hold to the end."
            case .short:   return "A fast, high-completion length — punchy and easy to rewatch."
            case .long:    return "A story-rich cut; tightening toward ~30s usually helps completion."
            case .unknown: return ""
            }
        }
    }

    /// Whether the hook's promise gets paid off, and where.
    enum Payoff { case late, buried, absent
        var line: String {
            switch self {
            case .late:   return "The bite/verdict lands near the end — it earns the finish and the rewatch."
            case .buried: return "Your verdict lands mid-video; moving it toward the end tightens the loop."
            case .absent: return "No clear verdict beat in this footage — the one shot worth capturing next time."
            }
        }
        var chip: String {
            switch self {
            case .late:   return "lands the finish"
            case .buried: return "lands mid-video"
            case .absent: return "none yet"
            }
        }
    }

    /// How much of the timeline carries food b-roll over the talk — a coarse band, never a precise %.
    enum Broll { case none, light, moderate, heavy
        var label: String {
            switch self {
            case .none: return "none"; case .light: return "light"
            case .moderate: return "moderate"; case .heavy: return "heavy"
            }
        }
    }

    // MARK: - Values

    let totalDuration: Double
    let targetDuration: Double
    let keptCount: Int          // clips on the main spine
    let brollOverlayCount: Int  // placements on the overlay lane
    let setAsideCount: Int      // clips in the Cut Tray

    let scrollStop: ScrollStop
    let hookScore: Double       // raw — drives HookScoreMeter ONLY, never shown as text
    let hookSceneLabel: String
    let hookWhy: String         // composed honest "why it opens" from sceneType + description

    let pace: Pace
    let length: Length
    let payoff: Payoff
    let payoffFraction: Double? // 0…1 position on the strip; nil when absent
    let broll: Broll
    /// The creator EXPLICITLY asked for a high b-roll target (More food / Mostly food) and the cut
    /// landed under half of it — footage-bound, not a miss, and worth saying in their terms so the
    /// override never reads as ignored. All real fields: the lean choice, the resolved target, and
    /// the lane's actual coverage of kept talking time.
    let brollAskShortfall: Bool
    let secondsTrimmed: Int

    let introKept: Int
    let middleKept: Int
    let endKept: Int
    /// Sections present in the footage but absent from the cut — surfaced calmly, never hidden.
    let missingSections: [VideoSection]

    // MARK: - Derivation (all from real fields)

    init(plan: EditPlan, store: EditPlanStore, brief: EditBrief? = nil) {
        let total = store.totalDuration
        totalDuration = total
        targetDuration = plan.recommendedDuration
        keptCount = store.order.count
        brollOverlayCount = store.brollLane.count
        setAsideCount = store.cutTray.count

        // Hook → scroll-stop band from the RAW score.
        let hook = store.hookId.flatMap { store.segment($0) }
        let hs = hook?.hookScore ?? 0
        hookScore = hs
        scrollStop = ScrollStop(score: hook == nil ? nil : hs)
        hookSceneLabel = hook?.sceneType.label ?? ""
        hookWhy = Self.composeHookWhy(for: hook)

        // Pace from average clip length on the spine (matches EditPlanStore's own bands).
        let avg = store.order.isEmpty ? 0 : total / Double(store.order.count)
        if store.order.isEmpty     { pace = .unknown }
        else if avg < 3.5          { pace = .punchy }
        else if avg < 6            { pace = .good }
        else                       { pace = .relaxed }

        // Length vs the ~25–35s food-review sweet spot.
        if total <= 0              { length = .unknown }
        else if total < 22         { length = .short }
        else if total <= 38        { length = .sweet }
        else                       { length = .long }

        // Payoff — first kept spine clip that's a bite reaction or an end/verdict beat.
        var payoffIdx: Int? = nil
        for (i, c) in store.order.enumerated() {
            if let s = store.segment(c.sourceSegmentId), s.sceneType == .biteReaction || s.section == .end {
                payoffIdx = i; break
            }
        }
        if let idx = payoffIdx, store.order.count > 0 {
            let frac = Double(idx) / Double(max(1, store.order.count - 1))
            payoffFraction = frac
            payoff = frac >= 0.6 ? .late : .buried
        } else {
            payoffFraction = nil
            payoff = .absent
        }

        // B-roll coverage → band (never a rendered %).
        let laneSeconds = store.brollLane.reduce(0) { $0 + $1.duration }
        let cover = total > 0 ? min(1, laneSeconds / total) : 0
        if store.brollLane.isEmpty || cover <= 0.001 { broll = .none }
        else if cover < 0.15                          { broll = .light }
        else if cover < 0.40                          { broll = .moderate }
        else                                          { broll = .heavy }

        // Override-aware shortfall — the creator asked HIGH (More food / Mostly food) but the cut landed
        // under HALF the resolved ask. Coverage measured over kept TALKING time (the target's own
        // denominator), so the comparison is apples-to-apples.
        let askedHeavy = brief?.brollLean == .moreFood || brief?.brollLean == .brollHeavy
        let keptTalking = store.order.reduce(0.0) { acc, c in
            (store.segment(c.sourceSegmentId)?.sceneType == .talkingHead) ? acc + c.timelineDuration : acc
        }
        let talkCover = keptTalking > 0 ? laneSeconds / keptTalking : 0
        brollAskShortfall = askedHeavy && store.brollCoverageTarget > 0
            && talkCover < store.brollCoverageTarget * 0.5

        // Real seconds trimmed away from kept spine clips (source full length − used slice). No inflation.
        var trimmed = 0.0
        for c in store.order {
            if let s = store.segment(c.sourceSegmentId) {
                trimmed += max(0, (s.endSeconds - s.startSeconds) - c.sourceDuration)
            }
        }
        secondsTrimmed = Int(trimmed.rounded())

        // Section tally — recomputed from Segment.section on kept ids (spine ∪ b-roll pool). NOT string-parsed.
        let keptIds = Set(store.order.map(\.sourceSegmentId)).union(store.brollClips)
        func count(_ sec: VideoSection) -> Int { keptIds.filter { store.segment($0)?.section == sec }.count }
        introKept = count(.intro); middleKept = count(.middle); endKept = count(.end)
        var missing: [VideoSection] = []
        for sec in [VideoSection.intro, .middle, .end] where plan.segments.contains(where: { $0.section == sec }) && count(sec) == 0 {
            missing.append(sec)
        }
        missingSections = missing
    }

    private static func composeHookWhy(for seg: Segment?) -> String {
        guard let seg else { return "" }
        let d = seg.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !d.isEmpty { return d }
        switch seg.sceneType {
        case .foodCloseup:  return "A tight food close-up — it hits before the viewer can scroll."
        case .biteReaction: return "A real reaction up front — a face is what stops the scroll."
        default:            return "Your strongest opening moment in this footage."
        }
    }

    // MARK: - Composed, honest one-liners the view drops in directly

    var brollLabel: String { broll.label }
    var lengthReadLine: String { length.line }

    /// Whether the cut ended up with little/no b-roll. Honest framing (2026-07-14): b-roll amount is
    /// bounded by how much food-cutaway footage exists to layer over the talking — a light result isn't
    /// a miss, it's what the footage supported, and it's hand-editable in Polish. Surfaced so The Read
    /// can say so instead of letting "Light" read as a broken promise against a survey pick.
    var brollIsLight: Bool { broll == .none || broll == .light }

    /// The map's shape line, honest about whether/where the payoff lands.
    var shapeLine: String {
        let head = "Hook in 1s → variety keeps the eye"
        switch payoff {
        case .late:   return head + " → payoff before the drop."
        case .buried: return head + " → payoff lands mid-video."
        case .absent: return head + " → no clear verdict beat yet."
        }
    }

    /// The sticky recap line — restates only what the reads actually show.
    var recapLine: String {
        var parts: [String] = []
        switch scrollStop {
        case .strong:            parts.append("Strong open")
        case .solid:             parts.append("Solid open")
        case .workable, .none:   parts.append("A quick open")
        }
        switch pace {
        case .punchy:  parts.append("a punchy middle")
        case .good:    parts.append("a steady middle")
        case .relaxed: parts.append("an easy middle")
        case .unknown: break
        }
        switch payoff {
        case .late:   parts.append("a verdict to close")
        case .buried: parts.append("a verdict mid-way")
        case .absent: break
        }
        return parts.joined(separator: ", ") + "."
    }

    /// "~28s · target ~30s" helper for the dark card.
    var lengthTitle: String { "~\(Int(totalDuration.rounded()))s" }
    var targetTitle: String { targetDuration > 0 ? "target ~\(Int(targetDuration.rounded()))s" : "" }
    var onTarget: Bool { targetDuration > 0 && abs(totalDuration - targetDuration) < 3 }
}
