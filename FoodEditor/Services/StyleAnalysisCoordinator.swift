import Foundation
import Observation
import UIKit

/// Owns the **style-learning** pipeline (extraction call 1): for each selected finished video, compress →
/// upload → extract a `StyleProfileRaw`, then merge the per-video profiles into one `StyleTemplate`.
///
/// Mirrors `AnalysisCoordinator`'s exactly-once design (phase flips synchronously before the first await;
/// idempotent on the clip-set signature; the Task is held here so analysis survives the view disappearing),
/// but produces a template rather than an EditPlan and does NOT create a project. Reused by onboarding
/// (step 3) and the create-new-template flow (step 9, M6).
@MainActor
@Observable
final class StyleAnalysisCoordinator {
    enum Phase: Equatable { case idle, running, done, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var label = "Getting started"
    private(set) var analyzedCount = 0        // videos finished (drives the mockup's "{n} of {N}" counter)
    private(set) var totalCount = 0
    private(set) var template: StyleTemplate?
    /// First clip's frame — saved as the template's library-tile thumbnail.
    private(set) var posterImage: UIImage?

    private var signature: String?
    private var task: Task<Void, Never>?

    // MARK: entry points

    func start(clips: [SourceClip]) {
        let sig = AnalysisCoordinator.signature(for: clips)
        switch phase {
        case .running:                                   return
        case .done where signature == sig && template != nil: return
        case .failed where signature == sig:             return
        default:                                         break
        }
        launch(clips: clips, signature: sig)
    }

    func retry(clips: [SourceClip]) {
        task?.cancel()
        launch(clips: clips, signature: AnalysisCoordinator.signature(for: clips))
    }

    private func launch(clips: [SourceClip], signature sig: String) {
        signature = sig
        phase = .running
        progress = 0
        analyzedCount = 0
        totalCount = clips.count
        label = "Getting started"
        template = nil
        // The long analysis now runs server-side (one job per video), so only the on-device uploads need
        // a background-task assertion — applied per-upload inside `run`. Once the uploads finish the
        // creator can close the app and the work still completes.
        task = Task { [weak self] in
            await self?.run(clips: clips)
        }
    }

    // MARK: pipeline — one extraction per video, then merge

    private func run(clips: [SourceClip]) async {
        Task { await NotificationService.shared.requestAuthorization() }
        guard !clips.isEmpty else { phase = .failed("No videos to learn from."); return }
        posterImage = clips.first?.thumbnail   // tile thumbnail for the saved template

        do {
            let n = clips.count

            // Phase A (0 → 50%) — compress + upload each video and start a server job for it. After this
            // loop, ALL jobs are running on Supabase, so the creator can close the app.
            var jobIds: [String] = []
            for (i, clip) in clips.enumerated() {
                if Task.isCancelled { return }
                let base = 0.5 * Double(i) / Double(n)
                let span = 0.5 / Double(n)
                label = n > 1 ? "Uploading video \(i + 1) of \(n)" : "Uploading your video"

                // Compress this single video to a 720p proxy (first 60% of its upload slice).
                let proxy = try await VideoPreprocessor.mergeAndCompress(clips: [clip]) { [weak self] p in
                    Task { @MainActor in self?.progress = base + span * (p * 0.6) }
                }
                if Task.isCancelled { return }

                // Upload phone→Google (background-task assertion covers a tap-away mid-upload), then hand
                // the extraction to the server.
                let uploaded = try await BackgroundActivity.run("style-upload") {
                    try await GeminiService.shared.upload(at: proxy.url)
                }
                let jobId = try await GeminiService.shared.startStyleExtractionJob(
                    fileURI: uploaded.fileURI, fileName: uploaded.fileName, mimeType: uploaded.mimeType,
                    prompt: GeminiPrompt.styleProfile)
                jobIds.append(jobId)
                progress = base + span
            }

            // Phase B (50 → 95%) — poll each job to completion. The work runs server-side, so a
            // suspend/resume just continues polling (no lost progress).
            var profiles: [StyleProfileRaw] = []
            for (i, jobId) in jobIds.enumerated() {
                if Task.isCancelled { return }
                let base = 0.5 + 0.45 * Double(i) / Double(n)
                let span = 0.45 / Double(n)
                label = n > 1 ? "Reading video \(i + 1) of \(n)" : "Reading your style"

                let raw = try await GeminiService.shared.awaitJobResult(jobId: jobId) { [weak self] _ in
                    Task { @MainActor in self?.progress = min(base + span * 0.9, 0.95) }
                }
                if Task.isCancelled { return }

                Log.blob(.gemini, "RAW STYLE PROFILE (video \(i + 1)/\(n))", raw)
                profiles.append(try StyleProfileRaw.parse(fromRawModelText: raw))
                analyzedCount = i + 1
                progress = base + span
            }

            // Phase C (95 → 100%) — merge the per-video profiles into one template (unchanged).
            if Task.isCancelled { return }
            label = "Putting your style into words"
            progress = 0.98

            let merged = StyleProfileRaw.merge(profiles)
            let built = StyleTemplate(from: merged, count: clips.count)
            Log.blob(.gemini, "DECODED STYLE TEMPLATE", built.debugSummary)

            template = built
            progress = 1.0
            phase = .done
            NotificationService.shared.notify(
                title: "Your style is ready ✨",
                body: "“\(built.name)” — learned from \(clips.count) video\(clips.count == 1 ? "" : "s"). Tap to review."
            )
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            Log.gemini("Style pipeline error: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            NotificationService.shared.notify(title: "Style analysis hit a snag", body: error.localizedDescription)
        }
    }
}
