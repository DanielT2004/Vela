import Foundation

/// The **PERCEIVE** output — a flat, order-free DESCRIPTION of the footage that makes ZERO edit decisions.
/// Mirrors `tools/promptlab/perceive-schema.json` (the lab is the source of truth). Lenient-decoded exactly
/// like `EditPlan`/`Segment` (reusing their `lenientInt`/`lenientDouble` helpers) so a surprise value never
/// crashes. DECIDE reads this; the only code that ever touches it is the deterministic `ContentIndexNormalizer`.
enum ReactionKind: String, Codable, Equatable {
    case none
    case bite
    case firstTaste = "first_taste"
    case verdict
    case peakReaction = "peak_reaction"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ReactionKind(rawValue: raw) ?? .none
    }

    /// The b-roll COVER POLICY for a talking shot with this reaction — the ONE place the rule lives
    /// (consumed by `EditPlanAdapter`'s gate AND `EditPlanStore.seededLane`'s clamp; mirrored in
    /// `tools/promptlab/adapt-plan.mjs`). `nil` = NEVER coverable (a bite / the verdict IS the payoff);
    /// otherwise the minimum `start_offset_seconds` — a first_taste / peak_reaction keeps its first
    /// ~3s peak face-on, then the descriptive tail may be covered. Matches the DECIDE prompt's R3 rule.
    var minCoverOffset: Double? {
        switch self {
        case .bite, .verdict:            return nil
        case .firstTaste, .peakReaction: return 3.0
        case .none:                      return 0
        }
    }
}

/// One continuous visual on screen (the SUPPLY side). 1:1 with the app's `Segment` — same `id`/timestamps/
/// `scene_type`/`section`/`topic`/`description`/`hook_score` — plus the perceive-only fields DECIDE consumes.
struct Shot: Codable, Identifiable, Equatable {
    let id: Int
    let startSeconds: Double
    let endSeconds: Double
    let sceneType: SceneType
    let description: String
    /// The food/place this shot SHOWS (b-roll supply key); "" if it shows nothing reusable.
    let depictsSubject: String
    /// Other subjects visible in the same frame (a spread shot's secondary dishes).
    let alsoVisible: [String]
    let hasSpeech: Bool
    let section: VideoSection
    let topic: String
    let hookScore: Double
    let reactionKind: ReactionKind
    /// Objective defects: dead_air / duplicate_take / false_start / camera_adjust / audio_issue.
    let qualityFlags: [String]
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case id
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case sceneType = "scene_type"
        case description
        case depictsSubject = "depicts_subject"
        case alsoVisible = "also_visible"
        case hasSpeech = "has_speech"
        case section
        case topic
        case hookScore = "hook_score"
        case reactionKind = "reaction_kind"
        case qualityFlags = "quality_flags"
        case confidence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.lenientInt(.id) ?? 0
        startSeconds   = try c.lenientDouble(.startSeconds) ?? 0
        endSeconds     = try c.lenientDouble(.endSeconds) ?? 0
        sceneType      = (try? c.decode(SceneType.self, forKey: .sceneType)) ?? .unknown
        description    = (try? c.decode(String.self, forKey: .description)) ?? ""
        depictsSubject = (try? c.decode(String.self, forKey: .depictsSubject)) ?? ""
        alsoVisible    = (try? c.decode([String].self, forKey: .alsoVisible)) ?? []
        hasSpeech      = (try? c.decode(Bool.self, forKey: .hasSpeech)) ?? false
        section        = (try? c.decode(VideoSection.self, forKey: .section)) ?? .unknown
        topic          = (try? c.decode(String.self, forKey: .topic)) ?? ""
        hookScore      = try c.lenientDouble(.hookScore) ?? 0
        reactionKind   = (try? c.decode(ReactionKind.self, forKey: .reactionKind)) ?? .none
        qualityFlags   = (try? c.decode([String].self, forKey: .qualityFlags)) ?? []
        confidence     = try c.lenientDouble(.confidence) ?? 1
    }

    /// Memberwise init for the normalizer + self-checks.
    init(id: Int, startSeconds: Double, endSeconds: Double, sceneType: SceneType, description: String,
         depictsSubject: String, alsoVisible: [String], hasSpeech: Bool, section: VideoSection,
         topic: String, hookScore: Double, reactionKind: ReactionKind, qualityFlags: [String], confidence: Double) {
        self.id = id; self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.sceneType = sceneType
        self.description = description; self.depictsSubject = depictsSubject; self.alsoVisible = alsoVisible
        self.hasSpeech = hasSpeech; self.section = section; self.topic = topic; self.hookScore = hookScore
        self.reactionKind = reactionKind; self.qualityFlags = qualityFlags; self.confidence = confidence
    }

    /// Convenience: rebuild with new timestamps (the normalizer's split).
    func with(id: Int, startSeconds: Double, endSeconds: Double) -> Shot {
        Shot(id: id, startSeconds: startSeconds, endSeconds: endSeconds, sceneType: sceneType,
             description: description, depictsSubject: depictsSubject, alsoVisible: alsoVisible,
             hasSpeech: hasSpeech, section: section, topic: topic, hookScore: hookScore,
             reactionKind: reactionKind, qualityFlags: qualityFlags, confidence: confidence)
    }
}

