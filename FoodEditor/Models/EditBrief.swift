import Foundation

// ============================================================================
// MARK: - EditBrief — the required per-video brief ("Anything special for this one?")
// ============================================================================
//
// The creator fills this in before EVERY edit (gated between the picker and processing). It's
// pre-filled from the active `StyleTemplate` so confirming the usual settings is one glance and the
// creator only spends thought on what's special about THIS video. The answers become a prepended
// prompt block (`BriefPromptBuilder.block`) sitting between the Style Block and the segmentation body.
//
// EVERY field here maps to a REAL lever the Gemini `editPlan` prompt actually returns and the assembler
// actually executes — target length (recommended_duration), an ordered opener (final_edit_order head +
// hook_score), a voiceover/b-roll lean (voiceover_candidate + broll_placements), keep-these-beats
// (keep:true), and trim-the-slow-stuff (trim_to_seconds). Things the app CANNOT produce — music,
// AI captions/text, "energy"/speed-ramps, CTA cards — are deliberately NOT here. Anything content-specific
// goes in `note`; Gemini watches the footage, so it honors lines like "keep where I say the price".
//
// // TODO (future "read the video first"): a quick pre-analysis pass could populate real spoken moments
// to tick, instead of the scene-type beats below. The struct is kept flat so that can slot in later.

struct EditBrief: Equatable {
    /// Which template this brief was pre-filled from (so the screen can detect a manual swap).
    var sourceTemplateId: UUID?

    var lengthSeconds: Int = 30          // → recommended_duration (slider 10…180)
    var hookSequence: [HookShot] = []    // ordered openers → top of final_edit_order + hook_score
    var maxScrollStopHook: Bool = true   // ON by default: AI opens on the most arresting moment (overrides hookSequence); creators toggle OFF for a fixed opener
    var brollLean: BrollLean = .balanced // → voiceover_candidate leaning + broll_placements coverage
    /// Creator will record a narration voiceover IN Vela after the cut (Polish → Voiceover tool) —
    /// distinct from the in-footage voiceover_candidate lean above. Steers DECIDE toward a cut that
    /// reads well under narration, and pre-arms the Polish page's voiceover nudge.
    var plansVoiceover: Bool = false
    var keepBeats: Set<KeepBeat> = []    // → keep:true + sensible placement
    var trimSlowParts: Bool = true       // → trim_to_seconds on weak heads/tails + keep:false on filler
    var note: String = ""                // free-text catch-all (content-specific asks, specific hook idea)

    // MARK: length banding (mirrors the design's helper copy)

    enum LengthBand { case punchy, standard, detailed, indepth }

    var lengthBand: LengthBand {
        switch lengthSeconds {
        case ..<20:  return .punchy
        case ...45:  return .standard
        case ...90:  return .detailed
        default:     return .indepth
        }
    }

    var lengthBandLabel: String {
        switch lengthBand {
        case .punchy:   return "Punchy"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        case .indepth:  return "In-depth"
        }
    }

    var lengthBandMessage: String {
        switch lengthBand {
        case .punchy:   return "Quick and scroll-stopping — straight to the good stuff."
        case .standard: return "Your usual rhythm — room to build to the payoff."
        case .detailed: return "Slower and fuller — every beat gets its moment."
        case .indepth:  return "A full walkthrough — recipe, story and all the detail."
        }
    }

    /// Display value, e.g. "~30s" or "~1m 30s".
    var lengthDisplay: String {
        let s = lengthSeconds
        if s < 60 { return "~\(s)s" }
        let m = s / 60, r = s % 60
        return r == 0 ? "~\(m)m" : "~\(m)m \(r)s"
    }

    // MARK: pre-fill

    /// Build a brief seeded from the active template's learned profile, with sensible fallbacks when
    /// there's no template. The video-specific fields (keep-beats, note) ALWAYS start empty so the
    /// creator gives them fresh thought; the "usual settings" (length, opener, lean) are pre-filled.
    static func prefilled(from template: StyleTemplate?) -> EditBrief {
        var b = EditBrief()
        b.sourceTemplateId = template?.id
        guard let p = template?.profile else { return b }

        let total = Int(p.pacing.totalLengthSeconds.rounded())
        if total > 0 { b.lengthSeconds = min(180, max(10, total)) }

        if let opener = HookShot(profileType: p.hook.type) { b.hookSequence = [opener] }
        // The template ANSWERS the b-roll question — the brief row states the learned style and offers
        // relative per-video overrides; ".matchStyle" resolves to the template's heaviness downstream.
        b.brollLean = .matchStyle
        // Narration-led creators (their posted videos are mostly voice over b-roll) almost certainly
        // narrate in post — default the voiceover plan ON from the fields the style learning already
        // captures. Vocabulary matches the extraction prompt's primary_mode enum.
        b.plansVoiceover = p.voiceover.primaryMode == "mostly-voiceover-over-broll"
            || p.voiceover.voiceoverRatio >= 0.6
        return b
    }
}

// ============================================================================
// MARK: - Grounded choices (display label + prompt phrasing + scene-type mapping)
// ============================================================================

