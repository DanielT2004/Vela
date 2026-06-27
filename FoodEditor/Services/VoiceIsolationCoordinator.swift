import Foundation
import AVFoundation
import Observation
import UIKit

/// Owns the **Voice Isolation** pipeline for the Polish page: extract an audio slice of the current edit
/// from the proxy → send it to ElevenLabs' Voice Isolator → save the cleaned MP3 and register it as an
/// `IsolatedAudioSpan` on the store (keyed by proxy-time, so it stays aligned through later edits).
///
/// Mirrors `AnalysisCoordinator`: an `@Observable` owned by `RootView` (so the **paid** call survives the
/// Polish view remounting), an idempotent `start(...)` that flips `phase` synchronously before the first
/// `await`, and a completion notification (the user may background the app while it runs).
@MainActor
@Observable
final class VoiceIsolationCoordinator {
    /// ElevenLabs' Voice Isolator requires at least 5 seconds of audio — shorter input fails. Checked in
    /// the UI (pre-flight, so the user sees a clean message) and again here as a backstop.
    static let minDurationSeconds: Double = 5

    /// What to clean — the whole edit, or one clip's proxy-second range.
    enum Scope: Equatable {
        case entire
        case clip(start: Double, end: Double)
    }

    enum Phase: Equatable {
        case idle
        case exporting          // pulling the audio slice out of the proxy
        case uploading          // round-trip to ElevenLabs
        case done
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var label = ""
    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .exporting || phase == .uploading }

    // MARK: - Entry point

    /// Idempotent — ignores re-entry while a call is in flight. Reads the proxy + store off the session.
    func start(session: VideoSession, scope: Scope) {
        guard !isRunning else { return }
        guard let store = session.store, !store.order.isEmpty, let proxyURL = session.merged?.url else {
            phase = .failed("Nothing to isolate — your timeline is empty.")
            return
        }
        phase = .exporting          // flipped synchronously, before any await → no double-launch
        progress = 0
        label = "Preparing audio"
        task = Task { [weak self] in
            await BackgroundActivity.run("voice-isolation") {
                await self?.run(store: store, proxyURL: proxyURL, scope: scope)
            }
        }
    }

    func cancel() {
        task?.cancel()
        if isRunning { phase = .idle }
    }

