import Foundation

/// Builds the **Pre-Edit Brief Block** — the per-video instructions the creator confirmed in `BriefView`.
/// It is **prepended after the Style Block** and before the tested segmentation body
/// (`styleBlock + briefBlock + GeminiPrompt.editPlan`), so the final priority is brief > style > generic.
///
/// Every line maps to a real `editPlan` lever (recommended_duration, final_edit_order, hook_score,
/// voiceover_candidate, broll_placements, keep, trim_to_seconds). We deliberately do NOT touch
/// `GeminiPrompt.editPlan` (the tested body). Because this block is highest priority and always present
/// when a brief exists, its closing line **redirects `style_match_notes`** to report which brief items
/// were honored — so feedback works even with no active style template.
enum BriefPromptBuilder {

    /// `template` = the active style template, used ONLY to keep the default max-scroll-stop opener from
    /// silently discarding a signature hook line the creator confirmed minutes earlier (displaced, never
    /// dropped). The brief still outranks the style everywhere — this just makes the collision explicit.
    static func block(for brief: EditBrief?, template: StyleTemplate? = nil) -> String {
        guard let b = brief else { return "" }

        var lines: [String] = []

        // 1 — target length → recommended_duration
        lines.append("- Target final length: ~\(b.lengthSeconds)s. → Set recommended_duration near this and bias which segments you keep/drop and where you trim dead air to land close to it, but never shorten a segment mid-thought to hit the number.")

        // 2 — opener: MAX SCROLL-STOP (let the AI pick the punchiest moment) OR a fixed ordered sequence
        if b.maxScrollStopHook {
            var scrollStop = "- Cold open — MAX SCROLL-STOP (no fixed shot sequence): open on the SINGLE most arresting moment in the footage — the punchiest claim, the biggest first-taste/peak reaction, or the most striking food shot with a strong line over it — whatever stops the scroll in the first ~1.5s. Do NOT force a fixed opener order; pick the best opener the footage offers, put it at the very top of final_edit_order and boost its hook_score, follow it with a one-line stakes/verdict TEASE, then continue with the intro and the rest in intro → middle → end order. Keep it coherent — the opener + tease must still lead sensibly into the video."
            // A style-side teaser-montage opener is not a CONFLICT with max-scroll-stop — it's how this
            // creator stops the scroll. Say so explicitly, or the brief's priority silently wins.
            if let t = template, t.profile.hook.montage.isMontage, t.profile.hook.montage.source != "other-creators" {
                scrollStop += " This creator's style opens with a rapid TEASER-MONTAGE (see their style block): honor it — the single most arresting moment should LEAD the teaser as its first shot, not replace the teaser."
            }
            if let hookLine = Self.confirmedHookLine(in: template) {
                scrollStop += " That said: this creator's confirmed signature hook line is \"\(hookLine)\" — if it exists in the footage, prefer it as the opener when it's competitive; if you open on something stronger, place the signature line immediately after the cold open — displaced, never dropped — and say why in style_match_notes."
            }
            lines.append(scrollStop)
        } else if !b.hookSequence.isEmpty {
            let ordered = b.hookSequence.enumerated()
                .map { "\($0.offset + 1)) \($0.element.phrasing) [\($0.element.sceneType)]" }
                .joined(separator: ", ")
            lines.append("- Cold open: open the video with these shots in THIS exact order, back-to-back, each using the strongest available segment of that type: \(ordered). This is a COLD OPEN — these play FIRST, before the intro, even if a shot naturally belongs to a later section; put them at the very top of final_edit_order and boost their hook_score, then continue with the intro and the rest in intro → middle → end order. If a requested type isn't in the footage, skip it and continue with the next.")
        }

        // 3 — voiceover/b-roll lean → broll_placements coverage + voiceover leaning
        lines.append(brollLine(for: b, template: template))

        // 3b — creator will narrate in post (Vela's in-app voiceover recorder) → cut for visual flow
        if b.plansVoiceover {
            lines.append("- The creator will record a fresh narration voiceover over the finished edit inside the app (this is separate from — and does not change — the strict in-footage voiceover_candidate rules below). Cut for a video that reads well under narration: favor visually strong segments, and beautiful food/action/payoff shots are worth keeping even where their live audio is weak or silent; do not fight to preserve spoken filler. Genuinely strong spoken moments (real reactions, punchy claims, the verdict) still deserve keep:true — the narration will be mixed around them.")
        }

        // 4 — keep-these-beats → keep:true + placement
        if !b.keepBeats.isEmpty {
            // Stable order for a deterministic prompt.
            let beats = KeepBeat.allCases.filter { b.keepBeats.contains($0) }.map(\.phrasing)
            lines.append("- Guarantee these beats survive the cut if they exist in the footage (mark the best matching segment keep:true and place it sensibly): \(beats.joined(separator: "; ")). If one isn't in the footage, do not fabricate it — note that in style_match_notes.")
        }

        // 5 — trim the slow stuff → trim_to_seconds + keep:false
        if b.trimSlowParts {
            lines.append("- Trim the slow stuff: use trim_to_seconds to cut weak or silent heads and tails, false starts and obvious dead air, and keep:false for redundant or repeated takes — but NEVER trim someone mid-sentence, drop a segment needed to land a point, or treat the spoken intro/context (the place, the order, the wait) as filler.")
        }

        // 6 — free-text catch-all (content-specific asks Gemini can honor by watching the video)
        let note = b.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            lines.append("- Creator's free-text note for this video (interpret intent and apply, including any \"avoid\"/\"focus on\" requests and any specific hook idea; you are watching the footage, so honor content-specific lines like \"keep the part where I say the price\"): \"\(note)\"")
        }