/// An opening shot type. Maps to the `editPlan` scene-type vocabulary so Gemini can find a real segment
/// of this kind and boost its `hook_score`. Selected as an ORDERED list → back-to-back opener sequence.
enum HookShot: String, CaseIterable, Equatable {
    case foodCloseup, biteReaction, talking, plating, place

    var label: String {
        switch self {
        case .foodCloseup:  return "Food close-up"
        case .biteReaction: return "A bite / reaction"
        case .talking:      return "Me talking"
        case .plating:      return "Plating / the pour"
        case .place:        return "The place"
        }
    }

    /// The scene_type(s) this opener corresponds to (for the prompt).
    var sceneType: String {
        switch self {
        case .foodCloseup:  return "food-closeup"
        case .biteReaction: return "bite-reaction"
        case .talking:      return "talking-head"
        case .plating:      return "plating"
        case .place:        return "ambiance/wide-shot"
        }
    }

    /// Human phrasing for the brief prompt line.
    var phrasing: String {
        switch self {
        case .foodCloseup:  return "a tight food close-up"
        case .biteReaction: return "a bite or reaction"
        case .talking:      return "you delivering a spoken hook or claim"
        case .plating:      return "a plating or pour shot"
        case .place:        return "an establishing shot of the place"
        }
    }

    /// Map a learned profile hook type to an opener, or nil (let the AI pick).
    init?(profileType: String) {
        switch profileType {
        case "food-closeup":                 self = .foodCloseup
        case "bite-reaction":                self = .biteReaction
        case "talking-head-claim", "pov":    self = .talking
        case "plating", "action":            self = .plating
        default:                             return nil
        }
    }
}

/// How much to replace the creator's face with food b-roll while their voice keeps playing. Steers
/// the `broll_placements` coverage target + voiceover leaning. TWO vocabularies ("the template answers
/// the survey", STATE.md 2026-07-15): the ABSOLUTE cases are the no-template flow's question ("Mostly
/// me / A mix / Mostly food"); the RELATIVE cases are the template flow's per-video override, resolved
/// against the learned heaviness ("More me / My usual / More food" = usual ∓ 0.15, clamped). Relative
/// picks are per-video only — never written back into the template.
enum BrollLean: String, CaseIterable, Equatable {
    case onCamera, balanced, brollHeavy
    case matchStyle, moreMe, moreFood

    /// The no-template flow's absolute options (today's grid, unchanged).
    static let absoluteCases: [BrollLean] = [.onCamera, .balanced, .brollHeavy]
    /// The template flow's RELATIVE overrides, in display order.
    static let relativeCases: [BrollLean] = [.moreMe, .matchStyle, .moreFood]

    // Display-only (the prompt reads `phrasing`) — plain words a first-timer parses off vibes.
    var label: String {
        switch self {
        case .onCamera:   return "Mostly me"
        case .balanced:   return "A mix"
        case .brollHeavy: return "Mostly food"
        case .moreMe:     return "More me"
        case .matchStyle: return "My usual"
        case .moreFood:   return "More food"   // niche-coupled string — swap per niche at expansion
        }
    }

    var phrasing: String {
        switch self {
        case .onCamera:
            return "Keep the creator's face on camera: keep b-roll placements sparse, and mark a talking shot for voiceover only where the strict voiceover conditions clearly hold."
        case .balanced:
            return "Balance face-on-camera with food b-roll using your normal judgement."
        case .brollHeavy:
            return "Lean into food b-roll: wherever a talking shot qualifies under the strict voiceover conditions, mark it for voiceover and cover more of the talking with matching b-roll."
        case .matchStyle, .moreMe, .moreFood:
            // Relative leans never reach the prompt via this string — BriefPromptBuilder resolves them
            // against the template with real numbers. Defensive fallback = the balanced line.
            return "Balance face-on-camera with food b-roll using your normal judgement."
        }
    }

    /// Numeric coverage target for the coordinator's b-roll seeding cap, resolved against the active
    /// style's learned heaviness. `nil` = fall through to the template/profile default (the caller's
    /// `??` chain) — which is exactly what "my usual" means.
    func resolvedTarget(styleHeaviness: Double?) -> Double? {
        func clamp(_ x: Double) -> Double { min(0.50, max(0.05, x)) }
        let usual = styleHeaviness ?? 0.25
        switch self {
        case .onCamera:   return 0.10
        case .balanced:   return nil
        case .brollHeavy: return 0.45
        case .matchStyle: return nil
        case .moreMe:     return clamp(usual - 0.15)
        case .moreFood:   return clamp(usual + 0.15)
        }
    }
}

/// A beat to guarantee survives the cut (`keep:true`). Grounded in scene types every food video tends to
/// have — not arbitrary content topics.
enum KeepBeat: String, CaseIterable, Equatable {
    case biteReaction, finalDish, plating

    var label: String {
        switch self {
        case .biteReaction: return "My bite reaction"
        case .finalDish:    return "The final dish"
        case .plating:      return "Plating / cooking"
        }
    }

    var phrasing: String {
        switch self {
        case .biteReaction: return "the bite / reaction moment"
        case .finalDish:    return "the final dish / beauty shot (place it near the end)"
        case .plating:      return "a plating or cooking-action shot"
        }
    }
}
