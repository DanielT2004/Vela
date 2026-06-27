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

    static func block(for brief: EditBrief?) -> String {
        guard let b = brief else { return "" }

        var lines: [String] = []

        // 1 — target length → recommended_duration
        lines.append("- Target final length: ~\(b.lengthSeconds)s. → Set recommended_duration near this and bias which segments you keep/drop and where you trim dead air to land close to it, but never shorten a segment mid-thought to hit the number.")

        // 2 — ordered opener → top of final_edit_order + hook_score
        if !b.hookSequence.isEmpty {
            let ordered = b.hookSequence.enumerated()
                .map { "\($0.offset + 1)) \($0.element.phrasing) [\($0.element.sceneType)]" }
                .joined(separator: ", ")
            lines.append("- Cold open: open the video with these shots in THIS exact order, back-to-back, each using the strongest available segment of that type: \(ordered). This is a COLD OPEN — these play FIRST, before the intro, even if a shot naturally belongs to a later section; put them at the very top of final_edit_order and boost their hook_score, then continue with the intro and the rest in intro → middle → end order. If a requested type isn't in the footage, skip it and continue with the next.")
        }

        // 3 — voiceover/b-roll lean → voiceover_candidate + broll_placements
        lines.append("- Voiceover vs. on camera: \(b.brollLean.phrasing) The four strict voiceover_candidate conditions in the body below remain hard requirements regardless.")

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
}
