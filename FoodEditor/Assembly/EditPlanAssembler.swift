import AVFoundation
import UIKit

enum AssemblyError: LocalizedError {
    case noSpans, noKeptClips, trackCreationFailed, emptyComposition, exportInit, exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSpans:             return "The source map is missing — re-import your clips."
        case .noKeptClips:         return "Nothing to export — every clip is in the Cut Tray."
        case .trackCreationFailed: return "Couldn't create the composition tracks."
        case .emptyComposition:    return "Couldn't assemble any video from the edit."
        case .exportInit:          return "Couldn't start the exporter."
        case .exportFailed(let m): return "Export failed: \(m)"
        }
    }
}

/// M8 — turns the edited plan into a real, full-resolution 9:16 MP4.
///
/// Gemini's timestamps are in the merged 720p **proxy** timeline; `SourceSpan`s map those seconds
/// back to the original full-res clips, so the final render is cut from the originals (not the proxy).
/// It renders the flat `EditPlanStore.renderSlots()` — the same slot list the Polish preview shows —
/// so the exported file matches the preview. For each slot:
///   • audio = always the base segment's own original audio (keeps the creator's real voice);
///   • video = the base segment's own video, UNLESS a B-roll overlay covers the slot, in which case
///     the overlay's source fills it (silent) while the base audio keeps playing underneath.
/// A 1080×1920 `AVVideoComposition` reframes every source to 9:16 (aspect-fill, center-crop).
enum EditPlanAssembler {
    static let renderSize = CGSize(width: 1080, height: 1920)

    /// One source clip available to the assembler, identified by a stable `key`. The `asset` may be an
    /// `AVURLAsset` (a fresh temp clip or the saved proxy) or a Photos-resolved `AVAsset` (resumed
    /// full-res). `startInMerged`/`duration` place it on the analysis (proxy) timeline — the same
    /// coordinate space Gemini timestamps live in.
    struct AssetSpan {
        let key: String
        let asset: AVAsset
        let startInMerged: Double
        let duration: Double
    }

    /// A slice of one source clip (range is in that clip's own timeline).
    private struct Piece { let key: String; let range: CMTimeRange }

    private struct SourceInfo {
        let asset: AVAsset             // retained so its tracks stay valid for insertion
        let video: AVAssetTrack?
        let audio: AVAssetTrack?
        let natural: CGSize
        let preferred: CGAffineTransform
    }

    static func assemble(
        store: EditPlanStore,
        sources: [AssetSpan],
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard !sources.isEmpty else { throw AssemblyError.noSpans }
        guard !store.order.isEmpty else { throw AssemblyError.noKeptClips }
        let slots = store.renderSlots()

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AssemblyError.trackCreationFailed }

        let assetByKey: [String: AVAsset] = Dictionary(sources.map { ($0.key, $0.asset) }, uniquingKeysWith: { a, _ in a })

        // Load + cache each source clip's tracks/orientation once.
        var infoCache: [String: SourceInfo] = [:]
        func sourceInfo(_ key: String) async -> SourceInfo {
            if let c = infoCache[key] { return c }
            let asset = assetByKey[key] ?? AVURLAsset(url: URL(fileURLWithPath: key))
            let v = (try? await asset.loadTracks(withMediaType: .video))?.first
            let au = (try? await asset.loadTracks(withMediaType: .audio))?.first
            let natural = ((try? await v?.load(.naturalSize)) ?? nil) ?? renderSize
            let preferred = ((try? await v?.load(.preferredTransform)) ?? nil) ?? .identity
            let info = SourceInfo(asset: asset, video: v, audio: au, natural: natural, preferred: preferred)
            infoCache[key] = info
            return info
        }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor = CMTime.zero   // export timeline cursor (driven by the video track)
        var mixParams: [AVMutableAudioMixInputParameters] = []

