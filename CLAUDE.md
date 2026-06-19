# Vela — AI Food Video Editor (native iOS)

Vela takes a creator's raw food footage → sends a compressed proxy to **Google Gemini** for analysis
→ gets back a structured JSON **Edit Plan** → renders it as a three-layer editing experience
(**Triage** swipe deck → **Timeline** fine-tune → **Polish** CapCut-style B-roll editor) → assembles a
full-resolution **9:16 TikTok-ready MP4** and saves it to the camera roll.

iOS-only. Swift / SwiftUI (Observation), AVFoundation, PhotosUI, Swift Concurrency. **Zero third-party
dependencies** — all Apple-native. Aesthetic is **"Warm Editorial"**: food is the hero, the chrome
recedes, no blue / no AI-gradients.

---

## Build, run, verify

```bash
# Authoritative build check (run after every change):
xcodebuild -project FoodEditor.xcodeproj -scheme FoodEditor \
  -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 \
  | grep -E "error:|\*\* BUILD" | head -40
```

- **Test target is a physical iPhone** (real food videos + Photos permission). The user runs it from
  Xcode (set Team under Signing, trust the dev cert). The simulator can't exercise the camera roll well.
- **Adding files needs no pbxproj edits.** The project uses a `PBXFileSystemSynchronizedRootGroup`, so
  any file placed under `FoodEditor/` is auto-included. Just create it in the right folder and build.

### ⚠️ SourceKit diagnostics lie — `xcodebuild` is the source of truth
The editor constantly shows **false-positive** diagnostics like `No such module 'UIKit'`,
`Cannot find 'AppRouter' in scope`, `Type 'Color' has no member 'veCream'`, `'@main' top-level code`.
These are stale-index / wrong-target artifacts. **Ignore them.** Only trust a real `xcodebuild` run.
Do not "fix" code to satisfy these — you'll break working code chasing a ghost.

### Secrets — never commit or echo
The Gemini API key lives ONLY in **`Secrets.xcconfig`** (gitignored) → surfaced into `Info.plist` as
`GEMINI_API_KEY = $(GEMINI_API_KEY)` → read at runtime via `Bundle.main.object(forInfoDictionaryKey:)`.
`Secrets.example.xcconfig` is the committed template. **Never hard-code the key in Swift, print it, or
paste it into chat.** Production should move it behind a proxy (documented, not built). Model:
`gemini-2.5-flash` via the Files API (resumable upload → poll `files.get` ACTIVE → `generateContent`).

---

## Architecture — the Edit Plan is the single source of truth

```
GeminiService → EditPlan (immutable, Decodable) → EditPlanStore (@Observable, editable state)
   → every View reads/mutates the store → preview + export consume it identically
```

- **`EditPlan` / `Segment` / `SceneType`** ([Models/EditPlan.swift](FoodEditor/Models/EditPlan.swift)) —
  mirror the tested Gemini prompt's schema verbatim, with *defensive* decoding (lenient numbers,
  unknown `scene_type` → `.unknown`). `EditPlan.parse(fromRawModelText:)` strips ```` ``` ```` fences.
  Never change the prompt ([Services/GeminiPrompt.swift](FoodEditor/Services/GeminiPrompt.swift)) without
  the user — it's tested.
- **`EditPlanStore`** ([Models/EditPlanStore.swift](FoodEditor/Models/EditPlanStore.swift)) — holds all
  editable state. **Two layers:**
  - **Layer 1 (main spine):** `order: [Int]` — clips with own video + own audio (the voice).
  - **Layer 2 (B-roll):** `brollClips` (source pool, pulled off the spine) + `brollLane: [OverlayClip]`
    (placements that play *silent video over* the spine while the base audio keeps playing).
  - Plus `cutTray`, `hookId`, `trimEnd`, per-clip `clipSpeed`, `clipVolume`.
  - **`renderSlots()` + `baseAudioPieces()` + `overlayAudioPieces()`** flatten both layers into a flat
    render model. **This is the contract:** the live preview and the final export BOTH consume it, so
    **what you see is what you get.** If you add an editing capability, thread it through these three.
- **Proxy vs full-res — `SourceSpan`.** Gemini analyzes a 720p **proxy** (merged clips), so all segment
  timestamps are in "merged proxy seconds." `ProcessedVideo.sourceSpans`
  ([Services/VideoPreprocessor.swift](FoodEditor/Services/VideoPreprocessor.swift)) maps merged seconds
  → the original full-res clip + offset. **Preview uses the proxy; final export cuts from the originals**
  so quality is preserved. `EditPlanAssembler.mapMergedRange(...)` does the mapping.
- **Assembly** ([Assembly/EditPlanAssembler.swift](FoodEditor/Assembly/EditPlanAssembler.swift)):
  `AVMutableComposition` (1080×1920), per-slot video reframed to 9:16 **aspect-fill (center-crop)**,
  speed via `scaleTimeRange`, per-clip volume via `AVMutableAudioMix`. iOS 17-compatible export
  (`exportAsynchronously` in a continuation — NOT the iOS-18 `export()`).
- **Preview compositor** ([Services/PolishComposition.swift](FoodEditor/Services/PolishComposition.swift))
  mirrors the assembler against the proxy. Keep the two in lockstep.

### Navigation
`AppRouter` ([Models/AppRouter.swift](FoodEditor/Models/AppRouter.swift)) — `@Observable` screen enum +
history stack. Flow: `home → picker → processing → segments → triage → timeline → (hook / polish) →
export`. Routed in [Views/RootView.swift](FoodEditor/Views/RootView.swift) with a soft fade.

---

## Design system (match exactly)

[DesignSystem/](FoodEditor/DesignSystem/) — reuse these, don't reinvent:

- **Palette** (`Color.ve*`): `veCream #F7F3EC` (bg), `veSurface #EDE7DC` (secondary surface),
  `veTerracotta #B5654A` (primary action / appetite), `veSage #5F7355` (success / keep),
  `veCharcoal #2E2A26` (text, never pure black), `veWarmGray #8A8178`, `veFaintGray #A89F90`,
  `veOnTerracotta #FBF4EC`, `veNote #F4EFE6`, `veNoteText #6E665C`. Ochre `0x9A7350` = "unsure"/B-roll.
  `Color(hex: 0xRRGGBB)` initializer exists.
