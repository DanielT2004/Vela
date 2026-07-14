import Foundation

/// Deterministic, code-side repair of the **b-roll source-not-kept** failure — the one the lab proved is
/// (a) real and (b) *intermittent*, so a prompt rule can only lower its odds. This GUARANTEES it instead:
/// after Gemini answers, any b-roll overlay whose source clip is cut (or a talking-head, or the same clip
/// it covers) is **re-pointed to a kept, non-talking-head clip that depicts the same thing** — preferring a
/// clip of the same topic the speaker is talking about. If nothing valid exists to re-point to, the
/// placement is dropped (same as `EditPlanStore.seededLane` would have done, but now recorded).
///
/// Pure: returns a new `EditPlan` + a human-readable list of what it changed. The caller still validates
/// the ORIGINAL plan first, so we keep measuring how often the model breaks the rule (see AnalysisCoordinator).
enum EditPlanRepair {

    static func repairBroll(_ plan: EditPlan) -> (plan: EditPlan, actions: [String]) {
        guard !plan.brollPlacements.isEmpty else { return (plan, []) }
        let byId = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Candidate pool: kept, visual (non-talking-head) clips we can show over a face.
        let keptVisual = plan.segments.filter { $0.keep && $0.sceneType != .talkingHead }

        /// Best kept visual clip whose topic matches `topic` (highest hook score wins), excluding `overId`.
        func bestMatch(topic: String, excluding overId: Int) -> Segment? {
            guard !topic.isEmpty else { return nil }
            return keptVisual
                .filter { $0.id != overId && $0.topic.caseInsensitiveCompare(topic) == .orderedSame }
                .max { $0.hookScore < $1.hookScore }
        }
        /// Last-resort: any kept visual clip, preferring food close-ups, then by hook score.
        func anyVisual(excluding overId: Int) -> Segment? {
            keptVisual.filter { $0.id != overId }.max { a, b in
                func rank(_ s: Segment) -> Double { (s.sceneType == .foodCloseup ? 100 : 0) + s.hookScore }
                return rank(a) < rank(b)
            }
        }

        var actions: [String] = []
        var repaired: [BrollPlacement] = []

        for p in plan.brollPlacements {
            let src = byId[p.brollSegmentId]
            let valid = src != nil && src!.keep && src!.sceneType != .talkingHead && p.brollSegmentId != p.overSegmentId
            if valid { repaired.append(p); continue }

            // Why was it broken? (for the log)
            let why = src == nil ? "missing"
                : (src!.keep == false ? "cut (keep:false)"
                : (src!.sceneType == .talkingHead ? "talking-head"
                : "same as over-segment"))

            // Re-point: prefer a kept clip of the topic being TALKED ABOUT (the over-segment's topic), then
            // the original source's topic, then any kept visual.
            let overTopic = byId[p.overSegmentId]?.topic ?? ""
            let srcTopic = src?.topic ?? ""
            let target = bestMatch(topic: overTopic, excluding: p.overSegmentId)
                ?? bestMatch(topic: srcTopic, excluding: p.overSegmentId)
                ?? anyVisual(excluding: p.overSegmentId)

            if let target {
                repaired.append(BrollPlacement(overSegmentId: p.overSegmentId, brollSegmentId: target.id,
                                               startOffsetSeconds: p.startOffsetSeconds,
                                               durationSeconds: p.durationSeconds, reason: p.reason))
                actions.append("over seg \(p.overSegmentId): source \(p.brollSegmentId) was \(why) → re-pointed to seg \(target.id) [\(target.sceneType.rawValue), topic \"\(target.topic)\"]")
            } else {
                actions.append("over seg \(p.overSegmentId): source \(p.brollSegmentId) was \(why) → dropped (no kept visual clip to re-point to)")
            }
        }

        let newPlan = EditPlan(videoSummary: plan.videoSummary, recommendedHook: plan.recommendedHook,
                               recommendedDuration: plan.recommendedDuration, finalEditOrder: plan.finalEditOrder,
                               segments: plan.segments, styleMatchNotes: plan.styleMatchNotes,
                               brollPlacements: repaired)
        return (newPlan, actions)
    }

