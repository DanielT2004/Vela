import Foundation

/// **Phase 1 — measure, don't repair.** A pure check of an `EditPlan` against the prompt's own HARD
/// CONSTRAINTS (GeminiPrompt.swift) plus the b-roll legality rules `EditPlanStore.seededLane` enforces
/// silently. It NEVER mutates the plan — it returns a `Report` (a 0…1 score + a list of `Violation`s)
/// that we log and drop into the run's eval bundle as `validation.json`. The point of this round is to
/// learn *how often* and *which* rules Gemini actually breaks before deciding whether to auto-repair.
///
/// The same rules are mirrored in `tools/promptlab` (the off-device lab) so a saved `plan.json` scores
/// identically there. Keep the two in lockstep if you change a check.
enum EditPlanValidator {

    /// One rule break. `Codable` so the whole report serializes to `validation.json` verbatim.
    struct Violation: Codable, Equatable {
        enum Kind: String, Codable {
            case segmentTooLong          // > 15s (hard constraint)
            case nonPositiveDuration     // end <= start
            case endBeyondVideo          // end > proxy duration
            case invalidTrim             // trim_to_seconds outside (start, end]
            case coverageGap             // a hole between consecutive segments / before the first / after the last
            case coverageOverlap         // two segments cover the same second
            case unknownSceneType        // scene_type decoded to .unknown
            case unknownSection          // section decoded to .unknown
            case orderRefersToCut        // final_edit_order id whose segment is keep:false
            case orderRefersToMissing    // final_edit_order id with no matching segment
            case orderDuplicate          // an id appears twice in final_edit_order
            case brollOverMissing        // over_segment_id not found
            case brollOverNotKept        // over segment is keep:false
            case brollOverNotTalkingHead // over segment isn't a talking-head (face to cover)
            case brollSourceMissing      // broll_segment_id not found
            case brollSourceNotKept      // source segment is keep:false
            case brollSourceIsTalkingHead// source is a talking-head (would cover a face with a face)
            case brollSameAsOver         // source == over (covering a clip with itself)
            case brollWindowOutOfRange   // offset/duration falls outside the over-segment window
            case brollDuplicateSource    // the same source used by more than one placement (identical frames replay)
        }
        let kind: Kind
        let severity: String   // "high" | "medium" | "low"
        let detail: String
        let segmentId: Int?
    }

    /// The full result. Counts are included so `meta.json` / the lab CSV can read them without re-deriving.
    struct Report: Codable, Equatable {
        let score: Double            // 1.0 = clean; drops with each weighted violation
        let violations: [Violation]
        let summary: String          // one-line, console-friendly
        let segmentCount: Int
        let keptCount: Int
        let coverageSeconds: Double  // union of segment spans actually covered
        let proxyDuration: Double    // 0 when unknown (e.g. a resumed run with no metadata)
        /// Planned b-roll coverage — overlay seconds ÷ KEPT talking-on-camera seconds (trims respected);
        /// 0 when no talking is kept. Same denominator as the style block's coverage target and the
        /// seeding cap, so style conformance is one comparison. Additive key in validation.json.
        let plannedBrollPct: Double
    }

    /// Seconds of slop we tolerate before calling something a gap/overlap/over-length. Gemini's timestamps
    /// are coarse (~±0.5s), so a tight tolerance would flag noise; 0.25s keeps real holes visible.
    private static let tol = 0.25