- **Type**: `VeFont.serif(_ size, italic:)` (Newsreader-ish, used for titles/captions) and
  `VeFont.sans(_ size, weight:)` (Hanken-ish body/UI). Serif italic for video captions.
- **Components** ([DesignSystem/Components.swift](FoodEditor/DesignSystem/Components.swift)):
  `VibeMeterPill`, `ReasonNote`, `SceneChip`, `PrimaryActionButton`, `BackChevronButton`, `ToastView`.
- **Food gradients** ([DesignSystem/FoodGradients.swift](FoodEditor/DesignSystem/FoodGradients.swift)):
  `FoodTone` (cheese/tomato/herb/dough/char/berry/plate/talk) + `FoodTile` for placeholders. Real art
  comes from `AVAssetImageGenerator` thumbnails of the proxy.

---

## The "nice feel" playbook — motion & UX patterns

This is what makes Vela feel good. When adding a feature, reach for these:

**Motion**
- Springs over linear: `.spring(response: 0.3–0.5, dampingFraction: 0.7–0.85)` for reflow / settle.
- **One-shot hint nudges** to teach a gesture: on a card's `.onAppear`, animate an offset toward the
  suggested direction then spring back to **zero** (rest state stays straight — see TriageView `hint`).
- **Confirmation flash** on commit: a brief centered icon (✓ keep / ✕ cut / ★ hook) scaling in/out.
- Entrance animations on result screens (export celebration springs in).
- Cards/blocks **reflow** with animated `.offset(y:)` when reordering; the dragged item gets `nil`
  animation so it tracks the finger 1:1.

**Haptics** (`import UIKit`)
- Destructive / cut / remove → `UINotificationFeedbackGenerator().notificationOccurred(.warning)`.
- Success (accept-all, saved) → `.notificationOccurred(.success)`.
- Keep / light confirmations → `UIImpactFeedbackGenerator(style: .light)`.
- Pick-up / lift (reorder start) → `.rigid`; drop / commit → `.medium`; soft feedback → `.soft`.

**Video playback**
- Controls-free inline players use `PlayerLayerView` (UIViewRepresentable over `AVPlayerLayer`); the
  parent owns the `AVPlayer`. `LoopingPlayerView` loops a `[start,end]` proxy slice. Loop via
  `.onReceive(NotificationCenter…AVPlayerItemDidPlayToEndTime)` → seek to zero + play.
- Only ONE inline player alive at a time (front card / pinned preview). Pause when a sheet covers it.
- Always call `AudioSession.configureForPlayback()` before play (sound on silent switch).
- **🔒 PERMANENT RULE — full-screen video is always swipe-down-to-dismiss.** Any full-screen video
  player must be dismissible by a top-to-bottom swipe (not only a close button), now and for every
  future player. Two ways to satisfy it:
  - Present it as a **`.sheet`** → the system gives interactive swipe-down for free (e.g.
    `SlicePlayerSheet`).
  - For a **`.fullScreenCover`** (or any custom full-screen player), apply the shared
    **`.swipeDownToDismiss { … }`** modifier ([Views/SwipeToDismiss.swift](FoodEditor/Views/SwipeToDismiss.swift))
    to the content (as `FullScreenPlayer` in PolishView does), and include a small top-center grabber
    affordance. Keep the ✕ button too — swipe is *in addition to*, not instead of.
  - The modifier uses `.simultaneousGesture` so it coexists with AVKit `VideoPlayer` controls; only
    deliberate downward drags dismiss. Never ship a full-screen player that can only be closed by a tap.

