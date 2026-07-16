// Node mirror of StyleConstraintBuilder.block(for:) — builds the Part-A style block from a template.json
// (exported from the device or hand-written) so fidelity fixtures can be generated off-device.
//
//   node build-style-block.mjs path/to/template.json [--v1] > style-block.txt
//
// --v1 emits the PRE-signature block (no VOICE line, no SIGNATURE LINES, no habit accountability) — the
// baseline arm of the fidelity A/B. Default emits v2. The delta between arms is exactly M3's addition.
//
// LOCKSTEP: this re-implements Swift logic, the most drift-prone mirror in the lab — so it records the
// SHA-256 of StyleConstraintBuilder.swift into style-block.meta.json next to any --out file, and
// check-signatures.mjs hard-fails when the Swift file's hash no longer matches ("mirror out of date").
// PREFER captured blocks: when the app's logs give you the real built block, use that text instead and
// skip this mirror entirely (run-decide.mjs only needs prompt.txt).

import { readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
export const SWIFT_PATH = join(here, "../../FoodEditor/Services/StyleConstraintBuilder.swift");

export async function swiftSha256() {
  return createHash("sha256").update(await readFile(SWIFT_PATH)).digest("hex");
}

const nonEmpty = (s, fallback) => {
  const t = (s ?? "").toString().trim();
  return t.length ? t : fallback;
};
const trim = (s) => (s ?? "").toString().trim();

export function buildBlock(t, { v1 = false } = {}) {
  const p = t.profile;
  const vs = p.verbal_style ?? {};
  const count = t.count ?? 1;

  const hook = nonEmpty(p.hook?.type_custom && (p.hook.type === "other" || !p.hook.type) ? p.hook.type_custom : p.hook?.type, "a strong visual moment");
  const cut = Math.max(0, p.pacing?.average_clip_length_seconds ?? 0).toFixed(1);
  const total = Math.round(Math.max(0, p.pacing?.total_length_seconds ?? 0));
  const opens = Math.round(Math.max(0, p.hook?.opens_within_seconds ?? 0));
  const cutStyle = nonEmpty(p.pacing?.cut_style_custom && (p.pacing.cut_style === "other" || !p.pacing.cut_style) ? p.pacing.cut_style_custom : p.pacing?.cut_style, "their usual pacing");
  const vo = Math.min(1, Math.max(0, p.voiceover_vs_oncamera?.voiceover_ratio ?? 0)).toFixed(2);
  const brollAmount = nonEmpty(p.broll?.amount, "some");
  const brollUsage = nonEmpty(p.broll?.usage_custom && (p.broll.usage === "other" || !p.broll.usage) ? p.broll.usage_custom : p.broll?.usage, "as needed");
  const favShots = (p.broll?.favored_shots ?? []).length ? p.broll.favored_shots.join(", ") : "any strong food shots";
  const brollPct = Math.round(Math.min(1, Math.max(0, p.broll?.heaviness ?? 0.25)) * 100);
  const tgAmount = nonEmpty(p.text_and_graphics?.amount, "some");
  const tgStyle = nonEmpty(p.text_and_graphics?.text_style_custom && (p.text_and_graphics.text_style === "other" || !p.text_and_graphics.text_style) ? p.text_and_graphics.text_style_custom : p.text_and_graphics?.text_style, "their usual style");
  const closing = nonEmpty(p.closing?.type_custom && (p.closing.type === "other" || !p.closing.type) ? p.closing.type_custom : p.closing?.type, "their usual closing");
  const moves = nonEmpty((p.signature_moves ?? []).map((m) => m.move).filter(Boolean).join("; "), "none noted");
  const unusual = nonEmpty(p.anything_unusual ?? "", "none");

  // TEASER-MONTAGE OPENER (v2 only) — own-footage montage hooks reproduce via cold_open; mirrors Swift
  // (incl. the user-toggle override: an ON montage/teaser habit fires it, an OFF one silences it).
  let montageLine = "";
  if (!v1) {
    const m = p.hook?.montage ?? {};
    const montageHabit = (t.habits ?? []).find((h) => /montage|teaser/i.test(h.label ?? ""));
    const habitSaysNo = montageHabit ? !montageHabit.on : false;
    const habitSaysYes = montageHabit ? (montageHabit.on && (montageHabit.kind === undefined || montageHabit.kind === "selection" || montageHabit.kind === "verbal")) : false;
    if ((m.is_montage || habitSaysYes) && !habitSaysNo && m.source !== "other-creators") {
      const n = Math.max(2, Math.min(3, (m.clip_count_estimate ?? 0) <= 0 ? 3 : m.clip_count_estimate));
      const secs = (m.avg_clip_seconds ?? 0) > 0 ? Math.max(1.0, Math.min(2.0, m.avg_clip_seconds)).toFixed(1) : "1.5";
      montageLine = `\n- TEASER-MONTAGE OPENER: this creator opens with a rapid ${n}-shot teaser of their OWN footage before the intro. Build the cold_open that way: pick ${n} of the punchiest, most food-forward VISUAL moments (highest hook_score — pulls, bites, pours; prefer shots with no essential speech), cut each short (~${secs}s via trim_to_seconds — they're visual moments, so a short cut never clips a thought), then land on their spoken intro line and continue normally. Prefer teaser shots whose full version isn't essential later (a second-best pull, a pour) — never spend the single climax moment of a dish up front.`;
    }
  }

  // VOICE (v2 only)
  let voiceLine = "";
  if (!v1) {
    const tone = trim(vs.tone), pov = trim(vs.pov);
    if (tone || pov) {
      const both = [tone, pov].filter(Boolean).join(" · ");
      voiceLine = `\n- Voice: ${both}. → Every text choice you make (which spoken line opens the video, how edit_notes phrase overlay placements) should sound like this creator.`;
    }
  }

  // Recipe / arc
  const arc = (t.beats ?? []).length
    ? t.beats.map((b) => `${b.chip} (${b.t}): ${b.text}`).join(" → ")
    : ((p.structure?.arc ?? []).length ? p.structure.arc.join(" → ") : "hook → build → payoff → close");

  // SECTION MAP (with v2's inline examples)
  const beatText = (b) => {
    const ex = trim(b.example);
    return !v1 && ex ? `${b.label} (e.g. ${ex})` : b.label;
  };
  const secs = (p.structure?.sections ?? []).filter((s) => (s.beats ?? []).length || trim(s.purpose));
  let sectionMap;
  if (!secs.length) {
    sectionMap = `- Typical arc: ${arc}. → Order final_edit_order to follow this narrative shape where the footage allows.`;
  } else {
    const rank = { intro: 0, middle: 1, end: 2 };
    const ordered = [...secs].sort((a, b) => (rank[trim(a.section).toLowerCase()] ?? 9) - (rank[trim(b.section).toLowerCase()] ?? 9));
    const beatLines = ordered.map((s) => {
      const core = (s.beats ?? []).filter((b) => b.core && b.label).map(beatText);
      const extra = (s.beats ?? []).filter((b) => !b.core && b.label).map(beatText);
      const parts = [];
      if (trim(s.purpose)) parts.push(trim(s.purpose));
      if (core.length) parts.push(`always include: ${core.join(", ")}`);
      if (extra.length) parts.push(`include if present: ${extra.join(", ")}`);
      return `  • ${trim(s.section).toUpperCase()} — ${parts.join("; ")}`;
    });
    sectionMap = ["- SECTION MAP — recreate this creator's structure. Tag every segment's section and rebuild the video intro → middle → end:",
      ...beatLines,
      "  For each section, keep the raw segments that fill its beats — the INTRO especially (the place / name / what they ordered / an establishing shot); never drop those as slow or filler. Order final_edit_order by section. If a listed beat isn't in the footage, don't fabricate it — say so in style_match_notes."].join("\n");
  }

  // SIGNATURE LINES (v2 only) — mirrors StyleConstraintBuilder.signatureSection
  let signatureSection = "";
  if (!v1) {
    const suppressed = (t.suppressed ?? []).map((s) => trim(s).toLowerCase()).filter(Boolean);
    const isSuppressed = (key) => suppressed.some((s) => key.includes(s) || s.includes(key));
    const tier = (confirmation, evidence) => {
      if (confirmation === "every") return ["confirmed — every video", true];
      if (confirmation === "sometimes") return ["sometimes — keep if present, don't force", false];
      if (count >= 2 && evidence >= count) return [`in all ${count} videos`, true];
      return ["seen once — keep if present, don't force", false];
    };
    const looksLikeRating = (s) => /\d+(\.\d+)?\s*(\/|out of)\s*(10|5)/i.test(s);

    const bullets = [];
    let coveredSignoff = false;
    for (const line of (vs.recurring_lines ?? [])) {
      if ((line.medium ?? "spoken") === "text-overlay") continue;
      const quote = trim(line.quote);
      const key = trim(line.pattern || line.quote).toLowerCase();
      if (!quote || isSuppressed(key) || bullets.length >= 3) continue;
      const [tierLabel, strong] = tier(line.confirmation, line.evidence_count ?? 1);
      // Mirror of the Swift role normalization: unknown roles place by observed position.
      const role = ["hook", "verdict", "sign-off", "transition", "throughout"].includes(line.where_used)
        ? line.where_used
        : (line.position === "opening" ? "hook" : "throughout");
      let placement;
      switch (role) {
        case "sign-off":
          coveredSignoff = true;
          placement = strong
            ? "If found: the shot carrying it MUST be kept and MUST be the final SPOKEN moment of final_edit_order — nothing spoken plays after it (a closing beauty shot may follow only if that matches their learned closing)."
            : "If found, prefer ending the spoken content on it.";
          break;
        case "verdict":
          placement = "If found: keep that shot and place it at the END, just before any sign-off — NEVER in the cold open.";
          break;
        case "hook":
          placement = strong && looksLikeRating(quote)
            ? "NOTE: this creator opens on their score, which conflicts with the hard never-open-on-the-final-rating rule — do NOT force it; keep the line where the arc allows and say so in style_match_notes."
            : "If found, it belongs at the very top of final_edit_order as the opening line.";
          break;
        default:
          placement = "If found, keep it where it occurs, with its segment — do not relocate it.";
      }
      const roleLabel = line.where_used ? line.where_used[0].toUpperCase() + line.where_used.slice(1) : "Line";
      const patternNote = trim(line.pattern) ? ` Template: "${trim(line.pattern)}" — match it with ANY value in the slot.` : "";
      const posNote = trim(line.position) ? ` Their usual position: ${trim(line.position)}.` : "";
      bullets.push(`  • ${roleLabel}: "${quote}" (${tierLabel}).${patternNote}${posNote} ${placement}`);
    }
    const signoff = trim(vs.signoff);
    if (!coveredSignoff && signoff && !isSuppressed(signoff.toLowerCase())) {
      const [tierLabel, strong] = tier(vs.signoff_confirmation, 1);
      const placement = strong
        ? "If found: the shot carrying it MUST be kept and MUST be the final SPOKEN moment of final_edit_order — nothing spoken plays after it (a closing beauty shot may follow only if that matches their learned closing)."
        : "If found, prefer ending the spoken content on it.";
      bullets.push(`  • Sign-off: "${signoff}" (${tierLabel}). ${placement}`);
    }
    const rating = trim(vs.rating_format);
    if (rating) {
      const [tierLabel] = tier(vs.rating_confirmation, 1);
      const scope = trim(vs.rating_scope).toLowerCase();
      if (scope === "per-item") {
        bullets.push(`  • Rating — PER ITEM (${tierLabel}): they score EACH dish as they go (${rating}). Every score line stays WITH its dish's block — never relocate scores to the end, and there may be no single final verdict; do not fabricate one.`);
      } else if (scope === "both") {
        bullets.push(`  • Rating — per item + overall (${tierLabel}): ${rating}. Per-dish scores stay WITH their dish blocks; ONLY the single overall verdict goes at the end, just before any sign-off — never in the cold open.`);
      } else {
        bullets.push(`  • Rating (${tierLabel}): ${rating}. The shot where the final score is spoken MUST be kept and placed at the END, just before any sign-off — never spend it in the cold open.`);
      }
    }
    if (bullets.length) {
      signatureSection = "\n" + ["- SIGNATURE LINES — this creator's verbal identity. Scan everything spoken in the footage (the talk spans' spoken_text when a content index is provided; otherwise the audio) for each line below — match the exact wording OR a close paraphrase (same distinctive phrase, minor word changes):",
        ...bullets,
        "  For every signature you find: keep the FULL sentence (never trim through it), never cover its to-camera delivery with b-roll, and in style_match_notes list each signature you found and where you placed it — plus any you looked for that the footage didn't contain. If a signature isn't in the footage, do NOT fabricate it or approximate it with a different line. The per-video brief still outranks these placements where they conflict."].join("\n");
    }
  }

  // Habits
  const onHabits = (t.habits ?? []).filter((h) => h.on && ["selection", "verbal", undefined].includes(h.kind ?? "selection") && trim(h.label));
  const appliable = (t.habits ?? []).filter((h) => h.on && (h.kind === undefined || h.kind === "selection" || h.kind === "verbal") && trim(h.label));
  const habitRows = (v1 ? onHabits : appliable).map((h) => (h.detail ? `- ${h.label} — ${h.detail}` : `- ${h.label}`));
  let habitsSection = habitRows.length ? `\n\nHABITS THE CREATOR KEPT ON (honor these wherever the footage allows):\n${habitRows.join("\n")}` : "";
  if (habitsSection && !v1) {
    habitsSection += "\nFor EVERY habit listed above, style_match_notes must say whether you honored it and, if not, why (footage didn't contain it / conflicts with a hard rule) — one short clause per habit, semicolon-separated; lead with anything you could NOT honor.";
  }

  const trimmedNotes = trim(t.notes);
  const notesSection = trimmedNotes ? `\n\nEXTRA NOTES FROM THE CREATOR (honor these):\n${trimmedNotes}` : "";

  return `=== THIS CREATOR'S EDITING STYLE — EDIT TO MATCH ===

You are editing for a specific creator. Below is their learned editing style. Your segmentation and edit decisions should make the final video feel like THEY made it, not like a generic edit. Apply this style as far as the available raw footage allows — match it where the footage supports it, and where the footage lacks what the style calls for, get as close as the available segments allow rather than inventing anything.

STYLE BRIEF (read this first — it's the gist):
${nonEmpty(p.style_brief, "A clean, appetizing edit that feels like this creator.")}

KEY STYLE TARGETS (translate these tendencies into your per-segment decisions):${voiceLine}
- Preferred hook: ${hook} — they open within ~${opens}s. → Choose a hook segment of this type if one exists; give it the top of final_edit_order. If no such segment exists, pick the closest high-impact opener available.${montageLine}
- Pacing: they average ~${cut}s per clip (${cutStyle}), total length ~${total}s. → This is their VISUAL rhythm — created by cutting between shots and laying quick b-roll, NOT by cutting people off mid-sentence. Do NOT use trim_to_seconds to pull talking toward this average; let a talking segment run as long as the thought needs. You may use the total length as a SOFT guide for which segments to keep, but completeness of the message wins — never drop or shorten a segment that's needed to land the point.
- Voiceover ratio: ${vo} (0 = always face on camera, 1 = always voice over b-roll). → The higher this number, the more aggressively you should mark qualifying talking-head segments as voiceover_candidate (still respecting the strict voiceover rules in the body below).
- B-roll: ${brollAmount} amount, used ${brollUsage}; favored shots: ${favShots}. → COVERAGE TARGET: cover roughly ${brollPct}% of the TALKING-ON-CAMERA time with b-roll overlays (the broll_placements list), and never leave a coverable talking stretch longer than ~8 seconds fully uncovered. This visual rhythm is part of this creator's style — under-covering it is a style miss. Prefer their favored shot types when choosing each b-roll source and for voiceover_reason.
${sectionMap}${signatureSection}
- Text/graphics habit: ${tgAmount} (${tgStyle}). → Note in edit_note where their usual overlays (e.g. dish names) would go; you are not creating graphics, just flagging placement.
- Closing: ${closing}. → Try to end final_edit_order on a segment that fits this closing style.
- Signature moves: ${moves}. → If the footage contains a moment that lets you honor one of these, do so and mention it in the relevant edit_note.
- Anything unusual: ${unusual}.${habitsSection}${notesSection}

PRIORITY RULE: When the style and good general editing conflict, favor the creator's style — it's why they're using this tool. The ONE exception: never violate the hard editor rules or the strict voiceover conditions in the body below; those are hard constraints, the style is a strong preference on top of them.

=== END STYLE BLOCK ===

`;
}

// CLI
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const [path, ...flags] = process.argv.slice(2);
  if (!path) { console.error("usage: node build-style-block.mjs template.json [--v1] [--out dir]"); process.exit(1); }
  const t = JSON.parse(await readFile(path, "utf8"));
  const v1 = flags.includes("--v1");
  const block = buildBlock(t, { v1 });
  const outIdx = flags.indexOf("--out");
  if (outIdx >= 0 && flags[outIdx + 1]) {
    const dir = flags[outIdx + 1];
    await writeFile(join(dir, "style-block.txt"), block);
    await writeFile(join(dir, "style-block.meta.json"), JSON.stringify({ swiftSha256: await swiftSha256(), v1 }, null, 2));
    console.error(`wrote ${dir}/style-block.txt (+meta, ${v1 ? "v1" : "v2"})`);
  } else {
    process.stdout.write(block);
  }
}