    /// Dismiss a finished/failed banner back to neutral (the spans + toggle stay put).
    func acknowledge() {
        if case .done = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    // MARK: - Pipeline

    private func run(store: EditPlanStore, proxyURL: URL, scope: Scope) async {
        Task { await NotificationService.shared.requestAuthorization() }
        do {
            // Resolve the proxy-second range to clean.
            let asset = AVURLAsset(url: proxyURL)
            let proxyDuration = (try? await asset.load(.duration).seconds) ?? store.baseDuration
            let start: Double
            let end: Double
            switch scope {
            case .entire:                 start = 0;            end = max(0, proxyDuration)
            case .clip(let s, let e):     start = max(0, s);    end = min(e, proxyDuration)
            }
            guard end - start >= Self.minDurationSeconds else { throw IsolationError.tooShort }
            Log.audio("Voice isolation — \(scopeLabel(scope)) range [\(String(format: "%.1f", start))–\(String(format: "%.1f", end))s].")

            // 1) Extract the proxy audio slice → .m4a (audio-only; ElevenLabs accepts AAC).
            label = "Exporting audio"; progress = 0.12
            let m4a = try await Self.extractAudioSlice(from: asset, start: start, end: end)
            defer { try? FileManager.default.removeItem(at: m4a) }
            let m4aDur = (try? await AVURLAsset(url: m4a).load(.duration).seconds) ?? -1
            let m4aSize = ((try? FileManager.default.attributesOfItem(atPath: m4a.path))?[.size] as? Int) ?? 0
            Log.audio("Extracted slice → m4a (\(String(format: "%.1f", m4aDur))s, \(ByteCountFormatter.string(fromByteCount: Int64(m4aSize), countStyle: .file))).")
            if Task.isCancelled { return }

            // 2) Round-trip to ElevenLabs → cleaned MP3 bytes.
            phase = .uploading; label = "Cleaning your voice"; progress = 0.5
            let mp3 = try await ElevenLabsService.shared.isolate(audioFileURL: m4a)
            if Task.isCancelled { return }

            // 3) Save the cleaned MP3, then decode it to a composition-safe LPCM .caf. (Raw MP3 source
            //    tracks don't play in an AVMutableComposition — they insert silent — so we decode to LPCM.)
            progress = 0.9
            let mp3URL = FileManager.default.temporaryDirectory
                .appendingPathComponent("vela-voice-\(UUID().uuidString).mp3")
            try mp3.write(to: mp3URL)
            defer { try? FileManager.default.removeItem(at: mp3URL) }

            let cleanedURL = try AudioConvert.toLPCM(mp3URL)

            // Validate before registering — must have an audio track AND real duration. No silent fallback
            // to the original: if the cleaned audio is unreadable, fail honestly so the user knows.
            let cleanedAsset = AVURLAsset(url: cleanedURL)
            let cleanedTrack = try? await cleanedAsset.loadTracks(withMediaType: .audio).first
            let cleanedDur = (try? await cleanedAsset.load(.duration).seconds) ?? 0
            guard cleanedTrack != nil, cleanedDur > 0.2 else {
                try? FileManager.default.removeItem(at: cleanedURL)
                throw IsolationError.unreadableCleaned
            }
            Log.audio("✅ Cleaned voice → LPCM caf (\(String(format: "%.1f", cleanedDur))s; requested \(String(format: "%.1f", end - start))s).")

            // Replace any spans this one overlaps — so "entire" supersedes earlier per-clip isolations.
            let stale = store.isolatedAudio.filter { $0.startProxy < end && $0.endProxy > start }
            store.isolatedAudio.removeAll { $0.startProxy < end && $0.endProxy > start }
            store.isolatedAudio.append(IsolatedAudioSpan(startProxy: start, endProxy: end, url: cleanedURL))
            store.useIsolatedAudio = true
            for s in stale { try? FileManager.default.removeItem(at: s.url) }

            progress = 1; phase = .done
            Log.audio("✅ Registered span [\(String(format: "%.1f", start))–\(String(format: "%.1f", end))s] cafDur=\(String(format: "%.1f", cleanedDur))s. Total spans: \(store.isolatedAudio.count).")
            NotificationService.shared.notify(title: "Clean voice ready 🎙️", body: "Tap to hear your isolated audio.")
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            Log.audio("Voice isolation failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
            NotificationService.shared.notify(title: "Voice isolation hit a snag", body: error.localizedDescription)
        }
    }

    private func scopeLabel(_ scope: Scope) -> String {
        switch scope { case .entire: return "entire video"; case .clip: return "single clip" }
    }

    enum IsolationError: LocalizedError {
        case tooShort, exportInit, exportFailed(String), unreadableCleaned
        var errorDescription: String? {
            switch self {
            case .tooShort:            return "Voice isolation needs at least 5 seconds of audio — pick a longer clip."
            case .exportInit:          return "Couldn't start the audio exporter."
            case .exportFailed(let m): return "Audio export failed: \(m)"
            case .unreadableCleaned:   return "Couldn't read the cleaned audio — please try isolating again."
            }
        }
    }

    /// Export an audio-only `.m4a` slice `[start, end]` of the proxy (iOS-17 `exportAsynchronously`).
    private static func extractAudioSlice(from asset: AVAsset, start: Double, end: Double) async throws -> URL {
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw IsolationError.exportInit
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-voice-src-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       end: CMTime(seconds: end, preferredTimescale: 600))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        guard export.status == .completed else {
            throw IsolationError.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        return outURL
    }
}