**Gestures — avoid the conflicts (learned the hard way)**
- A plain `DragGesture` on scroll content **blocks the ScrollView**. To reorder *and* scroll on the same
  surface: use **`LongPressGesture(0.28).sequenced(before: DragGesture())`** attached with
  **`.simultaneousGesture`** (not `.gesture`), and `.scrollDisabled(isActivelyDragging)` so the scroll
  halts only once a clip is lifted.
- Put conflicting interactions on **separate sub-views** with their own gestures (e.g. a small centered
  trim handle with `.highPriorityGesture`), not full-width strips that swallow scroll.
- Respect **direction**: only act on a swipe when `abs(dx) > abs(dy)` (or vice-versa).
- **Drag in a STABLE coordinate space, never `.local` — the cure for "vibrating" clips.** If a view is
  `.offset` by its own `DragGesture` translation, measure the gesture in a fixed **`.named(...)` space**
  (a non-moving ancestor), not the default `.local`. With `.local` the gesture's origin moves *with* the
  view, so each frame's `translation` is re-measured against the just-moved frame → a feedback loop that
  makes the dragged clip **vibrate/jitter** the whole drag. Fix: one `.coordinateSpace(name:)` on the
  timeline container, then every clip gesture uses
  `DragGesture(coordinateSpace: .named(polishTimelineSpace))` — see
  [Views/PolishView.swift](FoodEditor/Views/PolishView.swift), where the overlay-chip body + trim
  handles, the base-tile drag, and the playhead all share one space. Also set `selection` only on drag
  *begin* (not every frame) and `.transaction { $0.animation = nil }` on the actively-dragged item so it
  tracks the finger 1:1. (The playhead was always smooth because it already used a named space; the clip
  drags used `.local` — that was the bug.)

**Layout robustness**
- Background full-bleed, content inset: put `.background(Color.veCream.ignoresSafeArea())` on the content
  `VStack` so it respects the safe area (header below the status bar, buttons above the home indicator).
  Do NOT wrap content in a full-screen `ZStack` whose background ignores safe area — it drags the whole
  layout edge-to-edge.
- **Clip cards to an explicit height *inside* the view** (`.frame(height:)` then `.clipShape`), never
  rely on an outer frame — otherwise tall content renders outside its slot and overlaps neighbors.
- In hot, frequently-rebuilt lists (drag), use **real `View` structs**, never `AnyView` — `AnyView`
  defeats SwiftUI diffing and makes drags janky.

---

## Working style (what the user expects)

- **Milestone rhythm:** build to a clear, runnable milestone, then **STOP and report exactly what to
  test** (a `⛔` checkpoint). Don't barrel ahead through multiple milestones. Wait for "looks good".
- **Verbose logging is intentional** (MVP/testing). Use `Log` categories
  ([Services/Log.swift](FoodEditor/Services/Log.swift)): `🍳 app 🎞️ video 🗜️ compress 📤 upload
  ⏳ poll 🤖 gemini 🎬 assembly 🔔 notif`. Log the raw Gemini response and per-step pipeline state.
- Fire a **local notification** when the slow Gemini call / export finishes (user may background the app).
- Match surrounding code: comment density, naming, idioms. Reference files as clickable
  `[name](path)` / `[name:line](path#Lline)` links, not backticks.
- The plan file (`~/.claude/plans/im-building-an-ios-purring-melody.md`) is the living milestone log.
- When the user has hand-edited files, **read them first and don't revert their intent.**

---

## Stubbed / out of scope (clearly mark `// TODO`)
Style-profile **learning**, conversational AI re-edit, TikTok OAuth/posting, accounts, payments,
Android/web, backend DB, the production server proxy, Recent-projects persistence, Whisper transcription.

**Known parked bug:** native PHPicker "Add more" preselection (`preselectedAssetIdentifiers`) silently
no-ops on **iOS 26.1/26.2** (Apple regression; works on iOS 18). Code already passes the identifiers.

## Good next steps
Production key proxy (key currently ships in the binary via xcconfig — fine for local testing only),
real **crossfades/transitions** on B-roll cuts (currently hard cuts), Recent-projects persistence on Home.
