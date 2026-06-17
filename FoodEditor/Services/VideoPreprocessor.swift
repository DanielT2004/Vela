import AVFoundation
import UIKit

/// Maps a stretch of the merged/analysis timeline back to the FULL-RESOLUTION source clip it came
/// from. Gemini analyzes the 720p proxy, so its timestamps are in "merged timeline" seconds; at final
/// export (M8) we use these spans to cut from the original clips instead of the compressed proxy —
/// keeping the exported video at full source quality.
struct SourceSpan {
    let url: URL                // full-resolution original clip (kept for the whole session)
    let assetIdentifier: String?
    let startInMerged: Double   // seconds where this clip begins on the merged/analysis timeline
    let duration: Double        // clip length in seconds
}

/// The merged + compressed result that gets sent to Gemini (a low-res proxy for analysis only).
struct ProcessedVideo {
    let url: URL
    let metadata: VideoMetadata
    let inputBytes: Int64        // combined size of the source clips
    let elapsed: TimeInterval    // how long merge + compress took
    /// Timeline → original-clip map so the final export can use full-resolution sources.
    let sourceSpans: [SourceSpan]
}

enum PreprocessError: LocalizedError {
    case noClips
    case trackCreationFailed
    case noVideoTrack
    case exportInit
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noClips:             return "No clips to process."
        case .trackCreationFailed: return "Couldn't create the composition tracks."
        case .noVideoTrack:        return "A selected clip had no video track."
        case .exportInit:          return "Couldn't start the video exporter."
        case .exportFailed(let m): return "Export failed: \(m)"
        }
    }
}

/// Concatenates the selected clips (in order) into ONE video and compresses it to ~720p in a single
/// `AVAssetExportSession` pass. A normalizing `AVVideoComposition` aspect-fits each clip into a
/// common render frame so mixed orientations/resolutions stitch cleanly. This is the single video
/// that gets uploaded to Gemini (M3); the real 9:16 edit/reframe happens later at export (M8).
enum VideoPreprocessor {
    /// Long edge of the normalized output (720p-class). Keeps uploads fast.
    private static let targetLongEdge: CGFloat = 1280

    static func mergeAndCompress(
        clips: [SourceClip],
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> ProcessedVideo {
        guard !clips.isEmpty else { throw PreprocessError.noClips }
        let started = Date()
        let inputBytes = clips.reduce(Int64(0)) { $0 + ($1.metadata?.fileSizeBytes ?? 0) }
        Log.compress("Merging \(clips.count) clip(s) — combined input \(ByteCountFormatter.string(fromByteCount: inputBytes, countStyle: .file)).")

        let composition = AVMutableComposition()
        guard
            let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw PreprocessError.trackCreationFailed }

        var renderSize = CGSize(width: 720, height: 1280)
        var layerInstructions: [AVMutableVideoCompositionInstruction] = []
        var spans: [SourceSpan] = []
        var cursor = CMTime.zero

        for (i, clip) in clips.enumerated() {
            let asset = AVURLAsset(url: clip.url)
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                Log.compress("Clip \(i + 1) has no video track — skipping.")
                continue
            }
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)

