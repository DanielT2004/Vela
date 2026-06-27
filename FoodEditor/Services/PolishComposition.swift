import AVFoundation

/// Builds the Polish page's live preview from the 720p **proxy**: one video track stitched from the
/// edit's `RenderSlot`s (overlay B-roll covers the base where present, speed applied via
/// `scaleTimeRange`), plus a base + overlay **audio** track mixed by an `AVMutableAudioMix` so each
/// clip plays at its own volume (overlay defaults to muted). Mirrors `EditPlanAssembler` so the
/// preview matches the exported video.
enum PolishComposition {
    /// A built preview item plus the handles needed to flip Original↔Cleaned **without rebuilding**:
    /// the two parallel base audio tracks (both present whenever a cleaned file exists, built from the
    /// same pieces so they're time-matched) and the unchanging overlay mix params. The toggle just swaps
    /// the item's `audioMix` (see `voiceAudioMix`).
    struct VoicePreview {
        let item: AVPlayerItem
        let baseOriginal: AVMutableCompositionTrack?   // always-original base voice
        let baseCleaned: AVMutableCompositionTrack?    // cleaned-where-covered base voice; nil if no cleaned file
        let basePieces: [AudioPiece]
        let overlayParams: [AVMutableAudioMixInputParameters]
    }

    /// Build the audio mix for a given toggle state: the active base track plays at the per-clip volumes,
    /// the other base track is muted; overlay params are reused unchanged. Assign this to
    /// `item.audioMix` (then a same-position seek to apply it live — see PolishView).
    static func voiceAudioMix(_ d: VoicePreview, useIsolated: Bool) -> AVMutableAudioMix {
        let sorted = d.basePieces.sorted { $0.baseStart < $1.baseStart }
        func params(_ track: AVMutableCompositionTrack, active: Bool) -> AVMutableAudioMixInputParameters {
            let p = AVMutableAudioMixInputParameters(track: track)
            p.audioTimePitchAlgorithm = .spectral
            var prev: Float = -1
            for piece in sorted {
                let vol: Float = active ? piece.volume : 0
                if vol != prev { p.setVolume(vol, at: CMTime(seconds: piece.baseStart, preferredTimescale: 600)); prev = vol }
            }
            if !active { p.setVolume(0, at: .zero) }   // ensure muted from t=0
            return p
        }
        let origActive = !useIsolated || d.baseCleaned == nil
        var inputs: [AVMutableAudioMixInputParameters] = []
        if let orig = d.baseOriginal { inputs.append(params(orig, active: origActive)) }
        if let cleaned = d.baseCleaned { inputs.append(params(cleaned, active: useIsolated)) }
        inputs.append(contentsOf: d.overlayParams)
        let mix = AVMutableAudioMix(); mix.inputParameters = inputs; return mix
    }

    static func makeItem(proxyURL: URL,
                         slots: [RenderSlot],
                         baseAudio: [AudioPiece],
                         overlayAudio: [AudioPiece],
                         isolated: [IsolatedAudioSpan] = [],
                         useIsolated: Bool = false) async -> VoicePreview? {
        guard !slots.isEmpty else { return nil }
        let asset = AVURLAsset(url: proxyURL)
        guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first
        let assetDuration = (try? await asset.load(.duration).seconds) ?? .greatestFiniteMagnitude

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }

        // ── VIDEO ──
        // Stitch the proxy slices into one track. The 9:16 reframe + per-clip crop are applied in the
        // preview UI (PlayerLayerView gravity .resizeAspectFill + a CALayer transform) — NOT via an
        // AVMutableVideoComposition here, which rendered black on device. Export still composites.
        var cursor = CMTime.zero
        for slot in slots {
            let dur = slot.duration
            guard dur > 0.02 else { continue }
            let srcLen = dur * slot.videoSpeed
            let vStart = max(0, slot.videoSourceStart)
            let vEnd = min(vStart + srcLen, assetDuration)
            let at = cursor
            if vEnd > vStart + 0.02 {
                let r = CMTimeRange(start: CMTime(seconds: vStart, preferredTimescale: 600),
                                    end: CMTime(seconds: vEnd, preferredTimescale: 600))
                try? vTrack.insertTimeRange(r, of: srcVideo, at: at)
                if slot.videoSpeed != 1 {
                    vTrack.scaleTimeRange(CMTimeRange(start: at, duration: r.duration),
                                          toDuration: CMTime(seconds: dur, preferredTimescale: 600))
                }
            }
            cursor = cursor + CMTime(seconds: dur, preferredTimescale: 600)
        }
        if let t = try? await srcVideo.load(.preferredTransform) { vTrack.preferredTransform = t }
        guard cursor > .zero else { return nil }

        // ── AUDIO ──
        // Cleaned-voice files loaded + cached once (Voice Isolation). Mirrors the exporter.
        // Retain the AVURLAsset (not just its track) — an orphaned track inserts SILENT. (Same reason
        // EditPlanAssembler's SourceInfo keeps its asset.) The cache is build-scoped, so assets stay
        // alive through every insertTimeRange call.
        var isoCache: [URL: (asset: AVURLAsset, track: AVAssetTrack, duration: Double)] = [:]
        func isolatedTrack(_ url: URL) async -> (asset: AVURLAsset, track: AVAssetTrack, duration: Double)? {
            if let c = isoCache[url] { return c }
            let a = AVURLAsset(url: url)
            guard let t = try? await a.loadTracks(withMediaType: .audio).first else { return nil }
            let d = (try? await a.load(.duration).seconds) ?? .greatestFiniteMagnitude
            let entry = (asset: a, track: t, duration: d); isoCache[url] = entry; return entry
        }

