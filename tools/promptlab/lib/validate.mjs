// JS mirror of FoodEditor/Models/EditPlanValidator.swift — KEEP IN LOCKSTEP with the Swift version so a
// saved plan.json scores identically here and on-device. Same checks, same severities, same weights.

const TOL = 0.25; // seconds of slop before a gap/overlap/over-length counts (Gemini timestamps are coarse)

/** Strip ```fences``` and grab the outermost {...}, mirroring EditPlan.parse(fromRawModelText:). */
export function parsePlan(rawText) {
  let s = String(rawText).trim();
  if (s.startsWith("```")) {
    const nl = s.indexOf("\n");
    if (nl >= 0) s = s.slice(nl + 1);
    const close = s.lastIndexOf("```");
    if (close >= 0) s = s.slice(0, close);
    s = s.trim();
  }
  const a = s.indexOf("{"), b = s.lastIndexOf("}");
  if (a < 0 || b < 0 || a >= b) throw new Error("no JSON object in model text");
  return JSON.parse(s.slice(a, b + 1));
}

const fmt = (d) => Number(d).toFixed(2);

/**
 * Validate a decoded plan (snake_case JSON, as Gemini returns it) against the prompt's hard constraints.
 * @returns {{score:number, violations:Array, summary:string, segmentCount:number, keptCount:number, coverageSeconds:number, proxyDuration:number}}
 */