        /// Build one audio track (base or overlay) from clip pieces, with gaps + speed scaling, and
        /// register its per-clip volume on the audio mix.
        func buildAudioTrack(_ pieces: [AudioPiece]) async {
            guard !pieces.isEmpty,
                  let aTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { return }
            let sorted = pieces.sorted { $0.baseStart < $1.baseStart }
            var trackEnd = CMTime.zero
            for p in sorted {
                let at = CMTime(seconds: p.baseStart, preferredTimescale: 600)
                if CMTimeCompare(at, trackEnd) > 0 {
                    aTrack.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at))
                }
                var c = at
                for piece in mapMergedRange(start: p.sourceStart, end: p.sourceStart + p.sourceDuration, sources: sources) {
                    let info = await sourceInfo(piece.key)
                    if let srcAudio = info.audio { try? aTrack.insertTimeRange(piece.range, of: srcAudio, at: c) }
                    c = CMTimeAdd(c, piece.range.duration)
                }
                if p.speed != 1 && CMTimeCompare(c, at) > 0 {
                    aTrack.scaleTimeRange(CMTimeRange(start: at, duration: CMTimeSubtract(c, at)),
                                          toDuration: CMTime(seconds: p.timelineDuration, preferredTimescale: 600))
                }
                trackEnd = CMTime(seconds: p.baseStart + p.timelineDuration, preferredTimescale: 600)
            }
            let params = AVMutableAudioMixInputParameters(track: aTrack)
            params.audioTimePitchAlgorithm = .spectral
            var prev: Float = -1
            for p in sorted where p.volume != prev {
                params.setVolume(p.volume, at: CMTime(seconds: p.baseStart, preferredTimescale: 600))
                prev = p.volume
            }
            mixParams.append(params)
        }

        Log.assembly("Assembling \(slots.count) slot(s) → \(Int(renderSize.width))×\(Int(renderSize.height)) 9:16…")

        for slot in slots {
            let dur = slot.duration
            guard dur > 0.04 else { continue }

            let slotStart = cursor
            let srcLen = dur * slot.videoSpeed

            // Insert the slot's video (unscaled), recording each original piece for its instruction.
            var unscaledCursor = slotStart
            var pieces: [(range: CMTimeRange, natural: CGSize, preferred: CGAffineTransform)] = []
            var remaining = srcLen
            for piece in mapMergedRange(start: slot.videoSourceStart, end: slot.videoSourceStart + srcLen, sources: sources) {
                if remaining <= 0.01 { break }
                let take = min(piece.range.duration.seconds, remaining)
                guard take > 0.01 else { continue }
                let useRange = CMTimeRange(start: piece.range.start, duration: CMTime(seconds: take, preferredTimescale: 600))
                let info = await sourceInfo(piece.key)
                if let srcVideo = info.video,
                   (try? vTrack.insertTimeRange(useRange, of: srcVideo, at: unscaledCursor)) != nil {
                    pieces.append((CMTimeRange(start: unscaledCursor, duration: useRange.duration), info.natural, info.preferred))
                    unscaledCursor = CMTimeAdd(unscaledCursor, useRange.duration)
                    remaining -= take
                }
            }
            let insertedLen = CMTimeSubtract(unscaledCursor, slotStart)
            guard insertedLen.seconds > 0.01 else {
                Log.assembly("Slot @\(String(format: "%.1f", CMTimeGetSeconds(slotStart)))s: no mappable video — skipped.")
                continue
            }

            // Speed: scale the inserted run to the timeline duration; instructions in scaled coords.
            var f = 1.0
            if slot.videoSpeed != 1 {
                vTrack.scaleTimeRange(CMTimeRange(start: slotStart, duration: insertedLen),
                                      toDuration: CMTime(seconds: dur, preferredTimescale: 600))
                f = dur / insertedLen.seconds
            }
            var insStart = slotStart
            for p in pieces {
                let scaled = CMTime(seconds: p.range.duration.seconds * f, preferredTimescale: 600)
                instructions.append(makeInstruction(track: vTrack, range: CMTimeRange(start: insStart, duration: scaled),
                                                    natural: p.natural, preferred: p.preferred,
                                                    cropScale: slot.cropScale, cropOffsetX: slot.cropOffsetX, cropOffsetY: slot.cropOffsetY))
                insStart = CMTimeAdd(insStart, scaled)
            }
            cursor = insStart
            let speedTag = slot.videoSpeed != 1 ? String(format: " @%.2g×", slot.videoSpeed) : ""
            Log.assembly("Slot \(slot.isOverlay ? "b-roll \(slot.videoSegId)" : "clip \(slot.videoSegId)")\(speedTag), \(String(format: "%.1f", dur))s.")
        }

        guard cursor > .zero, !instructions.isEmpty else { throw AssemblyError.emptyComposition }

        // ---- AUDIO: base voice + un-muted overlay, mixed per-clip volume ----
        await buildAudioTrack(store.baseAudioPieces())
        await buildAudioTrack(store.overlayAudioPieces())

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        // ---- TEXT: burn captions in via a Core-Animation layer over the composited video ----
        if !store.textOverlays.isEmpty {
            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: renderSize)
            let videoLayer = CALayer(); videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            var burned = 0
            for o in store.textOverlays {
                if let l = TextOverlayRenderer.layer(for: o, renderSize: renderSize) { parent.addSublayer(l); burned += 1 }
            }
            if burned > 0 {
                videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
                Log.assembly("Burned \(burned) text overlay(s) into the export.")
            }
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw AssemblyError.exportInit
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-final-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
        export.outputURL = outURL
        export.outputFileType = .mp4
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            export.audioMix = mix
        }
        export.audioTimePitchAlgorithm = .spectral

        Log.assembly("Exporting final cut (\(String(format: "%.1f", CMTimeGetSeconds(cursor)))s)…")
        let progressTask = Task {
            while !Task.isCancelled {
                onProgress(Double(export.progress))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        defer { progressTask.cancel() }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { c.resume() }
        }
        onProgress(1)

        guard export.status == .completed else {
            throw AssemblyError.exportFailed(export.error?.localizedDescription ?? "status \(export.status.rawValue)")
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: outURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        Log.assembly("✅ Final cut: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)), \(String(format: "%.1f", CMTimeGetSeconds(cursor)))s → \(outURL.lastPathComponent)")
        return outURL
    }

    // MARK: - Helpers

    /// Splits a merged-timeline range into the source-clip slices it overlaps.
    private static func mapMergedRange(start: Double, end: Double, sources: [AssetSpan]) -> [Piece] {
        var pieces: [Piece] = []
        for span in sources {
            let spanEnd = span.startInMerged + span.duration
            let lo = max(start, span.startInMerged)
            let hi = min(end, spanEnd)
            guard hi - lo > 0.02 else { continue }
            let originalStart = lo - span.startInMerged
            let range = CMTimeRange(
                start: CMTime(seconds: originalStart, preferredTimescale: 600),
                duration: CMTime(seconds: hi - lo, preferredTimescale: 600))
            pieces.append(Piece(key: span.key, range: range))
        }
        return pieces
    }

    private static func makeInstruction(track: AVCompositionTrack, range: CMTimeRange, natural: CGSize,
                                        preferred: CGAffineTransform,
                                        cropScale: Double, cropOffsetX: Double, cropOffsetY: Double) -> AVMutableVideoCompositionInstruction {
        let inst = AVMutableVideoCompositionInstruction()
        inst.timeRange = range
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(ReframeTransform.fill(natural: natural, preferred: preferred, into: renderSize,
                                                 cropScale: cropScale, cropOffsetX: cropOffsetX, cropOffsetY: cropOffsetY),
                           at: range.start)
        inst.layerInstructions = [layer]
        return inst
    }
}
