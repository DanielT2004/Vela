import Foundation

/// Builds **Part A** of the connector — the Style Injection Block prepended to the segmentation body
/// (`GeminiPrompt.editPlan`) when a creator has an active style. Fills the block from the active
/// `StyleTemplate`'s machine profile, plus the editable surface the creator owns: the recipe (as the arc),
/// the enabled toggles ("habits to honor"), and the free notes field. Returns `""` when there's no active
/// template — so the prompt is exactly the original generic version.
enum StyleConstraintBuilder {

    static func block(for template: StyleTemplate?) -> String {
        guard let t = template else { return "" }
        let p = t.profile

        let hook = nonEmpty(p.hook.resolved, "a strong visual moment")
        let cut = String(format: "%.1f", max(0, p.pacing.averageClipLengthSeconds))
        let total = Int(max(0, p.pacing.totalLengthSeconds).rounded())
        let opens = Int(max(0, p.hook.opensWithinSeconds).rounded())
        let cutStyle = nonEmpty(p.pacing.cutStyleResolved, "their usual pacing")
        let vo = String(format: "%.2f", min(1, max(0, p.voiceover.voiceoverRatio)))
        let brollAmount = nonEmpty(p.broll.amount, "some")
        let brollUsage = nonEmpty(p.broll.usageResolved, "as needed")
        let favShots = p.broll.favoredShotsText
        let brollPct = Int((min(1, max(0, p.broll.heaviness)) * 100).rounded())
        let tgAmount = nonEmpty(p.textAndGraphics.amount, "some")
        let tgStyle = nonEmpty(p.textAndGraphics.textStyleResolved, "their usual style")
        let closing = nonEmpty(p.closing.resolved, "their usual closing")
        let moves = nonEmpty(p.signatureMoves.map(\.move).filter { !$0.isEmpty }.joined(separator: "; "), "none noted")
        let unusual = nonEmpty(p.anythingUnusual ?? "", "none")

        // TEASER-MONTAGE OPENER — the OWN-FOOTAGE montage hook is reproducible with existing levers
        // (cold_open already takes 1-3 shots; the teaser moments are silent visual shots, so short
        // end-trims never clip a thought). Only the borrowed-clip variant (other creators' footage,
        // needs a marking UI + mid-speech cuts) stays deferred.
        // The USER'S toggle wins over the machine flag: a montage/teaser habit switched ON fires the
        // directive even when consolidation demoted the hook (a 1-of-3 sometimes-move), and switched
        // OFF it silences the directive even when the flag is set.
        let montageLine: String = {
            let m = p.hook.montage
            let montageHabit = t.habits.first {
                $0.label.range(of: "montage|teaser", options: [.regularExpression, .caseInsensitive]) != nil
            }
            let habitSaysNo = montageHabit.map { !$0.on } ?? false
            let habitSaysYes = montageHabit.map { $0.on && $0.isAppliable } ?? false
            guard (m.isMontage || habitSaysYes), !habitSaysNo, m.source != "other-creators" else { return "" }
            let n = max(2, min(3, m.clipCountEstimate <= 0 ? 3 : m.clipCountEstimate))
            let secs = m.avgClipSeconds > 0 ? String(format: "%.1f", max(1.0, min(2.0, m.avgClipSeconds))) : "1.5"
            return "\n- TEASER-MONTAGE OPENER: this creator opens with a rapid \(n)-shot teaser of their OWN footage before the intro. Build the cold_open that way: pick \(n) of the punchiest, most food-forward VISUAL moments (highest hook_score — pulls, bites, pours; prefer shots with no essential speech), cut each short (~\(secs)s via trim_to_seconds — they're visual moments, so a short cut never clips a thought), then land on their spoken intro line and continue normally. Prefer teaser shots whose full version isn't essential later (a second-best pull, a pour) — never spend the single climax moment of a dish up front."
        }()

        // VOICE — how this creator sounds; steers hook-line selection + edit_note phrasing.
        let voiceLine: String = {
            let tone = p.verbalStyle.tone.trimmingCharacters(in: .whitespaces)
            let pov = p.verbalStyle.pov.trimmingCharacters(in: .whitespaces)
            guard !tone.isEmpty || !pov.isEmpty else { return "" }
            let both = [tone, pov].filter { !$0.isEmpty }.joined(separator: " · ")
            return "\n- Voice: \(both). → Every text choice you make (which spoken line opens the video, how edit_notes phrase overlay placements) should sound like this creator."
        }()

        // Recipe (editable beats) drives the arc when present; else fall back to the profile's arc.
        let arc: String = t.beats.isEmpty
            ? p.structure.arcText
            : t.beats.map { "\($0.chip) (\($0.t)): \($0.text)" }.joined(separator: " → ")

        // SECTION MAP — the learned intro/middle/end structure to recreate. Falls back to the flat arc
        // line for legacy templates that predate section learning.
        let sectionMap: String = {
            let secs = p.structure.sections.filter { !$0.beats.isEmpty || !$0.purpose.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !secs.isEmpty else {
                return "- Typical arc: \(arc). → Order final_edit_order to follow this narrative shape where the footage allows."
            }
            let rank = ["intro": 0, "middle": 1, "end": 2]
            let ordered = secs.sorted { (rank[$0.section.lowercased()] ?? 9) < (rank[$1.section.lowercased()] ?? 9) }
            // Beats read "label (e.g. instance)" — the label is format-level, the example gives DECIDE the
            // concrete flavor without menu-locking the instruction to a past video's dishes.
            func beatText(_ b: SectionBeat) -> String {
                let ex = b.example.trimmingCharacters(in: .whitespaces)
                return ex.isEmpty ? b.label : "\(b.label) (e.g. \(ex))"
            }
            let beatLines = ordered.map { s -> String in
                let core  = s.beats.filter { $0.core && !$0.label.isEmpty }.map(beatText)
                let extra = s.beats.filter { !$0.core && !$0.label.isEmpty }.map(beatText)
                var parts: [String] = []
                let purpose = s.purpose.trimmingCharacters(in: .whitespaces)
                if !purpose.isEmpty { parts.append(purpose) }
                if !core.isEmpty    { parts.append("always include: \(core.joined(separator: ", "))") }
                if !extra.isEmpty   { parts.append("include if present: \(extra.joined(separator: ", "))") }
                return "  • \(s.section.uppercased()) — \(parts.joined(separator: "; "))"
            }
            return (["- SECTION MAP — recreate this creator's structure. Tag every segment's section and rebuild the video intro → middle → end:"]
                    + beatLines
                    + ["  For each section, keep the raw segments that fill its beats — the INTRO especially (the place / name / what they ordered / an establishing shot); never drop those as slow or filler. Order final_edit_order by section. If a listed beat isn't in the footage, don't fabricate it — say so in style_match_notes."])
                .joined(separator: "\n")
        }()

        // Enabled toggles (defaults + custom) — honored directives the creator confirmed. Only APPLIABLE
        // kinds reach the prompt: coming-soon habits (supplied-footage / visual-effect) are display rows —
        // instructions the editor can't execute are noise that dilutes the ones it can (Decision #10).
        // Accountability clause: every listed habit must be answered for in style_match_notes, so the
        // creator can SEE the obedience post-cut (FirstCutView renders the notes).
        let onHabits = t.habits.filter { $0.on && $0.isAppliable && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
        let habitsSection: String = onHabits.isEmpty ? "" : "\n\nHABITS THE CREATOR KEPT ON (honor these wherever the footage allows):\n" + onHabits.map { h in
            if let d = h.detail, !d.isEmpty { return "- \(h.label) — \(d)" }
            return "- \(h.label)"
        }.joined(separator: "\n")
        + "\nFor EVERY habit listed above, style_match_notes must say whether you honored it and, if not, why (footage didn't contain it / conflicts with a hard rule) — one short clause per habit, semicolon-separated; lead with anything you could NOT honor."

        let signatureSection = Self.signatureSection(for: t)

        let trimmedNotes = t.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let notesSection = trimmedNotes.isEmpty ? "" : "\n\nEXTRA NOTES FROM THE CREATOR (honor these):\n\(trimmedNotes)"

        return """
        === THIS CREATOR'S EDITING STYLE — EDIT TO MATCH ===

        You are editing for a specific creator. Below is their learned editing style. Your segmentation and edit decisions should make the final video feel like THEY made it, not like a generic edit. Apply this style as far as the available raw footage allows — match it where the footage supports it, and where the footage lacks what the style calls for, get as close as the available segments allow rather than inventing anything.

        STYLE BRIEF (read this first — it's the gist):
        \(nonEmpty(t.summary, "A clean, appetizing edit that feels like this creator."))

        KEY STYLE TARGETS (translate these tendencies into your per-segment decisions):\(voiceLine)
        - Preferred hook: \(hook) — they open within ~\(opens)s. → Choose a hook segment of this type if one exists; give it the top of final_edit_order. If no such segment exists, pick the closest high-impact opener available.\(montageLine)
        - Pacing: they average ~\(cut)s per clip (\(cutStyle)), total length ~\(total)s. → This is their VISUAL rhythm — created by cutting between shots and laying quick b-roll, NOT by cutting people off mid-sentence. Do NOT use trim_to_seconds to pull talking toward this average; let a talking segment run as long as the thought needs. You may use the total length as a SOFT guide for which segments to keep, but completeness of the message wins — never drop or shorten a segment that's needed to land the point.
        - Voiceover ratio: \(vo) (0 = always face on camera, 1 = always voice over b-roll). → The higher this number, the more aggressively you should mark qualifying talking-head segments as voiceover_candidate (still respecting the strict voiceover rules in the body below).
        - B-roll: \(brollAmount) amount, used \(brollUsage); favored shots: \(favShots). → COVERAGE TARGET: cover roughly \(brollPct)% of the TALKING-ON-CAMERA time with b-roll overlays (the broll_placements list), and never leave a coverable talking stretch longer than ~8 seconds fully uncovered. This visual rhythm is part of this creator's style — under-covering it is a style miss. Prefer their favored shot types when choosing each b-roll source and for voiceover_reason.
        \(sectionMap)\(signatureSection)
        - Text/graphics habit: \(tgAmount) (\(tgStyle)). → Note in edit_note where their usual overlays (e.g. dish names) would go; you are not creating graphics, just flagging placement.
        - Closing: \(closing). → Try to end final_edit_order on a segment that fits this closing style.
        - Signature moves: \(moves). → If the footage contains a moment that lets you honor one of these, do so and mention it in the relevant edit_note.
        - Anything unusual: \(unusual).\(habitsSection)\(notesSection)

        PRIORITY RULE: When the style and good general editing conflict, favor the creator's style — it's why they're using this tool. The ONE exception: never violate the hard editor rules or the strict voiceover conditions in the body below; those are hard constraints, the style is a strong preference on top of them.

        === END STYLE BLOCK ===


        """
    }

    // MARK: - SIGNATURE LINES

    /// The creator's verbal identity, matched against the new footage's speech. Spoken lines only
    /// (text-overlay signatures are reproduced UI-side in Polish, never talk-span matched); suppressed
    /// keys excluded belt-and-braces (rejected rows are already removed from the template). Placement
    /// follows each line's role + OBSERVED position; tiers: user-confirmed ("every") or all-sources
    /// evidence (N≥2) → hard placement, else "keep if present, don't force". Wording works for BOTH
    /// pipelines: DECIDE reads talk_spans; the legacy monolith hears the audio.
    private static func signatureSection(for t: StyleTemplate) -> String {
        let vs = t.profile.verbalStyle
        let suppressedKeys = t.suppressed.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        func isSuppressed(_ key: String) -> Bool { suppressedKeys.contains { key.contains($0) || $0.contains(key) } }

        func tier(_ confirmation: String?, _ evidence: Int) -> (label: String, strong: Bool) {
            if confirmation == "every" { return ("confirmed — every video", true) }
            if confirmation == "sometimes" { return ("sometimes — keep if present, don't force", false) }
            if t.count >= 2 && evidence >= t.count { return ("in all \(t.count) videos", true) }
            return ("seen once — keep if present, don't force", false)
        }
        func looksLikeRating(_ s: String) -> Bool {
            s.range(of: #"\d+(\.\d+)?\s*(/|out of)\s*(10|5)"#, options: [.regularExpression, .caseInsensitive]) != nil
        }

        var bullets: [String] = []
        var coveredSignoff = false

        for line in vs.recurringLines where line.isSpoken {
            let quote = line.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty, !isSuppressed(line.key), bullets.count < 3 else { continue }
            let (tierLabel, strong) = tier(line.confirmation, line.evidenceCount)
            // Schema-less extraction sometimes drifts off the role enum (observed: "intro") — normalize
            // unknown roles by the line's observed position so an opener formula still gets hook placement.
            let role: String = {
                switch line.role {
                case "hook", "verdict", "sign-off", "transition", "throughout": return line.role
                default: return line.position == "opening" ? "hook" : "throughout"
                }
            }()
            let placement: String
            switch role {
            case "sign-off":
                coveredSignoff = true
                placement = strong
                    ? "If found: the shot carrying it MUST be kept and MUST be the final SPOKEN moment of final_edit_order — nothing spoken plays after it (a closing beauty shot may follow only if that matches their learned closing)."
                    : "If found, prefer ending the spoken content on it."
            case "verdict":
                placement = "If found: keep that shot and place it at the END, just before any sign-off — NEVER in the cold open."
            case "hook":
                placement = (strong && looksLikeRating(quote))
                    ? "NOTE: this creator opens on their score, which conflicts with the hard never-open-on-the-final-rating rule — do NOT force it; keep the line where the arc allows and say so in style_match_notes."
                    : "If found, it belongs at the very top of final_edit_order as the opening line."
            default:
                placement = "If found, keep it where it occurs, with its segment — do not relocate it."
            }
            let roleLabel = role.capitalized
            let pattern = (line.pattern?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let patternNote = pattern.map { " Template: \"\($0)\" — match it with ANY value in the slot." } ?? ""
            let posNote = line.position.isEmpty ? "" : " Their usual position: \(line.position)."
            bullets.append("  • \(roleLabel): \"\(quote)\" (\(tierLabel)).\(patternNote)\(posNote) \(placement)")
        }

        // Scalar sign-off — only when no recurring line already covers it. Evidence is unknown for the
        // merged scalar, so unconfirmed stays at the soft tier (conservative).
        let signoff = vs.signoff.trimmingCharacters(in: .whitespacesAndNewlines)
        if !coveredSignoff, !signoff.isEmpty, !isSuppressed(signoff.lowercased()) {
            let (tierLabel, strong) = tier(vs.signoffConfirmation, 1)
            let placement = strong
                ? "If found: the shot carrying it MUST be kept and MUST be the final SPOKEN moment of final_edit_order — nothing spoken plays after it (a closing beauty shot may follow only if that matches their learned closing)."
                : "If found, prefer ending the spoken content on it."
            bullets.append("  • Sign-off: \"\(signoff)\" (\(tierLabel)). \(placement)")
        }

        // Rating formula — placement depends on the learned SCOPE (per-item raters keep scores with their
        // dish blocks; only an overall verdict is saved for the end).
        let rating = vs.ratingFormat.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rating.isEmpty {
            let (tierLabel, _) = tier(vs.ratingConfirmation, 1)
            switch vs.ratingScope.lowercased() {
            case "per-item":
                bullets.append("  • Rating — PER ITEM (\(tierLabel)): they score EACH dish as they go (\(rating)). Every score line stays WITH its dish's block — never relocate scores to the end, and there may be no single final verdict; do not fabricate one.")
            case "both":
                bullets.append("  • Rating — per item + overall (\(tierLabel)): \(rating). Per-dish scores stay WITH their dish blocks; ONLY the single overall verdict goes at the end, just before any sign-off — never in the cold open.")
            default:
                bullets.append("  • Rating (\(tierLabel)): \(rating). The shot where the final score is spoken MUST be kept and placed at the END, just before any sign-off — never spend it in the cold open.")
            }
        }

        guard !bullets.isEmpty else { return "" }
        return "\n" + (["- SIGNATURE LINES — this creator's verbal identity. Scan everything spoken in the footage (the talk spans' spoken_text when a content index is provided; otherwise the audio) for each line below — match the exact wording OR a close paraphrase (same distinctive phrase, minor word changes):"]
            + bullets
            + ["  For every signature you find: keep the FULL sentence (never trim through it), never cover its to-camera delivery with b-roll, and in style_match_notes list each signature you found and where you placed it — plus any you looked for that the footage didn't contain. If a signature isn't in the footage, do NOT fabricate it or approximate it with a different line. The per-video brief still outranks these placements where they conflict."])
            .joined(separator: "\n")
    }

    private static func nonEmpty(_ s: String, _ fallback: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? fallback : t
    }
}
