import Foundation

// MARK: - Scene taxonomy

/// The 7 exact `scene_type` values from the tested Gemini prompt (+ an `.unknown` fallback so a
/// surprise value never crashes decoding).
enum SceneType: String, Codable, CaseIterable, Equatable {
    case foodCloseup  = "food-closeup"
    case talkingHead  = "talking-head"
    case biteReaction = "bite-reaction"
    case plating      = "plating"
    case ambiance     = "ambiance"
    case wideShot     = "wide-shot"
    case transition   = "transition"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SceneType(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Short label shown on cards/blocks.
    var label: String {
        switch self {
        case .foodCloseup:  return "Food close-up"
        case .talkingHead:  return "Talking"
        case .biteReaction: return "Bite reaction"
        case .plating:      return "Plating"
        case .ambiance:     return "Ambiance"
        case .wideShot:     return "Wide shot"
        case .transition:   return "Transition"
        case .unknown:      return "Clip"
        }
    }

    /// Placeholder gradient tone for this scene type.
    var foodTone: FoodTone {
        switch self {
        case .foodCloseup:           return .cheese
        case .talkingHead, .unknown: return .talk
        case .biteReaction:          return .berry
        case .plating:               return .plate
        case .ambiance:              return .dough
        case .wideShot:              return .char
        case .transition:            return .herb
        }
    }
}

// MARK: - Section taxonomy

/// Which part of the FINAL video a segment belongs to. Mirrors `SceneType`'s defensive pattern: a
/// surprise/missing value decodes to `.unknown` so it never crashes. Drives section ordering in the
/// cut + the section dividers/badges in the editor.
enum VideoSection: String, Codable, CaseIterable, Equatable {
    case intro
    case middle
    case end
    case unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = VideoSection(rawValue: raw) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    /// Short label for section dividers / badges.
    var label: String {
        switch self {
        case .intro:   return "Intro"
        case .middle:  return "Middle"
        case .end:     return "End"
        case .unknown: return "Other"
        }
    }
}

// MARK: - Segment

/// One analyzed segment of the raw video. Mirrors the tested prompt's schema exactly.
struct Segment: Codable, Identifiable, Equatable {
    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    let sceneType: SceneType
    let description: String
    let hookScore: Double
    let keep: Bool
    let trimToSeconds: Double?
    let voiceoverCandidate: Bool
    let voiceoverReason: String?
    let confidence: Double
    let editNote: String
    let section: VideoSection
    /// The **content section** this clip belongs to — a short label naming what this part of the
    /// video is about (a dish like "Chicken Sandwich", or any chapter: "Arriving", "The verdict").
    /// Same-`topic` clips are grouped into contiguous sections in Triage + the Timeline. Empty when
    /// the model omits it or an older saved plan predates the field — grouping then no-ops (see
    /// `TopicGrouping`).
    let topic: String

    enum CodingKeys: String, CodingKey {
        case id
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case sceneType = "scene_type"
        case description
        case hookScore = "hook_score"
        case keep
        case trimToSeconds = "trim_to_seconds"
        case voiceoverCandidate = "voiceover_candidate"
        case voiceoverReason = "voiceover_reason"
        case confidence
        case editNote = "edit_note"
        case section
        case topic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = try c.lenientInt(.id) ?? 0
        startSeconds       = try c.lenientDouble(.startSeconds) ?? 0
        endSeconds         = try c.lenientDouble(.endSeconds) ?? 0
        sceneType          = (try? c.decode(SceneType.self, forKey: .sceneType)) ?? .unknown
        description        = (try? c.decode(String.self, forKey: .description)) ?? ""
        hookScore          = try c.lenientDouble(.hookScore) ?? 0
        keep               = (try? c.decode(Bool.self, forKey: .keep)) ?? true
        trimToSeconds      = try c.lenientDouble(.trimToSeconds)
        voiceoverCandidate = (try? c.decode(Bool.self, forKey: .voiceoverCandidate)) ?? false
        voiceoverReason    = (try? c.decodeIfPresent(String.self, forKey: .voiceoverReason)) ?? nil
        confidence         = try c.lenientDouble(.confidence) ?? 1
        editNote           = (try? c.decode(String.self, forKey: .editNote)) ?? ""
        section            = (try? c.decode(VideoSection.self, forKey: .section)) ?? .unknown
        topic              = (try? c.decode(String.self, forKey: .topic)) ?? ""
    }

    /// Memberwise initializer kept for previews / tests.
    init(id: Int, startSeconds: Double, endSeconds: Double, sceneType: SceneType,
         description: String, hookScore: Double, keep: Bool, trimToSeconds: Double?,
         voiceoverCandidate: Bool, voiceoverReason: String?, confidence: Double, editNote: String,
         section: VideoSection = .unknown, topic: String = "") {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.sceneType = sceneType
        self.description = description
        self.hookScore = hookScore
        self.keep = keep
        self.trimToSeconds = trimToSeconds
        self.voiceoverCandidate = voiceoverCandidate
        self.voiceoverReason = voiceoverReason
        self.confidence = confidence
        self.editNote = editNote
        self.section = section
        self.topic = topic
    }

