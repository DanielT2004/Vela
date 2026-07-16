// ADAPT — merge a DECIDE decisions object with the PERCEIVE content index into a full EditPlan the app
// renders unchanged. Pure + deterministic; this is the "code = safety net / assembler" step. The PERCEIVE
// `shots` ARE the app's `segments` (same id/timestamps/scene_type/section/topic), so this COPIES the index
// fields verbatim and only DERIVES the editorial ones — making coverage/timing/scene violations impossible.
// `keep` is implicit: a shot is kept iff it's in final_edit_order or used as a b-roll source.
// Mirrors what a Swift `adaptToEditPlan()` will do on-device. Asserts → warns; it NEVER rewrites the plan.

export function adaptToEditPlan(index, decisions) {
  const warnings = [];
  const shots = Array.isArray(index.shots) ? index.shots : [];
  const byId = new Map(shots.map((s) => [s.id, s]));
  const order = Array.isArray(decisions.final_edit_order) ? decisions.final_edit_order : [];
  const broll = Array.isArray(decisions.broll_placements) ? decisions.broll_placements : [];

  const trimById = new Map((decisions.trims || []).map((t) => [t.shot_id, t]));
  const voById = new Map((decisions.voiceovers || []).map((v) => [v.shot_id, v]));
  const noteById = new Map((decisions.edit_notes || []).map((n) => [n.shot_id, n]));

  // kept = in the order OR used as a b-roll source
  const kept = new Set(order);
  for (const p of broll) kept.add(p.broll_shot_id);

  // ---- asserts (warn only; on-device EditPlanRepair still repairs at runtime) ----
  if (decisions.hook_id !== order[0]) warnings.push(`hook_id ${decisions.hook_id} != final_edit_order[0] ${order[0]}`);
  const cold = Array.isArray(decisions.cold_open) ? decisions.cold_open : [];
  if (!cold.every((id, i) => order[i] === id)) warnings.push(`cold_open ${JSON.stringify(cold)} is not a prefix of final_edit_order`);
  const seen = new Set();
  for (const id of order) {
    if (!byId.has(id)) warnings.push(`final_edit_order references unknown shot ${id}`);
    if (seen.has(id)) warnings.push(`final_edit_order has duplicate shot ${id}`);
    seen.add(id);
  }
  for (const p of broll) {
    const over = byId.get(p.over_shot_id), src = byId.get(p.broll_shot_id);
    if (!over) warnings.push(`b-roll over_shot ${p.over_shot_id} unknown`);
    else if (over.scene_type !== "talking-head") warnings.push(`b-roll over_shot ${p.over_shot_id} is ${over.scene_type}, not a talking-head`);
    if (!src) warnings.push(`b-roll source ${p.broll_shot_id} unknown`);
    else if (src.scene_type === "talking-head") warnings.push(`b-roll source ${p.broll_shot_id} is a talking-head`);
    if (p.over_shot_id === p.broll_shot_id) warnings.push(`b-roll source equals the shot it covers (${p.over_shot_id})`);
  }

  // ---- segments: one per shot, index fields verbatim + editorial fields derived ----
  const segments = shots.map((s) => ({
    id: s.id,
    start_seconds: s.start_seconds,
    end_seconds: s.end_seconds,
    scene_type: s.scene_type,
    description: s.description ?? "",
    hook_score: s.hook_score ?? 0,
    keep: kept.has(s.id),
    trim_to_seconds: trimById.has(s.id) ? trimById.get(s.id).trim_to_seconds : null,
    voiceover_candidate: voById.has(s.id),
    voiceover_reason: voById.has(s.id) ? (voById.get(s.id).reason ?? null) : null,
    confidence: s.confidence ?? 1,
    edit_note: noteById.has(s.id) ? (noteById.get(s.id).note ?? "") : "",
    section: s.section ?? "unknown",
    topic: s.topic ?? "",
    reaction_kind: s.reaction_kind ?? "none",
  }));

  // ---- broll_placements: shot ids ARE segment ids; relative offset copies through (no math).
  // Reaction gate (mirrors EditPlanAdapter.swift + ReactionKind.minCoverOffset): a bite / the verdict is
  // NEVER covered (drop); a first_taste / peak_reaction keeps its ~3s peak face-on — clamp the offset up,
  // shrink the duration to the kept window, and drop only when nothing ≥1.5s fits.
  const minCoverOffset = (kind) => {
    if (kind === "bite" || kind === "verdict") return null;
    if (kind === "first_taste" || kind === "peak_reaction") return 3.0;
    return 0;
  };
  const fmt = (x) => Number(x).toFixed(1);
  const broll_placements = broll.flatMap((p) => {
    let offset = p.start_offset_seconds;
    let duration = p.duration_seconds;
    const over = byId.get(p.over_shot_id);
    if (over) {
      const minOffset = minCoverOffset(over.reaction_kind ?? "none");
      if (minOffset === null) {
        warnings.push(`dropped b-roll over shot ${p.over_shot_id} — it's a ${over.reaction_kind} reaction (never-cover)`);
        return [];
      }
      if (offset < minOffset) {
        const t = trimById.get(p.over_shot_id)?.trim_to_seconds;
        const end = (t != null && t > over.start_seconds + 0.05 && t < over.end_seconds - 0.05) ? t : over.end_seconds;
        warnings.push(`clamped b-roll over shot ${p.over_shot_id} — ${over.reaction_kind} peak stays face-on (offset ${fmt(offset)} → ${fmt(minOffset)})`);
        offset = minOffset;
        duration = Math.min(duration, (end - over.start_seconds) - offset);
        if (duration < 1.5) {
          warnings.push(`dropped b-roll over shot ${p.over_shot_id} — too short (${fmt(end - over.start_seconds)}s kept) for the ≥${fmt(minOffset)}s peak clamp`);
          return [];
        }
      }
    }
    return [{
      over_segment_id: p.over_shot_id,
      broll_segment_id: p.broll_shot_id,
      start_offset_seconds: offset,
      duration_seconds: duration,
      reason: p.reason ?? null,
    }];
  });

  const plan = {
    video_summary: decisions.video_summary || index.video_summary || "",
    recommended_hook: decisions.recommended_hook || "",
    recommended_duration: decisions.recommended_duration ?? 0,
    final_edit_order: order,
    style_match_notes: decisions.style_match_notes ?? null,
    segments,
    broll_placements,
  };
  return { plan, warnings };
}
