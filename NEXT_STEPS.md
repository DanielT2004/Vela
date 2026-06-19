# Vela — Next Steps Guide

*A grounded roadmap from working MVP → an app a creator trusts enough to post from. Written against
the actual codebase (not just the design doc) on 2026-06-18.*

---

## TL;DR

Vela's MVP genuinely works: pick footage → Gemini analysis → three-layer edit → AVFoundation export,
including the hard voiceover composite. The gap between "impressive demo" and "I'd post this" is
**precise manual control over the cut** plus the **safety rails of a real app** (undo, saved
projects, tests).

There is one finding that shapes everything below:

> **Vela's editable unit is the AI's `Segment`, treated as atomic.** You can shorten a clip from the
> end, but you cannot split a clip, set an in-point, or place the same source twice. That single
> constraint is what blocks "cut at an exact time" — and fixing it also makes clean undo possible.

The good news: the fix is contained to **4 files**, because [`renderSlots()`](FoodEditor/Models/EditPlanStore.swift)
is a stable seam that both the live preview and the exporter consume — so what you see stays what you
get, and the export engine barely changes.

---

## 1. Where Vela actually is today

### What works (don't touch unless improving)
- **Pipeline:** camera-roll pick → merge + 720p compress → Gemini Files-API analysis → parsed Edit
  Plan → three-layer UI → 1080×1920 export → save to camera roll.