    /// A synthetic segment for a camera-roll clip appended AFTER analysis (no Gemini). Covers the clip's
    /// full span on the re-merged proxy timeline; kept, neutral scene type, no AI metadata. Only
    /// `id`/`startSeconds`/`endSeconds` are read downstream (`makeClip`, `renderSlots`, `sourceLength`).
    static func imported(id: Int, startSeconds: Double, endSeconds: Double) -> Segment {
        Segment(id: id, startSeconds: startSeconds, endSeconds: max(startSeconds + 0.1, endSeconds),
                sceneType: .unknown, description: "", hookScore: 0, keep: true, trimToSeconds: nil,
                voiceoverCandidate: false, voiceoverReason: nil, confidence: 1, editNote: "")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startSeconds, forKey: .startSeconds)
        try c.encode(endSeconds, forKey: .endSeconds)
        try c.encode(sceneType, forKey: .sceneType)
        try c.encode(description, forKey: .description)
        try c.encode(hookScore, forKey: .hookScore)
        try c.encode(keep, forKey: .keep)
        try c.encode(trimToSeconds, forKey: .trimToSeconds)
        try c.encode(voiceoverCandidate, forKey: .voiceoverCandidate)
        try c.encode(voiceoverReason, forKey: .voiceoverReason)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(editNote, forKey: .editNote)
        try c.encode(section, forKey: .section)
        try c.encode(topic, forKey: .topic)
    }

    /// True when the AI was unsure enough that the doc says we should flag for review (~0.7).
    var isLowConfidence: Bool { confidence < 0.7 }
}

// MARK: - B-roll placement

/// One suggested B-roll overlay: play food close-up `brollSegmentId`'s video on top of the talking
/// segment `overSegmentId`, starting `startOffsetSeconds` into that segment, for `durationSeconds`.
/// Anchored to a segment + offset (NOT assembled-timeline seconds) because the spine doesn't exist
/// until `EditPlanStore` builds it — the store maps these onto the overlay lane. Decoded defensively
/// like `Segment`: a bad entry yields safe zeros and is dropped during seeding, never a crash.
struct BrollPlacement: Codable, Equatable {
    let overSegmentId: Int
    let brollSegmentId: Int
    let startOffsetSeconds: Double
    let durationSeconds: Double
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case overSegmentId = "over_segment_id"
        case brollSegmentId = "broll_segment_id"
        case startOffsetSeconds = "start_offset_seconds"
        case durationSeconds = "duration_seconds"
        case reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overSegmentId      = try c.lenientInt(.overSegmentId) ?? 0
        brollSegmentId     = try c.lenientInt(.brollSegmentId) ?? 0
        startOffsetSeconds = max(0, try c.lenientDouble(.startOffsetSeconds) ?? 0)
        durationSeconds    = try c.lenientDouble(.durationSeconds) ?? 0
        reason             = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
    }

    /// Memberwise initializer kept for previews / tests.
    init(overSegmentId: Int, brollSegmentId: Int, startOffsetSeconds: Double,
         durationSeconds: Double, reason: String? = nil) {
        self.overSegmentId = overSegmentId
        self.brollSegmentId = brollSegmentId
        self.startOffsetSeconds = startOffsetSeconds
        self.durationSeconds = durationSeconds
        self.reason = reason
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(overSegmentId, forKey: .overSegmentId)
        try c.encode(brollSegmentId, forKey: .brollSegmentId)
        try c.encode(startOffsetSeconds, forKey: .startOffsetSeconds)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        try c.encode(reason, forKey: .reason)
    }
}

// MARK: - Edit Plan (the data contract)

/// The canonical object Gemini returns and the whole app is built around. Analysis produces it;
/// the review UI edits a working copy of it (in `EditPlanStore`); assembly consumes it.
struct EditPlan: Codable, Equatable {
    let videoSummary: String
    let recommendedHook: String
    let recommendedDuration: Double
    let finalEditOrder: [Int]
    let segments: [Segment]
    /// Present only when an active style block was sent (M7) — the model's note on how well the footage
    /// matched the creator's style. Nil for a generic (no-style) edit.
    let styleMatchNotes: String?
    /// Suggested B-roll overlays the store seeds onto the Polish overlay lane. Empty when the model
    /// omits the field or an older saved plan predates it (lenient decode → `[]`).
    let brollPlacements: [BrollPlacement]

    enum CodingKeys: String, CodingKey {
        case videoSummary = "video_summary"
        case recommendedHook = "recommended_hook"
        case recommendedDuration = "recommended_duration"
        case finalEditOrder = "final_edit_order"
        case styleMatchNotes = "style_match_notes"
        case segments
        case brollPlacements = "broll_placements"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoSummary        = (try? c.decode(String.self, forKey: .videoSummary)) ?? ""
        recommendedHook     = (try? c.decode(String.self, forKey: .recommendedHook)) ?? ""
        recommendedDuration = try c.lenientDouble(.recommendedDuration) ?? 0
        finalEditOrder      = (try? c.decode([Int].self, forKey: .finalEditOrder)) ?? []
        styleMatchNotes     = try? c.decodeIfPresent(String.self, forKey: .styleMatchNotes)
        segments            = (try? c.decode([Segment].self, forKey: .segments)) ?? []
        brollPlacements     = (try? c.decode([BrollPlacement].self, forKey: .brollPlacements)) ?? []
    }

