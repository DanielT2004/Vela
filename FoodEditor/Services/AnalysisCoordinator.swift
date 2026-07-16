import Foundation
import Observation
import UIKit

/// A decodable but unusable Edit Plan — refused by `ship()`'s viability gate and routed through the
/// normal `.failed` + Retry path (KNOWN_ISSUES #12).
enum AnalysisViabilityError: LocalizedError {
    case emptyPlan
    var errorDescription: String? {
        "Vela couldn't find usable moments in this footage — try again, or start over with different clips."
    }
}

/// Owns the one-shot **merge + Gemini analysis** pipeline for a session. The pipeline used to live in
/// `ProcessingView.run()`, where it was triggered by the view's `.task` — but a SwiftUI view's mount /
/// remount lifecycle is fragile (RootView's `.id(router.screen)` recreates the view, resetting its
/// `@State`), so a remount could re-fire the **paid** Gemini call. This coordinator moves ownership out
/// of the view into a stable `@Observable` injected from `RootView` (same pattern as `ProjectService`).
///
/// **Exactly-once guarantee.** `start(session:projects:)` is idempotent and safe to call on every
/// `ProcessingView` appearance:
///   • `phase` flips to `.running` **synchronously, before the first `await`** — two near-simultaneous
///     mounts can't both launch (closes the in-flight concurrency window the old guard missed).
///   • idempotency is keyed to a **signature of the submitted clip set**, so re-entering with the same
///     clips no-ops, while a genuinely new submission runs once.
///   • the in-flight `Task` is held **here, not in the view**, so the analysis survives `ProcessingView`
///     disappearing — the user can navigate away or background the app mid-call and it still finishes
///     once and fires the completion notification.
/// The only intentional re-triggers are the user tapping **Retry** on the error state (`retry(...)`)
/// and **Cancel** on the working state (`cancel()`).
@MainActor
@Observable
final class AnalysisCoordinator {
    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)
    }

    /// Where in the pipeline we are — drives the "keep the app open" vs "you can close" messaging.
    /// `.preparing` (on-device compress) and `.uploading` must stay foreground; once `.analyzing` the
    /// work is server-side and the creator can close the app.
    enum Stage { case preparing, uploading, analyzing, finishing }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0 {
        didSet { lastProgressAt = Date(); if isSlow { isSlow = false } }   // any real movement clears "slow"
    }
    private(set) var label = "Getting started"
    private(set) var rawResponse: String?

    /// Upload-stall heuristic. The upload is opaque (URLSession gives no byte callbacks), so instead of a
    /// real meter we flag "slow connection" when the *uploading* stage makes no progress for ~15s — honest
    /// copy in place of a silently frozen arc.
    private(set) var isSlow = false
    private var lastProgressAt = Date()
    private var stallTask: Task<Void, Never>?

    /// Current pipeline stage. `canCloseApp` is true once the work has moved to the server.
    private(set) var stage: Stage = .preparing
    var canCloseApp: Bool { stage == .analyzing || stage == .finishing }
    /// True while the on-device merge+compress (prep) is running — the one step iOS interrupts if the app
    /// is backgrounded (the AVFoundation export gets suspended). `RootView` reads this on a background
    /// transition to ping the creator that compression won't finish unless they come straight back.
    var isCompressing: Bool { phase == .running && stage == .preparing }
    /// Estimated seconds left in the **prepping** (compress) step, or nil when there's no live estimate
    /// (uploading / analyzing). A real countdown derived from the export's progress.
    private(set) var etaSeconds: Int?

    /// ETA bookkeeping for the compress step.
    private var prepStartedAt: Date?
    private var smoothedEta: Double?

    /// Identity of the clip set we are / finished analyzing — the key for "run once per submission."
    private var signature: String?
    /// The owned pipeline task. Lives here (not in the View) so analysis survives the view disappearing.
    private var task: Task<Void, Never>?
    /// Monotonic run counter, bumped on every launch / resume / cancel. The async progress callbacks (the
    /// merge export's poll, the server-job poll) capture the token current when their run began and no-op
    /// once it changes — so a superseded run (cancelled, or replaced by a fresh submission) can never write
    /// into the live run's `progress`. This kills the "14% ↔ 0%" flicker when a creator cancels mid-compress
    /// and immediately re-submits: the old AVFoundation export's progress loop was still firing (this
    /// coordinator is long-lived, so `[weak self]` never lets it go) while the new run climbed from 0.
    private var runToken = 0
    /// The active style's injection block (M7), or "" for a generic edit. Set at launch.
    private var styleBlock = ""
    /// The per-video Pre-Edit Brief block, or "" if no brief. Prepended after the style block. Set at launch.
    private var briefBlock = ""
    /// The active template's B-roll coverage target (fraction 0…1), threaded into the store's seeding cap.
    private var brollCoverageTarget = 0.25

    // MARK: - Entry points

    /// Idempotent. `ProcessingView` calls this from its `.task`, which may fire on every (re)mount.
    /// `styleBlock` carries the active template's Style Injection Block (M7), or "" for a generic edit.
    func start(session: VideoSession, projects: ProjectService, styleBlock: String = "", briefBlock: String = "", brollCoverageTarget: Double = 0.25) {
        let sig = Self.signature(for: session.clips)
        // If a server job for this exact clip set is still pending (persisted across a kill), re-attach to
        // it rather than starting a second (paid) analysis.
        if phase == .idle, let pending = AnalysisJobStore.load(), pending.clipSignature == sig {
            resumeIfPending(session: session, projects: projects)
            return
        }
        switch phase {
        case .running:
            return                                                  // a call is already in flight
        case .done where signature == sig && session.store != nil:
            return                                                  // same clips, result still loaded
        case .failed where signature == sig:
            return                                                  // wait for an explicit Retry
        default:
            break                                                   // .idle / new clips / stale .done
        }
        launch(session: session, projects: projects, signature: sig, styleBlock: styleBlock, briefBlock: briefBlock, brollCoverageTarget: brollCoverageTarget)
    }

    /// The one intentional re-trigger — user tapped Retry on the error state.
    func retry(session: VideoSession, projects: ProjectService, styleBlock: String = "", briefBlock: String = "", brollCoverageTarget: Double = 0.25) {
        task?.cancel()
        launch(session: session, projects: projects, signature: Self.signature(for: session.clips), styleBlock: styleBlock, briefBlock: briefBlock, brollCoverageTarget: brollCoverageTarget)
    }

    /// Creator-initiated stop (ProcessingView's quiet Cancel). Cancels the in-flight pipeline task, drops
    /// the kill-recovery record, and returns to `.idle` — a later identical submission starts FRESH
    /// (deliberately NOT re-attaching: a cancelled run must never silently resume with a stale brief).
    /// An already-submitted server job simply runs out its clock; the reaper cleans it up.
    func cancel() {
        task?.cancel()
        task = nil
        runToken &+= 1           // invalidate any in-flight progress callbacks from the cancelled run
        stallTask?.cancel()
        stallTask = nil
        isSlow = false
        AnalysisJobStore.clear()
        signature = nil          // clears start()'s idempotency key so the same clips can run again
        phase = .idle
        progress = 0
        label = "Getting started"
        stage = .preparing
        etaSeconds = nil
        Log.gemini("Analysis cancelled by the creator — pending job record dropped.")
    }

    // MARK: - Pipeline

    private func launch(session: VideoSession, projects: ProjectService, signature sig: String, styleBlock: String, briefBlock: String, brollCoverageTarget: Double) {
        signature = sig
        self.styleBlock = styleBlock
        self.briefBlock = briefBlock
        self.brollCoverageTarget = brollCoverageTarget
        phase = .running            // flipped synchronously, before any await → no double-launch
        progress = 0
        label = "Getting started"
        rawResponse = nil
        stage = .preparing
        etaSeconds = nil
        prepStartedAt = nil
        smoothedEta = nil
        runToken &+= 1
        let token = runToken
        task = Task { [weak self] in
            await self?.runPipeline(session: session, projects: projects, token: token)
        }
        startStallWatch()
    }

    /// Watch for an upload stall (opaque upload → heuristic): flip `isSlow` once the uploading stage hasn't
    /// advanced for ~15s. Self-terminates when the run leaves `.running`; also killed by `cancel()`.
    private func startStallWatch() {
        stallTask?.cancel()
        lastProgressAt = Date()
        isSlow = false
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                if self.phase != .running { self.isSlow = false; return }
                if self.stage == .uploading, Date().timeIntervalSince(self.lastProgressAt) > 15 {
                    self.isSlow = true
                }
            }
        }
    }

    private func runPipeline(session: VideoSession, projects: ProjectService, token: Int) async {
        // Ask for notification permission up front (non-blocking) so we can ping when done.
        Task { await NotificationService.shared.requestAuthorization() }
        do {
            // Phase 1 — PREPPING: merge + compress (0 → 30%). This is an on-device AVFoundation export
            // that iOS kills if backgrounded, so the UI tells the creator to keep the app open; the
            // assertion only buys a brief grace window for an accidental tap-away. Reuse a prior merge.
            // Compress the proxy AND transcribe the audio CONCURRENTLY — the compressor builds the video
            // while on-device Speech reads the source clips' audio; they don't depend on each other, so
            // running them together hides the transcription time behind the (longer) compression.
            let processed: ProcessedVideo
            let words: [TranscriptionService.Word]
            if let existing = session.merged {
                processed = existing
                words = await TranscriptionService.transcribe(url: existing.url)   // proxy already merged
            } else {
                stage = .preparing; progress = 0; label = "Prepping your footage"
                prepStartedAt = Date(); smoothedEta = nil
                async let compressed: ProcessedVideo = BackgroundActivity.run("vela-prep") {
                    try await VideoPreprocessor.mergeAndCompress(clips: session.clips) { [weak self] p in
                        Task { @MainActor in
                            guard let self, self.runToken == token else { return }   // ignore a superseded run
                            self.progress = p * 0.30
                            self.updatePrepETA(progress: p)
                        }
                    }
                }
                async let transcript: [TranscriptionService.Word] = TranscriptionService.transcribeClips(session.clips)
                processed = try await compressed
                words = await transcript
                session.merged = processed
            }

            // Phase 2 — UPLOADING phone→Google (30 → 55%). Still must keep the app open (brief). Wrapped
            // in a background-task assertion so a tap-away mid-upload can finish in the iOS grace window.
            stage = .uploading; etaSeconds = nil
            label = "Uploading your video"; progress = 0.32
            let uploaded = try await BackgroundActivity.run("vela-upload") {
                try await GeminiService.shared.upload(at: processed.url)
            }
            if Task.isCancelled { return }
            progress = 0.55

            // Phase 3 — hand off to the server. Two paths (FeatureFlags.twoCallPipeline):
            //  • TWO-CALL (new): PERCEIVE (video → content index) → DECIDE (text-only → decisions) → ADAPT.
            //  • MONOLITH (instant revert): the single edit-plan call.
            // Both prepend the transcript block so the model anchors timing to real word times + exact length.
            let transcriptBlock = TranscriptPromptBuilder.block(words: words, duration: processed.metadata.duration,
                                                                clipStarts: processed.sourceSpans.map(\.startInMerged))

            if FeatureFlags.twoCallPipeline {
                // PERCEIVE — describe the footage (Flash, content-index schema). Async job → survives backgrounding.
                label = "Watching your footage"; progress = 0.58
                let perceivePrompt = transcriptBlock + "\n\n" + PerceivePrompt.body
                let perceiveJob = try await GeminiService.shared.startAnalysisJob(
                    fileURI: uploaded.fileURI, fileName: uploaded.fileName, mimeType: uploaded.mimeType,
                    prompt: perceivePrompt, schema: PerceivePrompt.schema)
                AnalysisJobStore.save(jobId: perceiveJob, clipSignature: signature ?? "",
                                      proxyURL: processed.url, brollCoverageTarget: brollCoverageTarget)
                stage = .analyzing
                let indexRaw = try await pollUntilFinished(jobId: perceiveJob, token: token)
                if Task.isCancelled { return }
                // DECIDE (text-only, Pro) → ADAPT → ship.
                try await decideAndShip(indexRaw: indexRaw, styleBriefBlock: styleBlock + briefBlock,
                                        processed: processed, session: session, projects: projects,
                                        words: words, perceiveJobId: perceiveJob)
            } else {
                // MONOLITH — the single edit-plan call.
                label = "Analyzing your footage"; progress = 0.58
                let prompt = styleBlock + briefBlock + transcriptBlock + GeminiPrompt.editPlan
                let jobId = try await GeminiService.shared.startAnalysisJob(
                    fileURI: uploaded.fileURI, fileName: uploaded.fileName, mimeType: uploaded.mimeType, prompt: prompt)
                AnalysisJobStore.save(jobId: jobId, clipSignature: signature ?? "",
                                      proxyURL: processed.url, brollCoverageTarget: brollCoverageTarget)
                stage = .analyzing
                let raw = try await pollUntilFinished(jobId: jobId, token: token)
                if Task.isCancelled { return }
                let parsed = try EditPlan.parse(fromRawModelText: raw)
                try await ship(parsed: parsed, processed: processed, session: session, projects: projects,
                               prompt: prompt, rawForCapture: raw, jobId: jobId, words: words)
            }
        } catch is CancellationError {
            return                                                  // superseded — leave newer state intact
        } catch {
            if Task.isCancelled { return }
            Log.gemini("Pipeline error: \(error.localizedDescription)")
            AnalysisJobStore.clear()                                // genuine failure — don't keep resuming it
            // If the on-device compress was interrupted (the app was backgrounded during prep, which iOS
            // kills), say so in plain language instead of the raw AVFoundation error.
            let interrupted = stage == .preparing && error.localizedDescription.lowercased().contains("interrupt")
            let message = interrupted
                ? "Vela needs to stay open while it preps your footage. Tap Retry to try again."
                : error.localizedDescription
            phase = .failed(message)
            // KNOWN_ISSUES #9 — a server-job failure (.badRequest) already pushed "hit a snag" to any
            // token-bearing device, so stay silent then. Client-side failures (compress / parse /
            // viability) never reached the server and always ping locally. Mirrors the style coordinator.
            let serverPushedFailure: Bool = { if let ge = error as? GeminiError, case .badRequest = ge { return true }; return false }()
            if !serverPushedFailure || NotificationService.shared.deviceTokenHex == nil {
                NotificationService.shared.notify(title: "Your cut hit a snag", body: message, screen: "analysis")
            }
        }
    }

    /// Recompute the prepping countdown from the export's progress (`p` ∈ 0…1). Low-pass smoothed, and
    /// gated to `p > 0.03` so the very first jumpy samples don't produce a wild estimate.
    private func updatePrepETA(progress p: Double) {
        guard stage == .preparing, p > 0.03, let start = prepStartedAt else { return }
        let elapsed = Date().timeIntervalSince(start)
        let raw = elapsed * (1 - p) / p
        let smoothed = smoothedEta.map { $0 * 0.7 + raw * 0.3 } ?? raw
        smoothedEta = smoothed
        etaSeconds = max(1, Int(smoothed.rounded()))
    }

    /// Polls the server job until it finishes, nudging the progress arc on each active tick. The poll /
    /// transient-swallow / cancellation / timeout logic lives in the shared `GeminiService.awaitJobResult`.
    private func pollUntilFinished(jobId: String, token: Int, editing: Bool = false) async throws -> String {
        try await GeminiService.shared.awaitJobResult(jobId: jobId) { [weak self] stage in
            Task { @MainActor in
                guard let self, self.runToken == token else { return }   // ignore a superseded run
                self.label = editing ? "Editing your video" : stage   // DECIDE poll keeps the editing label
                self.progress = min(0.97, max(self.progress, editing ? 0.92 : 0.6) + (editing ? 0.008 : 0.015))
            }
        }
    }

    /// The shared SHIPPING TAIL for BOTH the monolith and the two-call pipeline: validate → word-snap →
    /// b-roll repair → install the store → save / notify / poster. `parsed` is the assembled `EditPlan`
    /// (the monolith parses `raw`; the two-call path ADAPTs the decisions into one). `rawForCapture` is
    /// whatever raw model text to save for inspection (the monolith JSON, or the DECIDE decisions JSON).
    private func ship(parsed: EditPlan, processed: ProcessedVideo,
                      session: VideoSession, projects: ProjectService, resumed: Bool = false,
                      prompt: String? = nil, rawForCapture: String, jobId: String? = nil,
                      words: [TranscriptionService.Word] = [], adaptWarnings: [String] = [],
                      spineIsVerbatim: Bool = false,
                      serverNotifies: Bool = true) async throws {
        stage = .finishing; etaSeconds = nil
        label = "Putting it together"; progress = 0.97
        if !adaptWarnings.isEmpty { Log.gemini("ADAPT warnings (\(adaptWarnings.count)) — " + adaptWarnings.joined(separator: " · ")) }

        // Capture the run's INPUTS for inspection. Best-effort, gated, DEBUG-default.
        let bundle = EvalArtifactStore.captureInputs(
            proxyURL: processed.url, prompt: prompt, raw: rawForCapture,
            clipSignature: signature ?? "", proxyDuration: processed.metadata.duration,
            styleBlockChars: styleBlock.count, briefBlockChars: briefBlock.count,
            jobId: jobId, resumed: resumed)

        Log.blob(.gemini, "DECODED EDIT PLAN", parsed.debugSummary)
        Log.gemini(parsed.sectionAuditLine)   // invariant audit — flags a dropped intro / untagged segments

        // Measure the AI's RAW plan first (so we keep seeing how often it breaks its own rules)…
        let aiValidation = EditPlanValidator.validate(parsed, proxyDuration: processed.metadata.duration)
        Log.gemini("Plan validation (AI) — \(aiValidation.summary)")

        // …word-snap the OUT points to the transcript so a cut never lands mid-word (deterministic safety
        // net; the one place code TRANSFORMS the plan). No transcript → exact no-op. Then deterministically
        // repair the b-roll source-not-kept failure and re-validate what we SHIP. The model is
        // non-deterministic run-to-run, so these code passes guarantee a clean plan every time.
        let (snappedPlan, snapActions) = WordSnapper.snap(parsed, words: words)
        if !snapActions.isEmpty {
            Log.gemini("Word-snap (\(snapActions.count)) — " + snapActions.joined(separator: " · "))
        }
        let (repairedPlan, brollActions) = EditPlanRepair.repairBroll(snappedPlan)
        // …then fill any coverage holes so EVERY second of the proxy reaches the Sort deck — footage the
        // model skipped becomes explicit "watch it and decide" cards instead of silently vanishing.
        let (plan, coverageActions) = EditPlanRepair.fillCoverageGaps(repairedPlan, proxyDuration: processed.metadata.duration)
        let repairActions = brollActions + coverageActions
        let validation = EditPlanValidator.validate(plan, proxyDuration: processed.metadata.duration)
        if !brollActions.isEmpty {
            Log.gemini("B-roll repair (\(brollActions.count)) — " + brollActions.joined(separator: " · "))
        }
        if !coverageActions.isEmpty {
            Log.gemini("Coverage repair (\(coverageActions.count)) — " + coverageActions.joined(separator: " · "))
        }
        if !repairActions.isEmpty {
            Log.gemini("Plan validation (shipped, after repair) — \(validation.summary)")
        }
        // Style conformance in one line: planned coverage vs the creator's target (same talking-time
        // denominator on both sides), so an under-covering run is visible in the console + eval bundle.
        Log.gemini(String(format: "Planned b-roll — %.0f%% of kept talking time covered (target %.0f%%)",
                          validation.plannedBrollPct * 100, brollCoverageTarget * 100))
        if let bundle {
            EvalArtifactStore.attachPlan(bundle: bundle, plan: plan, validation: validation,
                                         aiValidation: aiValidation, repairActions: repairActions,
                                         brollTargetPct: brollCoverageTarget)
        }

        let store = EditPlanStore(plan: plan, brollCoverageTarget: brollCoverageTarget, spineIsVerbatim: spineIsVerbatim)
        // KNOWN_ISSUES #12 — a degenerate plan (no segments, or an empty resolved spine) must fail loudly
        // into the normal .failed + Retry path, never ship as a silent empty cut. `store.order` is the
        // resolved spine on BOTH pipeline paths, so this also covers "decodes fine but keeps nothing".
        guard !plan.segments.isEmpty, !store.order.isEmpty else {
            Log.gemini("Viability gate — refusing to ship (segments: \(plan.segments.count), spine: \(store.order.count)).")
            throw AnalysisViabilityError.emptyPlan
        }
        session.store = store
        rawResponse = rawForCapture
        progress = 1.0
        phase = .done
        // CP1.2 — register this analyzed session as a saved project (the repaired plan, so resume keeps the fix).
        projects.startNew(from: plan)
        projects.save(session: session, reaching: .triage)

        // Notify "cut is ready" — exactly once, only for the completions the SERVER can't announce.
        // `serverNotifies` is true when a server job's success push covers this finish (the monolith
        // `analyze` job); in that case the client stays silent to avoid a double when the user reopens after
        // backgrounding. It's false when DECIDE ran ON-DEVICE (the two-call Gemini path) — no server job, so
        // the client posts the only ping. Fires in background too (the on-device DECIDE runs under a
        // background assertion), just not on a reopen-resume (the user is already back in the app;
        // `phase == .done` routes them to the reveal).
        if !serverNotifies, !resumed {
            NotificationService.shared.notify(
                title: "Your first cut is ready 🍴",
                body: "~\(Int(plan.recommendedDuration))s, cut from \(plan.segments.count) moments. Tap to watch it.",
                screen: "analysis"
            )
        }

        // CP1.3 — capture a Home-tile poster from the proxy's opening frame, then re-save with it.
        let posterTime = plan.segments.first(where: { $0.id == plan.finalEditOrder.first })?.startSeconds ?? 0.5
        if let poster = await ThumbnailService.thumbnail(for: processed.url, at: posterTime) {
            projects.save(session: session, poster: poster)
        }

        // A resumed session is reading the PendingAnalysis durable proxy, which `clear()` is about to
        // delete — repoint it at the project's persisted copy (a proxy-identity span, exactly like
        // `ProjectService.resume`) so preview + thumbnails across reveal / segments / editor don't read a
        // dangling file URL. (The normal in-session path keeps its temp proxy + full-res spans untouched.)
        if resumed, let stable = projects.currentProxyURL,
           FileManager.default.fileExists(atPath: stable.path) {
            let span = SourceSpan(url: stable, assetIdentifier: nil, startInMerged: 0,
                                  duration: processed.metadata.duration)
            session.merged = ProcessedVideo(url: stable, metadata: processed.metadata,
                                            inputBytes: processed.inputBytes, elapsed: processed.elapsed,
                                            sourceSpans: [span])
        }

        AnalysisJobStore.clear()   // job done + project saved — drop the kill-recovery record + durable proxy
    }

    /// DECIDE runs text-only via the proxy's SYNCHRONOUS `generate` op. Gemini Pro finishes in ~40–60s
    /// (well under the ~150s edge wall-clock), so no async job / self-bail is needed. (Claude Sonnet + thinking
    /// scored a touch higher editorially but its ~150s runs time out on the free tier — parked in git history
    /// for a future paid tier.) Uses the `-latest` alias because Google retired the pinned `gemini-2.5-*`
    /// IDs (2026-07); revisit pinning to a dated snapshot before public launch.
    private static let decideModel = "gemini-pro-latest"

    /// The two-call tail: PERCEIVE content-index JSON → normalize → DECIDE (text-only) → ADAPT → `ship`.
    /// Shared by the live run and the kill-recovery resume. ADAPT produces the same `EditPlan` shape, so the
    /// shipping tail (word-snap, b-roll repair, validator, EditPlanStore) is identical to the monolith path.
    private func decideAndShip(indexRaw: String, styleBriefBlock: String, processed: ProcessedVideo,
                               session: VideoSession, projects: ProjectService, resumed: Bool = false,
                               words: [TranscriptionService.Word] = [], perceiveJobId: String) async throws {
        let parsedIndex = try ContentIndex.parse(fromRawModelText: indexRaw)
        let (index, normActions) = ContentIndexNormalizer.normalize(parsedIndex)
        Log.gemini("PERCEIVE — \(index.shots.count) shots, \(index.talkSpans.count) talk_spans"
                   + (normActions.isEmpty ? "" : " · normalized: " + normActions.joined(separator: ", ")))

        // DECIDE — the text-only editor (Pro). Re-serialize the NORMALIZED index so DECIDE references the
        // SAME shot ids ADAPT will use.
        label = "Editing your video"; progress = 0.92
        let indexJSON = (try? String(data: JSONEncoder().encode(index), encoding: .utf8)) ?? indexRaw
        let decidePrompt = styleBriefBlock + DecidePrompt.body + "\n\n=== CONTENT INDEX ===\n" + indexJSON
        // DECIDE — synchronous Gemini 2.5 Pro text-only call (no async job; ~40–60s fits under the edge cap).
        let decideRaw = try await BackgroundActivity.run("vela-decide") {
            try await GeminiService.shared.decide(prompt: decidePrompt, schema: DecidePrompt.schema, model: Self.decideModel)
        }
        let decisions = try EditDecisions.parse(fromRawModelText: decideRaw)
        let (plan, warnings) = EditPlanAdapter.adapt(index: index, decisions: decisions)

        // DECIDE ran ON-DEVICE (no server DECIDE job), so the client posts the "cut is ready" ping itself
        // (`serverNotifies: false`). PERCEIVE was submitted with `notifyOnFinish: false`, so nothing double-pings.
        try await ship(parsed: plan, processed: processed, session: session, projects: projects, resumed: resumed,
                       prompt: decidePrompt, rawForCapture: decideRaw, jobId: perceiveJobId, words: words,
                       adaptWarnings: warnings, spineIsVerbatim: true, serverNotifies: false)
    }

    // MARK: - Kill recovery (full app termination, not just backgrounding)

    /// Re-attach to a persisted job after the app was killed mid-analysis and finish it. Called by
    /// `RootView` on cold launch and on every foreground transition; **idempotent** — no-ops unless we're
    /// `.idle` with a saved pending job, so it never disturbs a live run, a loaded result, or a surfaced
    /// error. The job already ran server-side, so this only polls + finalizes (no re-upload, no re-pay).
    /// Returns `true` when it actually kicked off a resume (a pending job existed and we were idle) — so
    /// `RootView` can route the user to Processing → the reveal. `false` is a no-op (nothing to resume).
    @discardableResult
    func resumeIfPending(session: VideoSession, projects: ProjectService) -> Bool {
        guard phase == .idle, let pending = AnalysisJobStore.load() else { return false }
        Log.gemini("Resuming pending analysis job \(pending.jobId) after relaunch.")
        signature = pending.clipSignature
        brollCoverageTarget = pending.brollCoverageTarget
        phase = .running            // synchronous flip → can't double-resume
        stage = .analyzing          // resume is always post-upload → server-side, safe to close
        etaSeconds = nil
        progress = 0.6
        label = "Analyzing your footage"
        rawResponse = nil
        runToken &+= 1
        let token = runToken
        task = Task { [weak self] in
            await self?.resumePipeline(pending: pending, session: session, projects: projects, token: token)
        }
        return true
    }

    private func resumePipeline(pending: PendingAnalysisJob, session: VideoSession, projects: ProjectService, token: Int) async {
        Task { await NotificationService.shared.requestAuthorization() }
        do {
            // Rebuild the merged proxy from the durable copy if the session lost it (cold launch after a
            // kill). A proxy-identity span means export falls back to proxy quality — same as a resumed
            // saved project (full-res re-resolution from the camera roll is a later milestone).
            let processed: ProcessedVideo
            if let existing = session.merged {
                processed = existing
            } else {
                let url = URL(fileURLWithPath: pending.proxyPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    Log.gemini("Resume: durable proxy missing — dropping pending job.")
                    AnalysisJobStore.clear(); phase = .idle; return
                }
                let meta = await VideoInspector.metadata(for: url)
                    ?? VideoMetadata(duration: 0, width: 1080, height: 1920, fileSizeBytes: 0)
                let span = SourceSpan(url: url, assetIdentifier: nil, startInMerged: 0, duration: meta.duration)
                processed = ProcessedVideo(url: url, metadata: meta, inputBytes: 0, elapsed: 0, sourceSpans: [span])
                session.merged = processed
            }

            let raw = try await pollUntilFinished(jobId: pending.jobId, token: token)
            if Task.isCancelled { return }
            // The persisted job is whichever first call ran (PERCEIVE for two-call, the edit-plan call for
            // monolith). Resumed after a kill, style/brief are lost (DECIDE falls back to general judgement)
            // and there's no transcript (no word-snap) — acceptable for kill-recovery.
            if FeatureFlags.twoCallPipeline {
                try await decideAndShip(indexRaw: raw, styleBriefBlock: styleBlock + briefBlock,
                                        processed: processed, session: session, projects: projects,
                                        resumed: true, perceiveJobId: pending.jobId)
            } else {
                let parsed = try EditPlan.parse(fromRawModelText: raw)
                try await ship(parsed: parsed, processed: processed, session: session, projects: projects,
                               resumed: true, prompt: nil, rawForCapture: raw, jobId: pending.jobId)
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            Log.gemini("Resume error: \(error.localizedDescription)")
            AnalysisJobStore.clear()
            phase = .failed(error.localizedDescription)
            // Same two-condition gate as the live pipeline (KNOWN_ISSUES #9).
            let serverPushedFailure: Bool = { if let ge = error as? GeminiError, case .badRequest = ge { return true }; return false }()
            if !serverPushedFailure || NotificationService.shared.deviceTokenHex == nil {
                NotificationService.shared.notify(title: "Your cut hit a snag", body: error.localizedDescription, screen: "analysis")
            }
        }
    }

    // MARK: - Clip-set identity

    /// Order- and count-sensitive identity of the submitted clips (reordering or adding a clip is a new
    /// submission → a new analysis). Prefers the photo-library asset id, falls back to the temp file path.
    static func signature(for clips: [SourceClip]) -> String {
        clips.map { $0.assetIdentifier ?? $0.url.path }.joined(separator: "|")
    }
}