    // MARK: - Coverage gap fill

    /// Ignore sub-`minGap` holes (Gemini timestamps are ±0.5s noise); split filled gaps into ≤15s pieces
    /// (the same cap the normalizer enforces on real shots, so the validator never flags the fill).
    private static let minGap = 1.0
    private static let maxPiece = 15.0

    /// Deterministic COVERAGE repair — **every second the creator shot must reach the Sort deck.** The
    /// prompt demands gap-free segments, but the model breaks the rule intermittently and the validator
    /// only MEASURES it — so footage in a hole (before the first segment, between segments, after the
    /// last) was invisible app-wide. Each hole becomes a synthesized "unanalyzed" segment: `keep: false`
    /// (→ the Cut Tray, never silently on the spine — the creator decides) with `confidence: 0`, which
    /// the Sort card renders as "Your call" instead of "Suggested cut". Pure; returns the new plan plus
    /// human-readable actions for the log / eval bundle. `proxyDuration ≤ 0` (a resumed run with no
    /// metadata) fills only interior gaps — the tail can't be known.
    static func fillCoverageGaps(_ plan: EditPlan, proxyDuration: Double) -> (plan: EditPlan, actions: [String]) {
        guard !plan.segments.isEmpty else { return (plan, []) }

        // Union of the covered timeline (segments may overlap — merge intervals first).
        let spans = plan.segments.map { (max(0, $0.startSeconds), max(0, $0.endSeconds)) }
            .filter { $0.1 > $0.0 }
            .sorted { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for s in spans {
            if var last = merged.last, s.0 <= last.1 + 0.01 {
                last.1 = max(last.1, s.1); merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }

        // The holes: before the first span, between spans, after the last (when the duration is known).
        var gaps: [(Double, Double)] = []
        var cursor = 0.0
        for m in merged {
            if m.0 - cursor >= minGap { gaps.append((cursor, m.0)) }
            cursor = max(cursor, m.1)
        }
        if proxyDuration > 0, proxyDuration - cursor >= minGap { gaps.append((cursor, proxyDuration)) }
        guard !gaps.isEmpty else { return (plan, []) }

        var actions: [String] = []
        var nextId = (plan.segments.map(\.id).max() ?? -1) + 1
        var filler: [Segment] = []
        for (a, b) in gaps {
            let n = Int(((b - a) / maxPiece).rounded(.up))
            let step = (b - a) / Double(n)
            for i in 0..<n {
                let start = a + Double(i) * step
                let end = (i == n - 1) ? b : start + step
                filler.append(Segment(
                    id: nextId, startSeconds: start, endSeconds: end, sceneType: .unknown,
                    description: "Footage Vela couldn't analyze", hookScore: 0, keep: false,
                    trimToSeconds: nil, voiceoverCandidate: false, voiceoverReason: nil, confidence: 0,
                    editNote: "Vela couldn't read this part of your footage — watch it and decide."))
                nextId += 1
            }
            actions.append("filled \(fmt(b - a))s hole (\(fmt(a)) → \(fmt(b))) with \(n) review segment(s)")
        }

        let newPlan = EditPlan(videoSummary: plan.videoSummary, recommendedHook: plan.recommendedHook,
                               recommendedDuration: plan.recommendedDuration, finalEditOrder: plan.finalEditOrder,
                               segments: plan.segments + filler, styleMatchNotes: plan.styleMatchNotes,
                               brollPlacements: plan.brollPlacements)
        return (newPlan, actions)
    }

    private static func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
}

#if DEBUG
extension EditPlanRepair {
    /// Self-check: the captured failure (b-roll sources 3/18/19 cut while same-topic close-ups are kept)
    /// should re-point to kept clips and leave zero cut sources. Logs ✅/❌ on a debug launch.
    @discardableResult
    static func selfCheck() -> Bool {
        func seg(_ id: Int, _ type: SceneType, keep: Bool, topic: String, hook: Double = 5) -> Segment {
            Segment(id: id, startSeconds: Double(id), endSeconds: Double(id) + 1, sceneType: type,
                    description: "", hookScore: hook, keep: keep, trimToSeconds: nil,
                    voiceoverCandidate: false, voiceoverReason: nil, confidence: 1, editNote: "",
                    section: .middle, topic: topic)
        }
        let segs = [
            seg(3, .foodCloseup, keep: false, topic: "Chicken Sandwich"),   // cut source
            seg(4, .foodCloseup, keep: true,  topic: "Chicken Sandwich", hook: 9), // kept same-topic → target
            seg(26, .talkingHead, keep: true, topic: "Chicken Sandwich"),   // over (talking about chicken)
        ]
        let plan = EditPlan(videoSummary: "", recommendedHook: "", recommendedDuration: 0,
                            finalEditOrder: [26], segments: segs, styleMatchNotes: nil,
                            brollPlacements: [BrollPlacement(overSegmentId: 26, brollSegmentId: 3,
                                                             startOffsetSeconds: 1, durationSeconds: 2, reason: nil)])
        let (fixed, actions) = repairBroll(plan)
        let byId = Dictionary(fixed.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let stillBroken = fixed.brollPlacements.contains { byId[$0.brollSegmentId]?.keep == false }
        let rePointedToKeptSameTopic = fixed.brollPlacements.first?.brollSegmentId == 4
        let ok = !stillBroken && rePointedToKeptSameTopic && actions.count == 1
        Log.app(ok ? "✅ EditPlanRepair.selfCheck passed (re-pointed cut b-roll source → kept same-topic clip)"
                   : "❌ EditPlanRepair.selfCheck FAILED — \(actions)")
        return ok
    }

    /// Self-check for the coverage fill: segments [0,10]+[10,20]+[40,50] in a 60s proxy → a 20s interior
    /// hole (2 pieces) and a 10s tail hole (1 piece), all keep:false / confidence 0, union = full 60s.
    @discardableResult
    static func coverageSelfCheck() -> Bool {
        func seg(_ id: Int, _ a: Double, _ b: Double) -> Segment {
            Segment(id: id, startSeconds: a, endSeconds: b, sceneType: .talkingHead, description: "",
                    hookScore: 5, keep: true, trimToSeconds: nil, voiceoverCandidate: false,
                    voiceoverReason: nil, confidence: 1, editNote: "", section: .middle, topic: "")
        }
        let plan = EditPlan(videoSummary: "", recommendedHook: "", recommendedDuration: 0,
                            finalEditOrder: [0, 1, 2],
                            segments: [seg(0, 0, 10), seg(1, 10, 20), seg(2, 40, 50)],
                            styleMatchNotes: nil, brollPlacements: [])
        let (fixed, actions) = fillCoverageGaps(plan, proxyDuration: 60)
        let filler = fixed.segments.filter { $0.confidence == 0 && !$0.keep }
        let covered = fixed.segments.sorted { $0.startSeconds < $1.startSeconds }
            .reduce((0.0, 0.0)) { acc, s in (max(acc.0, s.endSeconds), acc.1 + max(0, s.endSeconds - max(s.startSeconds, acc.0))) }.1
        let ok = filler.count == 3 && abs(covered - 60) < 0.01 && actions.count == 2
            && filler.allSatisfy { $0.endSeconds - $0.startSeconds <= 15.01 }
        Log.app(ok ? "✅ EditPlanRepair.coverageSelfCheck passed (2 holes → 3 review segments, full 60s covered)"
                   : "❌ EditPlanRepair.coverageSelfCheck FAILED — filler \(filler.count), covered \(covered), \(actions)")
        return ok
    }
}
#endif