        /// Insert pieces into a fresh audio track. `useCleaned` → read from the cleaned file wherever a
        /// span fully covers the piece (else proxy — so partial "this clip" isolation works); `false` →
        /// always proxy. Same coverage test as EditPlanAssembler (lockstep). Returns the track, or nil.
        func buildAudioTrack(_ pieces: [AudioPiece], useCleaned: Bool) async -> AVMutableCompositionTrack? {
            guard !pieces.isEmpty,
                  let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
            let sorted = pieces.sorted { $0.baseStart < $1.baseStart }
            var trackEnd = CMTime.zero
            var cleanedCount = 0, fallbackCount = 0   // diagnostics (cleaned track only)
            for p in sorted {
                let at = CMTime(seconds: p.baseStart, preferredTimescale: 600)
                if CMTimeCompare(at, trackEnd) > 0 {
                    aTrack.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at))
                }
                var insertedCleaned = false
                if useCleaned {
                    let pStart = p.sourceStart, pEnd = p.sourceStart + p.sourceDuration
                    let coveringSpan = isolated.first { $0.startProxy <= pStart + 0.01 && $0.endProxy >= pEnd - 0.01 }
                    if let span = coveringSpan, let iso = await isolatedTrack(span.url) {
                        let aStart = max(0, p.sourceStart - span.startProxy)
                        let aEnd = min(aStart + p.sourceDuration, iso.duration)
                        if aEnd > aStart + 0.02 {
                            let r = CMTimeRange(start: CMTime(seconds: aStart, preferredTimescale: 600),
                                                end: CMTime(seconds: aEnd, preferredTimescale: 600))
                            do {
                                try aTrack.insertTimeRange(r, of: iso.track, at: at)
                                if p.speed != 1 {
                                    aTrack.scaleTimeRange(CMTimeRange(start: at, duration: r.duration),
                                                          toDuration: CMTime(seconds: p.timelineDuration, preferredTimescale: 600))
                                }
                                insertedCleaned = true; cleanedCount += 1
                            } catch { Log.audio("⚠️ cleaned insert failed @\(String(format: "%.1f", at.seconds))s: \(error.localizedDescription)") }
                        }
                    }
                    if !insertedCleaned { fallbackCount += 1 }
                }
                if !insertedCleaned, let srcAudio {   // original track, or cleaned-but-uncovered/failed piece
                    let aStart = max(0, p.sourceStart)
                    let aEnd = min(aStart + p.sourceDuration, assetDuration)
                    if aEnd > aStart + 0.02 {
                        let r = CMTimeRange(start: CMTime(seconds: aStart, preferredTimescale: 600),
                                            end: CMTime(seconds: aEnd, preferredTimescale: 600))
                        try? aTrack.insertTimeRange(r, of: srcAudio, at: at)
                        if p.speed != 1 {
                            aTrack.scaleTimeRange(CMTimeRange(start: at, duration: r.duration),
                                                  toDuration: CMTime(seconds: p.timelineDuration, preferredTimescale: 600))
                        }
                    }
                }
                trackEnd = CMTime(seconds: p.baseStart + p.timelineDuration, preferredTimescale: 600)
            }
            if useCleaned {
                Log.audio("cleaned track built: \(cleanedCount) cleaned / \(fallbackCount) fallback, dur=\(String(format: "%.1f", CMTimeGetSeconds(aTrack.timeRange.duration)))s.")
            }
            return aTrack
        }

        // Two parallel base voice tracks (cleaned built only when a cleaned file exists), plus overlay.
        let baseOriginal = await buildAudioTrack(baseAudio, useCleaned: false)
        let baseCleaned = isolated.isEmpty ? nil : await buildAudioTrack(baseAudio, useCleaned: true)

        var overlayParams: [AVMutableAudioMixInputParameters] = []
        if let overlayTrack = await buildAudioTrack(overlayAudio, useCleaned: false) {
            let p = AVMutableAudioMixInputParameters(track: overlayTrack)
            p.audioTimePitchAlgorithm = .spectral
            var prev: Float = -1
            for piece in overlayAudio.sorted(by: { $0.baseStart < $1.baseStart }) where piece.volume != prev {
                p.setVolume(piece.volume, at: CMTime(seconds: piece.baseStart, preferredTimescale: 600))
                prev = piece.volume
            }
            overlayParams.append(p)
        }

        let item = AVPlayerItem(asset: comp)
        let descriptor = VoicePreview(item: item, baseOriginal: baseOriginal, baseCleaned: baseCleaned,
                                      basePieces: baseAudio, overlayParams: overlayParams)
        item.audioMix = voiceAudioMix(descriptor, useIsolated: useIsolated)
        item.audioTimePitchAlgorithm = .spectral
        return descriptor
    }
}