export function validatePlan(plan, proxyDuration = 0) {
  const v = [];
  const segs = Array.isArray(plan.segments) ? plan.segments : [];
  const byId = new Map(segs.map((s) => [s.id, s]));
  const add = (kind, severity, detail, segmentId = null) => v.push({ kind, severity, detail, segmentId });

  // per-segment shape
  for (const s of segs) {
    const len = s.end_seconds - s.start_seconds;
    if (len > 15 + TOL) add("segmentTooLong", "high", `segment ${s.id} is ${fmt(len)}s (> 15s cap)`, s.id);
    if (s.end_seconds <= s.start_seconds)
      add("nonPositiveDuration", "high", `segment ${s.id} end ${fmt(s.end_seconds)} ≤ start ${fmt(s.start_seconds)}`, s.id);
    if (proxyDuration > 0 && s.end_seconds > proxyDuration + TOL)
      add("endBeyondVideo", "high", `segment ${s.id} ends at ${fmt(s.end_seconds)}s but the video is ${fmt(proxyDuration)}s`, s.id);
    const t = s.trim_to_seconds;
    if (t != null && !(t > s.start_seconds && t <= s.end_seconds + TOL))
      add("invalidTrim", "medium", `segment ${s.id} trim_to_seconds ${fmt(t)} outside (${fmt(s.start_seconds)}, ${fmt(s.end_seconds)}]`, s.id);
    if (s.scene_type === "unknown" || s.scene_type == null) add("unknownSceneType", "low", `segment ${s.id} unrecognised scene_type`, s.id);
    if (!["intro", "middle", "end"].includes(s.section)) add("unknownSection", "low", `segment ${s.id} unrecognised section`, s.id);
  }

  // coverage (gaps / overlaps)
  const ordered = [...segs].sort((a, b) => a.start_seconds - b.start_seconds);
  let coverage = 0;
  if (ordered.length) {
    const first = ordered[0];
    if (first.start_seconds > TOL) add("coverageGap", "medium", `a ${fmt(first.start_seconds)}s hole before the first segment`, first.id);
    let prevEnd = first.start_seconds;
    for (const s of ordered) {
      const gap = s.start_seconds - prevEnd;
      if (gap > TOL) add("coverageGap", "medium", `${fmt(gap)}s gap before segment ${s.id} (${fmt(prevEnd)} → ${fmt(s.start_seconds)})`, s.id);
      else if (gap < -TOL) add("coverageOverlap", "medium", `segment ${s.id} overlaps the previous by ${fmt(-gap)}s`, s.id);
      coverage += Math.max(0, s.end_seconds - Math.max(s.start_seconds, prevEnd));
      prevEnd = Math.max(prevEnd, s.end_seconds);
    }
    if (proxyDuration > 0 && proxyDuration - prevEnd > TOL)
      add("coverageGap", "medium", `${fmt(proxyDuration - prevEnd)}s of video after the last segment is uncovered`, null);
  }

  // final_edit_order ⊆ keep:true, no dupes
  const order = Array.isArray(plan.final_edit_order) ? plan.final_edit_order : [];
  const seen = new Set();
  for (const id of order) {
    if (seen.has(id)) add("orderDuplicate", "medium", `segment ${id} appears more than once in final_edit_order`, id);
    seen.add(id);
    const s = byId.get(id);
    if (!s) { add("orderRefersToMissing", "high", `final_edit_order lists segment ${id}, which doesn't exist`, id); continue; }
    if (s.keep === false) add("orderRefersToCut", "high", `final_edit_order includes segment ${id}, which is keep:false`, id);
  }

  // b-roll legality (mirrors EditPlanStore.seededLane's silent filters)
  const placements = Array.isArray(plan.broll_placements) ? plan.broll_placements : [];
  const seenBrollSources = new Set();
  for (const p of placements) {
    if (seenBrollSources.has(p.broll_segment_id))
      add("brollDuplicateSource", "medium", `b-roll source segment ${p.broll_segment_id} is used more than once (identical frames replay)`, p.broll_segment_id);
    seenBrollSources.add(p.broll_segment_id);
    const over = byId.get(p.over_segment_id);
    if (!over) add("brollOverMissing", "high", `b-roll over_segment_id ${p.over_segment_id} doesn't exist`, p.over_segment_id);
    else {
      if (over.keep === false) add("brollOverNotKept", "high", `b-roll covers segment ${p.over_segment_id}, which is cut`, p.over_segment_id);
      if (over.scene_type !== "talking-head") add("brollOverNotTalkingHead", "medium", `b-roll covers segment ${p.over_segment_id} (${over.scene_type}), not a talking-head`, p.over_segment_id);
    }
    const src = byId.get(p.broll_segment_id);
    if (!src) add("brollSourceMissing", "high", `b-roll broll_segment_id ${p.broll_segment_id} doesn't exist`, p.broll_segment_id);
    else {
      if (src.keep === false) add("brollSourceNotKept", "high", `b-roll source segment ${p.broll_segment_id} is cut`, p.broll_segment_id);
      if (src.scene_type === "talking-head") add("brollSourceIsTalkingHead", "medium", `b-roll source segment ${p.broll_segment_id} is a talking-head`, p.broll_segment_id);
    }
    if (p.over_segment_id === p.broll_segment_id) add("brollSameAsOver", "high", `b-roll source equals the segment it covers (${p.over_segment_id})`, p.over_segment_id);
    if (over) {
      const window = over.end_seconds - over.start_seconds;
      if (p.start_offset_seconds < -TOL || p.start_offset_seconds + p.duration_seconds > window + TOL)
        add("brollWindowOutOfRange", "medium", `b-roll on segment ${p.over_segment_id}: offset ${fmt(p.start_offset_seconds)} + dur ${fmt(p.duration_seconds)} exceeds the ${fmt(window)}s clip`, p.over_segment_id);
    }
  }

  const penalty = v.reduce((acc, x) => acc + (x.severity === "high" ? 0.15 : x.severity === "medium" ? 0.07 : 0), 0);
  const score = Math.max(0, Math.min(1, 1 - penalty));
  const kept = segs.filter((s) => s.keep !== false).length;
  const tally = Object.entries(v.reduce((m, x) => ((m[x.kind] = (m[x.kind] || 0) + 1), m), {}))
    .map(([k, n]) => `${k}×${n}`).sort().join(", ");
  const summary = v.length ? `score ${fmt(score)} — ${v.length} violation(s): ${tally}` : `Plan valid — ${segs.length} segments, score 1.00`;

  // Planned b-roll coverage — overlay seconds ÷ KEPT talking-on-camera seconds (trims respected);
  // mirrors EditPlanValidator.plannedBrollPct (same denominator as the style target + seeding cap).
  const keptTalking = segs.filter((s) => s.keep !== false && s.scene_type === "talking-head").reduce((acc, s) => {
    const t = s.trim_to_seconds;
    const end = (t != null && t > s.start_seconds && t <= s.end_seconds + TOL) ? Math.min(t, s.end_seconds) : s.end_seconds;
    return acc + Math.max(0, end - s.start_seconds);
  }, 0);
  const overlaySeconds = (plan.broll_placements || []).reduce((acc, p) => acc + Math.max(0, p.duration_seconds || 0), 0);
  const plannedBrollPct = keptTalking > 0 ? overlaySeconds / keptTalking : 0;

  return { score, violations: v, summary, segmentCount: segs.length, keptCount: kept, coverageSeconds: coverage, proxyDuration, plannedBrollPct };
}