            do {
                try compVideo.insertTimeRange(range, of: vTrack, at: cursor)
            } catch {
                Log.compress("Clip \(i + 1) video insert failed: \(error.localizedDescription) — skipping.")
                continue
            }
            if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
                try? compAudio.insertTimeRange(range, of: aTrack, at: cursor)
            }

            let naturalSize = try await vTrack.load(.naturalSize)
            let preferred = try await vTrack.load(.preferredTransform)
            let displaySize = orientedSize(naturalSize, preferred)

            if i == 0 { renderSize = normalizedRenderSize(for: displaySize) }

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: cursor, duration: duration)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideo)
            layer.setTransform(aspectFitTransform(natural: naturalSize, preferred: preferred, into: renderSize), at: cursor)
            instruction.layerInstructions = [layer]
            layerInstructions.append(instruction)

            spans.append(SourceSpan(url: clip.url,
                                    assetIdentifier: clip.assetIdentifier,
                                    startInMerged: CMTimeGetSeconds(cursor),
                                    duration: CMTimeGetSeconds(duration)))
            Log.compress("Clip \(i + 1): \(Int(displaySize.width))×\(Int(displaySize.height)), \(String(format: "%.1f", CMTimeGetSeconds(duration)))s inserted at \(String(format: "%.1f", CMTimeGetSeconds(cursor)))s.")
            cursor = CMTimeAdd(cursor, duration)
        }

        guard cursor > .zero else { throw PreprocessError.noVideoTrack }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = layerInstructions
        Log.compress("Render size \(Int(renderSize.width))×\(Int(renderSize.height)), total \(String(format: "%.1f", CMTimeGetSeconds(cursor)))s. Exporting…")

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw PreprocessError.exportInit
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-merged-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true

        // Poll progress while the export runs.
        let progressTask = Task {
            while !Task.isCancelled {
                onProgress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        defer { progressTask.cancel() }

        // iOS 17-compatible export (the no-arg async `export()` is iOS 18+).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }
        onProgress(1.0)

        guard export.status == .completed else {
            let msg = export.error?.localizedDescription ?? "status \(export.status.rawValue)"
            throw PreprocessError.exportFailed(msg)
        }

        let fallbackSize = ((try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let meta = await VideoInspector.metadata(for: outURL)
            ?? VideoMetadata(duration: CMTimeGetSeconds(cursor),
                             width: Int(renderSize.width), height: Int(renderSize.height),
                             fileSizeBytes: fallbackSize)
        let elapsed = Date().timeIntervalSince(started)

        let drop = inputBytes > 0 ? Int((1 - Double(meta.fileSizeBytes) / Double(inputBytes)) * 100) : 0
        Log.compress("""
        Done in \(String(format: "%.1f", elapsed))s — \(ByteCountFormatter.string(fromByteCount: inputBytes, countStyle: .file)) \
        → \(meta.fileSizeText) (\(drop)% smaller), \(meta.resolutionText), \(meta.durationText).
        """)

        return ProcessedVideo(url: outURL, metadata: meta, inputBytes: inputBytes, elapsed: elapsed, sourceSpans: spans)
    }

    // MARK: - Geometry helpers

    /// Orientation-corrected display size.
    private static func orientedSize(_ natural: CGSize, _ transform: CGAffineTransform) -> CGSize {
        let r = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(r.width), height: abs(r.height))
    }

    /// Render frame matching the clip's orientation, with the long edge at ~720p, dimensions even.
    private static func normalizedRenderSize(for displaySize: CGSize) -> CGSize {
        let portrait = displaySize.height >= displaySize.width
        let w: CGFloat, h: CGFloat
        if portrait {
            h = targetLongEdge
            w = targetLongEdge * displaySize.width / max(displaySize.height, 1)
        } else {
            w = targetLongEdge
            h = targetLongEdge * displaySize.height / max(displaySize.width, 1)
        }
        return CGSize(width: even(w), height: even(h))
    }

    /// Transform that aspect-fits a source track (after its orientation transform) into `renderSize`,
    /// centered (letterboxed if the aspect differs).
    private static func aspectFitTransform(natural: CGSize, preferred: CGAffineTransform, into renderSize: CGSize) -> CGAffineTransform {
        let displayRect = CGRect(origin: .zero, size: natural).applying(preferred)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let scale = min(renderSize.width / max(displaySize.width, 1), renderSize.height / max(displaySize.height, 1))
        let scaledW = displaySize.width * scale
        let scaledH = displaySize.height * scale
        let tx = (renderSize.width - scaledW) / 2
        let ty = (renderSize.height - scaledH) / 2

        var t = preferred
        // After the orientation transform the content may sit at a negative origin — pull it to (0,0)…
        t = t.concatenating(CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY))
        // …scale to fit…
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        // …then center inside the render frame.
        t = t.concatenating(CGAffineTransform(translationX: tx, y: ty))
        return t
    }

    private static func even(_ v: CGFloat) -> CGFloat {
        let i = Int(v.rounded())
        return CGFloat(i - (i % 2))
    }
}