- **The voiceover composite** (b-roll video over the creator's real audio for the same time range) —
  the design doc's *highest-risk* piece — is built and WYSIWYG with export.
- **Editing today:** reorder clips, keep/cut (with a restorable Cut Tray), end-only trim, per-clip
  speed + volume, b-roll overlays on a second lane.
- **The seam:** [`renderSlots()`](FoodEditor/Models/EditPlanStore.swift) flattens the spine + overlay
  lane into one slot list that **both** the preview and [`EditPlanAssembler`](FoodEditor/Assembly/EditPlanAssembler.swift)
  render — preview == export by construction.

### What's missing for a "real" editor
| Gap | Why it matters |
|---|---|
| Split / cut at an exact time | The #1 thing a creator expects; impossible today (segment is atomic) |
| In-point trim (move a clip's start) | Today only the end can move; can't recover footage the AI over-trimmed |
| Timeline zoom | On mobile, zoom *is* the frame-precision mechanism — without it cuts land a few frames off |
| Undo / redo | The design doc's #1 principle ("fearless, instant undo"); today only cut clips are restorable |
| Save / resume projects | Nothing survives an app restart; Home's recent-projects tiles are placeholders |
| Automated tests | No test target exists; the riskiest code (export math, JSON parsing) is unguarded |
| Confidence flagging in UI | `Segment.isLowConfidence` exists but isn't surfaced ("never make a silent bad decision") |
| Production API-key handling | The Gemini key is extractable from the app (fine for dev, not for launch) |

### The 4 files that own editing
- [Models/EditPlanStore.swift](FoodEditor/Models/EditPlanStore.swift) — the `@Observable` editable state
- [Views/PolishView.swift](FoodEditor/Views/PolishView.swift) — Layer 3, the horizontal CapCut-style editor (has the playhead)
- [Views/TimelineView.swift](FoodEditor/Views/TimelineView.swift) — Layer 2, vertical "pacing as shape" blocks
- [Assembly/EditPlanAssembler.swift](FoodEditor/Assembly/EditPlanAssembler.swift) — the export engine

---

## 2. Core editing features — what top apps have, mapped to Vela

Researched against how CapCut, iMovie, InShot, VN, and Splice actually behave (plus the
Premiere/Final Cut vocabulary). Scope deliberately excludes filters, color, stickers, transitions,
and music — just the cut/trim/arrange mechanics you asked about.

**The universal mobile model:** a fixed, centered playhead with the timeline scrolling underneath
your finger, and three core verbs — **trim-handle**, **split-at-playhead**, **delete**. Match that and
you match table stakes.

| Primitive | Verdict | Gesture (mobile) | Vela today | Action |
|---|---|---|---|---|
| **Pinch-zoom timeline** to ~1-frame width | **MUST** — *the* precision mechanism on mobile | Two-finger pinch on the timeline | None — fixed `pps` | **Build** |
| **Split at playhead** | **MUST** | Select clip → tap scissors; cuts at the centered line | None | **Build** (needs clip-instance model) ← your explicit ask |
| **Trim both edges** (in + out) | **MUST** | Drag the clip's left/right handle | End-only on base clips; both edges already on overlays | **Build** base in/out trim |
| **Ripple / magnetic main track on delete** | **MUST** | Delete → downstream clips slide left to close the gap | ✓ Have it (the index-based spine reflows) | Keep |
| **Frame-accurate scrub + play-from-playhead** | **MUST** | Drag timeline → preview updates per-frame | ✓ Have it (zero-tolerance seek, 0.05s observer) | Keep |
| **Centered playhead + scroll-under** | **MUST** — the coordinate model | Timeline moves under a fixed center line | Playhead is draggable, not centered | Optional polish — current model works |
| **Snapping + an off toggle** | **MUST** | Clip edges magnetize to playhead/edges; tappable magnet icon | None | Add (medium priority) |
| **Undo / redo** (multi-level) | **MUST** | ↶ ↷ buttons above the timeline | None (Cut Tray only) | **Build** (your priority #1) |
| **Frame-step nudge + timecode readout** | Trust-bar **differentiator** (most consumer apps *lack* it) | ◀/▶ one-frame buttons; a live `0:02.13` readout | None | **Add** — cheap, big trust win for the "last 20%" pitch |
| **Duplicate clip** | Expected | Select → Duplicate | None | Minor add |
| Roll / slip / slide, multi-select, J/L cuts | NICE / advanced | — | None | Defer |

### The minimum trust bar
A creator won't trust the cut enough to post unless they can land it **on the exact frame**. That
requires, at minimum: **pinch-zoom to frame width + split-at-playhead + two-edge trim +
ripple-delete + frame-accurate scrub + undo.** Vela already has ripple-delete and frame-accurate
scrub; the rest is Sprint 1. Adding a **frame-step button + timecode readout** is what separates
"a slider pretending to be precise" from "real frame-accurate editing" — and almost no consumer
mobile app does it, so it's a genuine differentiator for a tool whose whole pitch is *the human
perfects the last 20%*.

---

## 3. Prioritized roadmap

### Sprint 1 — Precise cutting + undo *(headline)*
The clip-instance refactor unblocks split, in-point trim, **and** clean undo at once.
- Clip-instance model (see §4) — the foundation.
- Split-at-playhead, two-edge base trim, pinch-zoom in [PolishView](FoodEditor/Views/PolishView.swift).
- Frame/timecode readout + 1-frame nudge buttons.
- Undo/redo (snapshot stack).
- **Stand up a minimal XCTest target here** to lock preview↔export parity before/after the refactor.

*Why first:* it's your explicit ask, it covers the must-have research items, and undo (your stated
priority #1) falls out almost for free once the editable state is value-type-friendly.

### Sprint 2 — Save / resume projects
- Persist [`VideoSession`](FoodEditor/Models/VideoSession.swift) + [`EditPlanStore`](FoodEditor/Models/EditPlanStore.swift)
  editable state + source-clip references to disk (the Edit Plan is already `Codable`; the editable
  state becomes value-type after Sprint 1, so it serializes cleanly).
- Turn Home's placeholder recent-projects tiles into real, resumable edits.

*Why second:* without it, a creator who closes the app loses their work — a blocker for real daily use.

### Sprint 3 — Tests + hardening
- Grow the test target: `renderSlots()` / split math, the lenient JSON decoder in
  [EditPlan.swift](FoodEditor/Models/EditPlan.swift), and a golden export-parity check.
- Surface low-confidence segments in [TriageView](FoodEditor/Views/TriageView.swift) (the design
  doc's "never make a silent bad decision" — `Segment.isLowConfidence` already exists, just unsurfaced).

### Deferred (pre-launch / V1)
- **API-key serverless proxy** — required before any public release; the `VideoAnalyzing` protocol in
  [GeminiService.swift](FoodEditor/Services/GeminiService.swift) is already the drop-in seam.
- Snapping toggle, duplicate clip, centered-playhead polish.
- **Style-profile learning** — the moat. Defer the mechanism, but **start logging corrections now**
  (cheap, and it keeps the option open — exactly what the design doc recommends).
- Conversational Polish (real model call), Whisper transcription, TikTok posting.

---

## 4. Appendix — precise-cutting implementation design

Enough detail to execute Sprint 1. Verified against the source.

### The new model
New file `FoodEditor/Models/Clip.swift`:
```swift
struct Clip: Identifiable, Equatable {
    let id: UUID                 // stable instance identity (survives reorder/trim/split)
    let sourceSegmentId: Int     // → Segment metadata + SourceSpan mapping
    var inPoint: Double          // absolute proxy seconds (NOT relative to segment.startSeconds)
    var outPoint: Double         // absolute proxy seconds; invariant inPoint < outPoint
    var speed: Double            // 1 = normal
    var volume: Float            // 0…1
    var sourceDuration: Double { max(0.0001, outPoint - inPoint) }
    var timelineDuration: Double { sourceDuration / max(0.25, min(4, speed)) }
}
```
- `EditPlanStore.order` becomes `[Clip]`; the `trimEnd`, `clipSpeed`, `clipVolume` dictionaries are
  **deleted** (their data now lives on `Clip`).
- **Absolute proxy seconds** for in/out is the load-bearing choice: it's the same coordinate space as
  `Segment.startSeconds` and `SourceSpan.startInMerged`, so the proxy→original mapping
  (`mapMergedRange`) and the **entire export engine stay unchanged**.

### Store migration (keep `renderSlots()` output identical)
- Re-key methods from segment-id to clip-UUID (`baseStart`, `reorder`, `speed`, `volume`, selection).
- `renderSlots()` / `baseAudioPieces()` produce the *same* output — just source `srcStart` from
  `clip.inPoint` and `tl` from `clip.timelineDuration` instead of the segment dicts.
- New methods:
  - `split(at timelineT:)` — find the clip under the playhead, convert timeline→source via `speed`,
    frame-snap, replace it with two adjacent clips. **Total duration is unchanged, so b-roll overlay
    positions are unaffected** (no reindex needed).
  - `setIn` / `setOut` — frame-accurate two-edge trim, clamped to the segment's *real* bounds (this
    finally lets a creator recover footage the AI trimmed off).
  - `deleteClip(_:)` — remove a single instance.

### PolishView UI
- **Split button** at the playhead (a scissors in a small toolbar so its hit target never fights the
  scrub gesture); draw a thin tick at `x(playheadT)` showing exactly where the cut lands.
- **Two-edge trim handles** on base tiles — reuse the existing `OverlayChipView` handle pattern that
  already works for overlays (handles appear only when selected, via `highPriorityGesture`).
- **Pinch-zoom:** make `pps` a `@State` driven by a `MagnificationGesture`, clamped so one frame
  (~1/30s) is ≥44pt at max zoom. All pixel↔time math already reads `pps`, so nothing else changes.
- **Undo/redo buttons** in the header.

### Undo
A snapshot stack of a value-type `EditState` (order + brollClips + cutTray + hookId + brollLane).
Copy-on-write makes each snapshot near-free. Take **one snapshot per gesture** by hooking the
existing `beginInteraction` / `endInteraction` lifecycle in PolishView — so a drag is one undo step,
not hundreds.

### Risks to watch
- **Overlay handling on reorder/cut** — filter `order` by `sourceSegmentId` so no orphan instance
  lingers when a source leaves the pool.
- **Speed-scaled split math** — convert the timeline cut point to a source point via `clip.speed`
  (inverse of how `renderSlots` advances source within a sped clip). A sign error here silently
  desyncs preview vs export.
- **Preview↔export parity** — the invariant to protect is `renderSlots()` output. Guard it with a
  test: same slots before/after the refactor for an unedited plan; `Σ slot.duration == baseDuration`
  after any split/trim.
- **TimelineView's single-instance assumption** — gate split to Polish initially; TimelineView (Layer
  2) stays a one-instance-per-source view.

### Build / test order
refactor (verify identical export) → store methods → edge-trim → split → zoom → undo — with the
`renderSlots()` parity test guarding each step.

---

## 5. Verification

- **Compile:** `xcodebuild -project FoodEditor.xcodeproj -scheme FoodEditor -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`
- **Regression bar:** `renderSlots()` yields the same slots before/after the refactor for an unedited
  plan; `Σ slot.duration == baseDuration` after split/trim.
- **On device:** split a clip at the playhead, trim both edges at max zoom, undo/redo the sequence,
  and confirm the exported MP4 matches the Polish preview.