    init(videoSummary: String, recommendedHook: String, recommendedDuration: Double,
         finalEditOrder: [Int], segments: [Segment], styleMatchNotes: String? = nil,
         brollPlacements: [BrollPlacement] = []) {
        self.videoSummary = videoSummary
        self.recommendedHook = recommendedHook
        self.recommendedDuration = recommendedDuration
        self.finalEditOrder = finalEditOrder
        self.segments = segments
        self.styleMatchNotes = styleMatchNotes
        self.brollPlacements = brollPlacements
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(videoSummary, forKey: .videoSummary)
        try c.encode(recommendedHook, forKey: .recommendedHook)
        try c.encode(recommendedDuration, forKey: .recommendedDuration)
        try c.encode(finalEditOrder, forKey: .finalEditOrder)
        try c.encodeIfPresent(styleMatchNotes, forKey: .styleMatchNotes)
        try c.encode(segments, forKey: .segments)
        try c.encode(brollPlacements, forKey: .brollPlacements)
    }

    /// A compact, human-readable summary for the console (M4 logging).
    var debugSummary: String {
        let kept = segments.filter { $0.keep }.count
        let vo = segments.filter { $0.voiceoverCandidate }.count
        let lowConf = segments.filter { $0.isLowConfidence }.count
        return """
        EditPlan · \(segments.count) segments (\(kept) keep, \(vo) voiceover, \(lowConf) low-confidence)
          summary: \(videoSummary)
          hook:    \(recommendedHook)
          target:  \(Int(recommendedDuration))s
          order:   \(finalEditOrder)
          broll:   \(brollPlacements.count) suggested placement(s)
          style:   \(styleMatchNotes ?? "— (generic, no active style)")
        """
    }
}

// MARK: - Section invariant audit

extension EditPlan {
    /// Post-parse audit of the section invariants: how many kept segments land in each section, plus red
    /// flags when a must-have is missing (intro footage that got dropped, an untagged kept segment). Logged
    /// right after parse so a cut that silently lost the intro is visible; the user-facing notice (the
    /// "SECTION ANALYSIS" card) is surfaced separately. Pure read — never mutates the plan.
    var sectionAuditLine: String {
        let kept = segments.filter { $0.keep }
        func keptIn(_ s: VideoSection) -> Int { kept.filter { $0.section == s }.count }
        func footageHas(_ s: VideoSection) -> Bool { segments.contains { $0.section == s } }

        var flags: [String] = []
        if footageHas(.intro) && keptIn(.intro) == 0 { flags.append("⚠️ intro footage exists but none kept") }
        if footageHas(.end)   && keptIn(.end)   == 0 { flags.append("⚠️ no end/verdict kept") }
        let untagged = kept.filter { $0.section == .unknown }.count
        if untagged > 0 { flags.append("⚠️ \(untagged) kept segment(s) untagged") }

        let cov = "intro \(keptIn(.intro)) · middle \(keptIn(.middle)) · end \(keptIn(.end))"
        return flags.isEmpty ? "Sections kept — \(cov)" : "Sections kept — \(cov) — " + flags.joined(separator: "; ")
    }
}

// MARK: - Lenient decoding helpers

extension KeyedDecodingContainer {
    /// Decode a Double that may arrive as a number, a numeric string, or null/missing.
    func lenientDouble(_ key: Key) throws -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// Decode an Int that may arrive as an int, a double, or a numeric string.
    func lenientInt(_ key: Key) throws -> Int? {
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return i }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }
}

// MARK: - Parsing the raw model text

enum EditPlanParseError: LocalizedError {
    case noJSONObject
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noJSONObject:        return "Couldn't find a JSON object in Gemini's response."
        case .decodeFailed(let m): return "Couldn't read the edit plan: \(m)"
        }
    }
}

extension EditPlan {
    /// Turns the raw model output into an `EditPlan`, tolerating stray markdown fences or prose
    /// around the JSON (we ask for raw JSON, but parse defensively anyway).
    static func parse(fromRawModelText raw: String) throws -> EditPlan {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip a leading ```json / ``` fence and its closing fence if present.
        if s.hasPrefix("```") {
            if let firstNewline = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: firstNewline)...])
            }
            if let closing = s.range(of: "```", options: .backwards) {
                s = String(s[..<closing.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Take the substring from the first "{" to the last "}".
        guard let start = s.firstIndex(of: "{"),
              let end = s.lastIndex(of: "}"),
              start < end,
              let data = String(s[start...end]).data(using: .utf8) else {
            throw EditPlanParseError.noJSONObject
        }

        do {
            return try JSONDecoder().decode(EditPlan.self, from: data)
        } catch {
            throw EditPlanParseError.decodeFailed(error.localizedDescription)
        }
    }
}
