import Foundation

// MARK: - Scene taxonomy

/// The 7 exact `scene_type` values from the tested Gemini prompt (+ an `.unknown` fallback so a
/// surprise value never crashes decoding).
enum SceneType: String, Decodable, CaseIterable, Equatable {
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

// MARK: - Segment

/// One analyzed segment of the raw video. Mirrors the tested prompt's schema exactly.
struct Segment: Decodable, Identifiable, Equatable {
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
    }

    /// Memberwise initializer kept for previews / tests.
    init(id: Int, startSeconds: Double, endSeconds: Double, sceneType: SceneType,
         description: String, hookScore: Double, keep: Bool, trimToSeconds: Double?,
         voiceoverCandidate: Bool, voiceoverReason: String?, confidence: Double, editNote: String) {
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
    }

    /// True when the AI was unsure enough that the doc says we should flag for review (~0.7).
    var isLowConfidence: Bool { confidence < 0.7 }
}

// MARK: - Edit Plan (the data contract)

/// The canonical object Gemini returns and the whole app is built around. Analysis produces it;
/// the review UI edits a working copy of it (in `EditPlanStore`); assembly consumes it.
struct EditPlan: Decodable, Equatable {
    let videoSummary: String
    let recommendedHook: String
    let recommendedDuration: Double
    let finalEditOrder: [Int]
    let segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case videoSummary = "video_summary"
        case recommendedHook = "recommended_hook"
        case recommendedDuration = "recommended_duration"
        case finalEditOrder = "final_edit_order"
        case segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoSummary        = (try? c.decode(String.self, forKey: .videoSummary)) ?? ""
        recommendedHook     = (try? c.decode(String.self, forKey: .recommendedHook)) ?? ""
        recommendedDuration = try c.lenientDouble(.recommendedDuration) ?? 0
        finalEditOrder      = (try? c.decode([Int].self, forKey: .finalEditOrder)) ?? []
        segments            = (try? c.decode([Segment].self, forKey: .segments)) ?? []
    }

    init(videoSummary: String, recommendedHook: String, recommendedDuration: Double,
         finalEditOrder: [Int], segments: [Segment]) {
        self.videoSummary = videoSummary
        self.recommendedHook = recommendedHook
        self.recommendedDuration = recommendedDuration
        self.finalEditOrder = finalEditOrder
        self.segments = segments
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
        """
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
