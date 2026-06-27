import Foundation
import Observation
import UIKit

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
/// The only intentional re-trigger is the user tapping **Retry** on the error state (`retry(...)`).
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
    private(set) var progress: Double = 0
    private(set) var label = "Getting started"
    private(set) var rawResponse: String?

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
        task = Task { [weak self] in
            await self?.runPipeline(session: session, projects: projects)
        }
    }

    private func runPipeline(session: VideoSession, projects: ProjectService) async {
        // Ask for notification permission up front (non-blocking) so we can ping when done.
        Task { await NotificationService.shared.requestAuthorization() }
        do {
            // Phase 1 — PREPPING: merge + compress (0 → 30%). This is an on-device AVFoundation export
            // that iOS kills if backgrounded, so the UI tells the creator to keep the app open; the
            // assertion only buys a brief grace window for an accidental tap-away. Reuse a prior merge.
            let processed: ProcessedVideo
            if let existing = session.merged {
                processed = existing
            } else {
                stage = .preparing; progress = 0; label = "Prepping your footage"
                prepStartedAt = Date(); smoothedEta = nil
                processed = try await BackgroundActivity.run("vela-prep") {
                    try await VideoPreprocessor.mergeAndCompress(clips: session.clips) { [weak self] p in
                        Task { @MainActor in
                            self?.progress = p * 0.30
                            self?.updatePrepETA(progress: p)
                        }
                    }
                }
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

            // Phase 3 — hand the analysis off to the server (55 → 60%).
            label = "Analyzing your footage"; progress = 0.58
            let prompt = styleBlock + briefBlock + GeminiPrompt.editPlan
            let jobId = try await GeminiService.shared.startAnalysisJob(
                fileURI: uploaded.fileURI, fileName: uploaded.fileName, mimeType: uploaded.mimeType, prompt: prompt)

            // Persist the job so it survives a full app KILL (not just backgrounding): copy the proxy to a
            // durable spot + record the jobId. `resumeIfPending` re-attaches on relaunch.
            AnalysisJobStore.save(jobId: jobId, clipSignature: signature ?? "",
                                  proxyURL: processed.url, brollCoverageTarget: brollCoverageTarget)

            // From here the work runs on Supabase (poll + generate) — the creator can now CLOSE THE APP.
            stage = .analyzing

            // Phase 4 — poll the job until done/failed (60 → 95%). The SERVER does the work; if the app
            // is backgrounded here, nothing is lost — the poll just resumes when we're foreground again.
            let raw = try await pollUntilFinished(jobId: jobId)

            // A newer launch (Retry) may have superseded us — don't clobber its result.
            if Task.isCancelled { return }

            // Phase 5 — parse + finalize (95 → 100%).
            try await finalize(raw: raw, processed: processed, session: session, projects: projects)
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
            NotificationService.shared.notify(title: "Analysis hit a snag", body: message, screen: "analysis")
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
    private func pollUntilFinished(jobId: String) async throws -> String {
        try await GeminiService.shared.awaitJobResult(jobId: jobId) { [weak self] stage in
            Task { @MainActor in
                self?.label = stage
                self?.progress = min(0.95, max(self?.progress ?? 0, 0.6) + 0.015)   // gentle creep
            }
        }
    }

    /// The tail of the pipeline: parse the model JSON into an Edit Plan, install it as the session's
    /// store, mark done, register + save the project, notify, and capture a Home-tile poster. Behaviour
    /// is unchanged from the old on-device flow — only how we *got* `raw` changed (a server job).
    private func finalize(raw: String, processed: ProcessedVideo,
                          session: VideoSession, projects: ProjectService, resumed: Bool = false) async throws {
        stage = .finishing; etaSeconds = nil
        label = "Putting it together"; progress = 0.97
        let parsed = try EditPlan.parse(fromRawModelText: raw)
        Log.blob(.gemini, "DECODED EDIT PLAN", parsed.debugSummary)
        Log.gemini(parsed.sectionAuditLine)   // invariant audit — flags a dropped intro / untagged segments

        session.store = EditPlanStore(plan: parsed, brollCoverageTarget: brollCoverageTarget,
                                      openerCount: session.brief?.hookSequence.count ?? 0)
        rawResponse = raw
        progress = 1.0
        phase = .done
        // CP1.2 — register this analyzed session as a saved project.
        projects.startNew(from: parsed)
        projects.save(session: session, reaching: .triage)

        // De-dupe with the server's APNs push: only ping locally when the app is FOREGROUND and this
        // wasn't a reopen-resume. A killed/backgrounded finish is covered by the server push (the one
        // thing a local notification can't deliver). `screen` lets a tap route to the reveal.
        if !resumed, UIApplication.shared.applicationState == .active {
            NotificationService.shared.notify(
                title: "Your cut is ready 🍴",
                body: "\(parsed.segments.count) moments found · ~\(Int(parsed.recommendedDuration))s suggested. Tap to refine.",
                screen: "analysis"
            )
        }

        // CP1.3 — capture a Home-tile poster from the proxy's opening frame, then re-save with it.
        let posterTime = parsed.segments.first(where: { $0.id == parsed.finalEditOrder.first })?.startSeconds ?? 0.5
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
        task = Task { [weak self] in
            await self?.resumePipeline(pending: pending, session: session, projects: projects)
        }
        return true
    }

    private func resumePipeline(pending: PendingAnalysisJob, session: VideoSession, projects: ProjectService) async {
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

            let raw = try await pollUntilFinished(jobId: pending.jobId)
            if Task.isCancelled { return }
            try await finalize(raw: raw, processed: processed, session: session, projects: projects, resumed: true)
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            Log.gemini("Resume error: \(error.localizedDescription)")
            AnalysisJobStore.clear()
            phase = .failed(error.localizedDescription)
            NotificationService.shared.notify(title: "Analysis hit a snag", body: error.localizedDescription, screen: "analysis")
        }
    }

    // MARK: - Clip-set identity

    /// Order- and count-sensitive identity of the submitted clips (reordering or adding a clip is a new
    /// submission → a new analysis). Prefers the photo-library asset id, falls back to the temp file path.
    static func signature(for clips: [SourceClip]) -> String {
        clips.map { $0.assetIdentifier ?? $0.url.path }.joined(separator: "|")
    }
}