    static func validate(_ plan: EditPlan, proxyDuration: Double) -> Report {
        var v: [Violation] = []
        let segs = plan.segments
        let byId = Dictionary(segs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // MARK: per-segment shape
        for s in segs {
            let len = s.endSeconds - s.startSeconds
            if len > 15 + tol {
                v.append(.init(kind: .segmentTooLong, severity: "high",
                               detail: "segment \(s.id) is \(fmt(len))s (> 15s cap)", segmentId: s.id))
            }
            if s.endSeconds <= s.startSeconds {
                v.append(.init(kind: .nonPositiveDuration, severity: "high",
                               detail: "segment \(s.id) end \(fmt(s.endSeconds)) ≤ start \(fmt(s.startSeconds))", segmentId: s.id))
            }
            if proxyDuration > 0, s.endSeconds > proxyDuration + tol {
                v.append(.init(kind: .endBeyondVideo, severity: "high",
                               detail: "segment \(s.id) ends at \(fmt(s.endSeconds))s but the video is \(fmt(proxyDuration))s", segmentId: s.id))
            }
            if let t = s.trimToSeconds, !(t > s.startSeconds && t <= s.endSeconds + tol) {
                v.append(.init(kind: .invalidTrim, severity: "medium",
                               detail: "segment \(s.id) trim_to_seconds \(fmt(t)) is outside (\(fmt(s.startSeconds)), \(fmt(s.endSeconds))]", segmentId: s.id))
            }
            if s.sceneType == .unknown {
                v.append(.init(kind: .unknownSceneType, severity: "low",
                               detail: "segment \(s.id) has an unrecognised scene_type", segmentId: s.id))
            }
            if s.section == .unknown {
                v.append(.init(kind: .unknownSection, severity: "low",
                               detail: "segment \(s.id) has an unrecognised section", segmentId: s.id))
            }
        }

        // MARK: coverage (gaps / overlaps over the whole timeline)
        let ordered = segs.sorted { $0.startSeconds < $1.startSeconds }
        var coverage = 0.0
        if let first = ordered.first {
            if first.startSeconds > tol {
                v.append(.init(kind: .coverageGap, severity: "medium",
                               detail: "a \(fmt(first.startSeconds))s hole before the first segment", segmentId: first.id))
            }
            var prevEnd = first.startSeconds
            for s in ordered {
                let gap = s.startSeconds - prevEnd
                if gap > tol {
                    v.append(.init(kind: .coverageGap, severity: "medium",
                                   detail: "\(fmt(gap))s gap before segment \(s.id) (\(fmt(prevEnd)) → \(fmt(s.startSeconds)))", segmentId: s.id))
                } else if gap < -tol {
                    v.append(.init(kind: .coverageOverlap, severity: "medium",
                                   detail: "segment \(s.id) overlaps the previous by \(fmt(-gap))s", segmentId: s.id))
                }
                coverage += max(0, s.endSeconds - max(s.startSeconds, prevEnd))
                prevEnd = max(prevEnd, s.endSeconds)
            }
            if proxyDuration > 0, proxyDuration - prevEnd > tol {
                v.append(.init(kind: .coverageGap, severity: "medium",
                               detail: "\(fmt(proxyDuration - prevEnd))s of video after the last segment is uncovered", segmentId: nil))
            }
        }

        // MARK: final_edit_order ⊆ keep:true, no dupes
        var seen = Set<Int>()
        for id in plan.finalEditOrder {
            if !seen.insert(id).inserted {
                v.append(.init(kind: .orderDuplicate, severity: "medium",
                               detail: "segment \(id) appears more than once in final_edit_order", segmentId: id))
            }
            guard let s = byId[id] else {
                v.append(.init(kind: .orderRefersToMissing, severity: "high",
                               detail: "final_edit_order lists segment \(id), which doesn't exist", segmentId: id))
                continue
            }
            if !s.keep {
                v.append(.init(kind: .orderRefersToCut, severity: "high",
                               detail: "final_edit_order includes segment \(id), which is marked keep:false", segmentId: id))
            }
        }

        // MARK: b-roll legality (mirrors EditPlanStore.seededLane's silent filters)
        var seenBrollSources = Set<Int>()
        for p in plan.brollPlacements {
            if !seenBrollSources.insert(p.brollSegmentId).inserted {
                v.append(.init(kind: .brollDuplicateSource, severity: "medium",
                               detail: "b-roll source segment \(p.brollSegmentId) is used more than once (identical frames replay)", segmentId: p.brollSegmentId))
            }
            let over = byId[p.overSegmentId]
            if over == nil {
                v.append(.init(kind: .brollOverMissing, severity: "high",
                               detail: "b-roll over_segment_id \(p.overSegmentId) doesn't exist", segmentId: p.overSegmentId))
            } else {
                if over!.keep == false {
                    v.append(.init(kind: .brollOverNotKept, severity: "high",
                                   detail: "b-roll covers segment \(p.overSegmentId), which is cut", segmentId: p.overSegmentId))
                }
                if over!.sceneType != .talkingHead {
                    v.append(.init(kind: .brollOverNotTalkingHead, severity: "medium",
                                   detail: "b-roll covers segment \(p.overSegmentId) (\(over!.sceneType.rawValue)), not a talking-head", segmentId: p.overSegmentId))
                }
            }
            let src = byId[p.brollSegmentId]
            if src == nil {
                v.append(.init(kind: .brollSourceMissing, severity: "high",
                               detail: "b-roll broll_segment_id \(p.brollSegmentId) doesn't exist", segmentId: p.brollSegmentId))
            } else {
                if src!.keep == false {
                    v.append(.init(kind: .brollSourceNotKept, severity: "high",
                                   detail: "b-roll source segment \(p.brollSegmentId) is cut", segmentId: p.brollSegmentId))
                }
                if src!.sceneType == .talkingHead {
                    v.append(.init(kind: .brollSourceIsTalkingHead, severity: "medium",
                                   detail: "b-roll source segment \(p.brollSegmentId) is a talking-head", segmentId: p.brollSegmentId))
                }
            }
            if p.overSegmentId == p.brollSegmentId {
                v.append(.init(kind: .brollSameAsOver, severity: "high",
                               detail: "b-roll source equals the segment it covers (\(p.overSegmentId))", segmentId: p.overSegmentId))
            }
            if let over {
                let window = over.endSeconds - over.startSeconds
                if p.startOffsetSeconds < -tol || p.startOffsetSeconds + p.durationSeconds > window + tol {
                    v.append(.init(kind: .brollWindowOutOfRange, severity: "medium",
                                   detail: "b-roll on segment \(p.overSegmentId): offset \(fmt(p.startOffsetSeconds)) + dur \(fmt(p.durationSeconds)) exceeds the \(fmt(window))s clip", segmentId: p.overSegmentId))
                }
            }
        }

        // MARK: score — start at 1.0, subtract weighted penalties, clamp to [0, 1].
        let penalty = v.reduce(0.0) { acc, x in
            switch x.severity {
            case "high":   return acc + 0.15
            case "medium": return acc + 0.07
            default:       return acc + 0.0
            }
        }
        let score = max(0, min(1, 1 - penalty))
        let kept = segs.filter { $0.keep }.count
        let summary = v.isEmpty
            ? "Plan valid — \(segs.count) segments, score 1.00"
            : "score \(fmt(score)) — \(v.count) violation(s): " + tally(v)

        // MARK: planned b-roll coverage — the A/B metric: overlay seconds over KEPT talking-on-camera
        // seconds. Each talking segment counts its kept window (a valid trim shortens it); placements
        // count their raw durations (legality issues are flagged above, not re-litigated here).
        let keptTalking = segs.filter { $0.keep && $0.sceneType == .talkingHead }.reduce(0.0) { acc, s in
            let end = (s.trimToSeconds.flatMap { $0 > s.startSeconds && $0 <= s.endSeconds + tol ? min($0, s.endSeconds) : nil }) ?? s.endSeconds
            return acc + max(0, end - s.startSeconds)
        }
        let overlaySeconds = plan.brollPlacements.reduce(0.0) { $0 + max(0, $1.durationSeconds) }
        let plannedBrollPct = keptTalking > 0 ? overlaySeconds / keptTalking : 0

        return Report(score: score, violations: v, summary: summary,
                      segmentCount: segs.count, keptCount: kept,
                      coverageSeconds: coverage, proxyDuration: proxyDuration,
                      plannedBrollPct: plannedBrollPct)
    }

    // MARK: helpers
    private static func fmt(_ d: Double) -> String { String(format: "%.2f", d) }

    private static func tally(_ v: [Violation]) -> String {
        Dictionary(grouping: v, by: { $0.kind })
            .map { "\($0.key.rawValue)×\($0.value.count)" }
            .sorted()
            .joined(separator: ", ")
    }
}

#if DEBUG
extension EditPlanValidator {
    /// Stand-in for an XCTest target (this project has none). Runs the clean / dirty / empty fixtures and
    /// logs pass/fail. Call once on a debug launch (or from the Home debug card) to get the green signal.
    @discardableResult
    static func selfCheck() -> Bool {
        var ok = true
        func expect(_ cond: Bool, _ what: String) {
            if !cond { ok = false; Log.app("❌ validator selfCheck: \(what)") }
        }

        // CLEAN — three contiguous segments tiling [0,15], a legal b-roll, order ⊆ kept. Expect score 1.0.
        let clean = makePlan(
            segments: [
                seg(1, 0, 5, .talkingHead, keep: true, section: .intro),
                seg(2, 5, 10, .foodCloseup, keep: true, section: .middle),
                seg(3, 10, 15, .talkingHead, keep: true, section: .end),
            ],
            order: [1, 2, 3],
            broll: [broll(over: 1, source: 2, offset: 1, dur: 2)])
        let rc = validate(clean, proxyDuration: 15)
        expect(rc.violations.isEmpty && rc.score == 1.0, "clean fixture should be empty/1.0, got \(rc.summary)")
        // Kept talking = seg 1 (5s) + seg 3 (5s) = 10s; one 2s placement → 20% planned coverage.
        expect(abs(rc.plannedBrollPct - 0.2) < 0.001, "clean fixture plannedBrollPct should be 0.2, got \(rc.plannedBrollPct)")

        // DIRTY — exactly three breaks: a 16s segment, a 0.5s gap before seg 3, and an order id (2) cut.
        let dirty = makePlan(
            segments: [
                seg(1, 0, 16, .talkingHead, keep: true, section: .intro),   // segmentTooLong
                seg(2, 16, 20, .foodCloseup, keep: false, section: .middle),// cut → referenced by order
                seg(3, 20.5, 24, .talkingHead, keep: true, section: .end),  // 0.5s gap (20 → 20.5)
            ],
            order: [1, 2, 3],                                                // 2 is keep:false → orderRefersToCut
            broll: [])
        let rd = validate(dirty, proxyDuration: 24)
        let kinds = Set(rd.violations.map { $0.kind })
        expect(rd.violations.count == 3, "dirty fixture should have exactly 3 violations, got \(rd.violations.count): \(rd.summary)")
        expect(kinds == [.segmentTooLong, .coverageGap, .orderRefersToCut], "dirty fixture kinds mismatch: \(kinds)")

        // EMPTY — no segments. Should not crash; score stays 1.0 (nothing to break).
        let empty = makePlan(segments: [], order: [], broll: [])
        let re = validate(empty, proxyDuration: 0)
        expect(re.segmentCount == 0, "empty fixture should report 0 segments")

        // DUPLICATE SOURCE — the same b-roll source on two placements → exactly one brollDuplicateSource.
        let dup = makePlan(
            segments: [
                seg(1, 0, 5, .talkingHead, keep: true, section: .intro),
                seg(2, 5, 10, .foodCloseup, keep: true, section: .middle),
                seg(3, 10, 15, .talkingHead, keep: true, section: .end),
            ],
            order: [1, 2, 3],
            broll: [broll(over: 1, source: 2, offset: 1, dur: 2), broll(over: 3, source: 2, offset: 1, dur: 2)])
        let rdup = validate(dup, proxyDuration: 15)
        expect(rdup.violations.filter { $0.kind == .brollDuplicateSource }.count == 1,
               "dup fixture should flag exactly one brollDuplicateSource, got \(rdup.summary)")

        Log.app(ok ? "✅ EditPlanValidator.selfCheck passed (clean/dirty/empty)"
                   : "❌ EditPlanValidator.selfCheck FAILED — see ❌ lines above")
        return ok
    }

    // tiny fixture builders (kept here so they don't ship in release)
    private static func seg(_ id: Int, _ start: Double, _ end: Double, _ type: SceneType,
                            keep: Bool, section: VideoSection) -> Segment {
        Segment(id: id, startSeconds: start, endSeconds: end, sceneType: type,
                description: "", hookScore: 0, keep: keep, trimToSeconds: nil,
                voiceoverCandidate: false, voiceoverReason: nil, confidence: 1,
                editNote: "", section: section, topic: "")
    }
    private static func broll(over: Int, source: Int, offset: Double, dur: Double) -> BrollPlacement {
        BrollPlacement(overSegmentId: over, brollSegmentId: source,
                       startOffsetSeconds: offset, durationSeconds: dur, reason: nil)
    }
    private static func makePlan(segments: [Segment], order: [Int], broll: [BrollPlacement]) -> EditPlan {
        EditPlan(videoSummary: "", recommendedHook: "", recommendedDuration: 0,
                 finalEditOrder: order, segments: segments, styleMatchNotes: nil,
                 brollPlacements: broll)
    }
}
#endif