        return """
        === THIS VIDEO'S BRIEF — HIGHEST PRIORITY (above the style profile) ===

        The creator completed a required brief for THIS video. These instructions OVERRIDE the style profile above wherever they conflict. Honor them as far as the available raw footage allows; never invent footage that isn't there. The voiceover rules and segmentation rules in the body below remain hard constraints that this brief cannot override.

        \(lines.joined(separator: "\n"))

        After editing, use style_match_notes to briefly state which of these brief items you honored and any the footage did not allow (e.g. "Made it 28s, opened on the close-up then the reaction; couldn't keep a plating shot — none in the footage"). Populate style_match_notes even if no style block was provided above.

        === END THIS VIDEO'S BRIEF ===


        """
    }

    /// The RESOLVED b-roll/voiceover line — relative leans resolve against the template's learned
    /// heaviness so the prompt states NUMBERS, not vibes; absolute leans (the no-template flow) keep
    /// their `phrasing`. An explicit override says outright that it overrides the style block's
    /// coverage target, so the two lines can never silently contradict.
    private static func brollLine(for b: EditBrief, template: StyleTemplate?) -> String {
        let hard = "The strict voiceover conditions in the body below remain hard requirements regardless."
        guard let heaviness = template?.profile.broll.heaviness else {
            // No template (or a relative pick left over from one, defensively) → the absolute phrasing.
            return "- Voiceover vs. on camera: \(b.brollLean.phrasing) \(hard)"
        }
        let usualPct = Int((min(1, max(0, heaviness)) * 100).rounded())
        let askPct = (b.brollLean.resolvedTarget(styleHeaviness: heaviness)).map { Int(($0 * 100).rounded()) }
        switch b.brollLean {
        case .matchStyle:
            return "- B-roll amount: match this creator's usual — hit the style profile's b-roll COVERAGE TARGET above (roughly \(usualPct)% of the talking-on-camera time) with broll_placements, using voiceover marks where they help you get there. \(hard)"
        case .moreMe:
            return "- B-roll amount — for THIS video the creator asked for LESS b-roll than their usual: aim for roughly \(askPct ?? usualPct)% of the talking-on-camera time covered by broll_placements (their usual is ~\(usualPct)%). This overrides the style profile's coverage target above. \(hard)"
        case .moreFood:
            return "- B-roll amount — for THIS video the creator asked for MORE b-roll than their usual: aim for roughly \(askPct ?? usualPct)% of the talking-on-camera time covered by broll_placements (their usual is ~\(usualPct)%). This overrides the style profile's coverage target above. \(hard)"
        case .onCamera, .balanced, .brollHeavy:
            return "- Voiceover vs. on camera: \(b.brollLean.phrasing) \(hard)"
        }
    }

    /// The creator's confirmed SPOKEN hook line, if the active template has one — user-confirmed
    /// ("every") or heard in every source video (N≥2). Suppressed keys never qualify (they're already
    /// removed from the template's lines when rejected).
    private static func confirmedHookLine(in template: StyleTemplate?) -> String? {
        guard let t = template else { return nil }
        let line = t.profile.verbalStyle.recurringLines.first { l in
            l.isSpoken && l.role == "hook"
                && (l.confirmation == "every" || (t.count >= 2 && l.evidenceCount >= t.count))
                && !l.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return line?.quote.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