/// One spoken sentence/phrase (the DEMAND side) — what's being said, anchored to the transcript.
struct TalkSpan: Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double
    let spokenText: String
    /// The subject the words are ABOUT right now (b-roll demand key); "" for generic chatter.
    let referencesSubject: String
    let alsoReferences: [String]
    let isToCamera: Bool

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case spokenText = "spoken_text"
        case referencesSubject = "references_subject"
        case alsoReferences = "also_references"
        case isToCamera = "is_to_camera"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds      = try c.lenientDouble(.startSeconds) ?? 0
        endSeconds        = try c.lenientDouble(.endSeconds) ?? 0
        spokenText        = (try? c.decode(String.self, forKey: .spokenText)) ?? ""
        referencesSubject = (try? c.decode(String.self, forKey: .referencesSubject)) ?? ""
        alsoReferences    = (try? c.decode([String].self, forKey: .alsoReferences)) ?? []
        isToCamera        = (try? c.decode(Bool.self, forKey: .isToCamera)) ?? false
    }

    init(startSeconds: Double, endSeconds: Double, spokenText: String, referencesSubject: String,
         alsoReferences: [String], isToCamera: Bool) {
        self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.spokenText = spokenText
        self.referencesSubject = referencesSubject; self.alsoReferences = alsoReferences; self.isToCamera = isToCamera
    }
}

struct ContentIndex: Codable, Equatable {
    let durationSeconds: Double
    let videoSummary: String
    let shots: [Shot]
    let talkSpans: [TalkSpan]

    enum CodingKeys: String, CodingKey {
        case durationSeconds = "duration_seconds"
        case videoSummary = "video_summary"
        case shots
        case talkSpans = "talk_spans"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        durationSeconds = try c.lenientDouble(.durationSeconds) ?? 0
        videoSummary    = (try? c.decode(String.self, forKey: .videoSummary)) ?? ""
        shots           = (try? c.decode([Shot].self, forKey: .shots)) ?? []
        talkSpans       = (try? c.decode([TalkSpan].self, forKey: .talkSpans)) ?? []
    }

    init(durationSeconds: Double, videoSummary: String, shots: [Shot], talkSpans: [TalkSpan]) {
        self.durationSeconds = durationSeconds; self.videoSummary = videoSummary
        self.shots = shots; self.talkSpans = talkSpans
    }

    /// Turns the raw PERCEIVE text into a `ContentIndex`, tolerating ```` ``` ```` fences / stray prose —
    /// mirrors `EditPlan.parse(fromRawModelText:)`.
    static func parse(fromRawModelText raw: String) throws -> ContentIndex {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end,
              let data = String(s[start...end]).data(using: .utf8) else {
            throw EditPlanParseError.noJSONObject
        }
        do { return try JSONDecoder().decode(ContentIndex.self, from: data) }
        catch { throw EditPlanParseError.decodeFailed(error.localizedDescription) }
    }
}
