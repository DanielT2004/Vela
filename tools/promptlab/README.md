# Vela Prompt Lab

Replay a saved proxy video against **prompt / model / schema variants** off-device, in seconds, with no
app rebuild — then score every result two ways: an **objective validator** (the same hard-constraint
checks the app runs) and an **LLM judge** (subjective TikTok quality). This is how we A/B a prompt or model
change and *prove* it beats the baseline instead of guessing.

Zero dependencies — Node 18+ only (uses global `fetch`). **No new API key:** it routes through your existing
Supabase `gemini-proxy` function with the anon key you already have — exactly like the app.

## One-time setup
1. Copy your two Supabase values from `FoodEditor/Secrets.xcconfig` into your shell:
   ```bash
   export SUPABASE_PROJECT_REF=...      # the Reference ID
   export SUPABASE_ANON_KEY=...         # the anon public key (public by design — safe on your Mac)
   ```
2. Put a proxy video in `fixtures/`. Easiest: on the phone, **EVAL LAB · DEBUG → Share runs**, AirDrop the
   zip to your Mac, unzip, and copy a run's `proxy.mp4` into `fixtures/` (e.g. `fixtures/howlins-proxy.mp4`).
   Any food video works too — but a real captured proxy reproduces a real run exactly.
3. Point `config.json` at it (`videos[].path` + `durationSeconds`).

## Run
```bash
node run.mjs                          # uploads each proxy once, fans out every cell → runs/summary.csv
node judge.mjs                        # grades each plan with the LLM judge → runs/summary_judged.csv
```
The big video upload still goes straight Mac→Google (the resumable URL is its own credential); only the small
key-bearing control calls go through your Supabase function. Long videos use the same async job path as the
app, so they won't time out.
Open `runs/summary.csv` (objective violation scores) next to `runs/summary_judged.csv` (rubric scores) and
compare variants. Each cell also leaves `runs/<video>/<cell>/{raw.json,plan.json,validation.json,judge.json}`.

## The experiment matrix (`config.json`)
- `videos` — proxies to test (frozen bytes, so prompt changes are isolated from encoder noise)
- `prompts` — files in `prompts/`. `baseline.txt` is a verbatim copy of `GeminiPrompt.editPlan`.
  A prompt may start with `@extends baseline.txt` to inherit the baseline and append an override — see
  `broll-keep-fix.txt`, the first real experiment (forces b-roll sources to be `keep:true`).
- `models` — e.g. `gemini-2.5-flash`, `gemini-2.5-pro`
- `schemaOn` — `true`/`false` to test the strict `responseSchema` (mirrored in `schema.json`)

## Rubric (judge.mjs)
hook_strength · keep_cut_correctness · ordering_narrative · speech_boundary_cleanliness · broll_relevance ·
duration_discipline (each 1–5, justifications must cite segment ids) · overall (0–100) · would_post_as_is · top_fix.

## Keep in lockstep with the app
- `lib/validate.mjs` mirrors `FoodEditor/Models/EditPlanValidator.swift`
- `adapt-plan.mjs` mirrors `FoodEditor/Models/EditPlanAdapter.swift` (incl. the b-roll reaction gate / ≥3s peak clamp) — no automated guard; if you touch one, touch both
- `prompts/decide.txt` mirrors `DecidePrompt.body` — no automated guard; if you touch one, touch both
- `schema.json` mirrors `GeminiService.responseSchema`
- `prompts/baseline.txt` mirrors `GeminiPrompt.editPlan`
- `prompts/style-v2.txt` mirrors `GeminiPrompt.styleProfile` — run-style-extract.mjs HARD-FAILS on drift (re-extract with the awk one-liner in git history)
- `prompts/style-consolidate.txt` mirrors `StyleConsolidator.promptBody` — run-style-consolidate.mjs hard-fails on drift
- `style-schema.json` mirrors `StyleConsolidator.extractionSchema` (the consolidation schema = same + `seen_in`) — no automated guard; if you touch one, touch both
- `build-style-block.mjs` re-implements `StyleConstraintBuilder.block` — pinned by SHA-256; check-signatures.mjs hard-fails stale fixtures ("mirror out of date" → re-run style-fidelity-setup.mjs)
If you change one side, update the other (the scores must stay comparable).
