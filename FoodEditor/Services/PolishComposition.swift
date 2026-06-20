import AVFoundation

/// Builds the Polish page's live preview from the 720p **proxy**: one video track stitched from the
/// edit's `RenderSlot`s (overlay B-roll covers the base where present, speed applied via
/// `scaleTimeRange`), plus a base + overlay **audio** track mixed by an `AVMutableAudioMix` so each
/// clip plays at its own volume (overlay defaults to muted). Mirrors `EditPlanAssembler` so the
/// preview matches the exported video.
enum PolishComposition {
    static func makeItem(proxyURL: URL,
                         slots: [RenderSlot],
                         baseAudio: [AudioPiece],
                         overlayAudio: [AudioPiece]) async -> AVPlayerItem? {
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

        // ── AUDIO (base + overlay tracks, volume via mix) ──
        var mixParams: [AVMutableAudioMixInputParameters] = []
        func addAudioTrack(_ pieces: [AudioPiece]) {
            guard let srcAudio, !pieces.isEmpty,
                  let aTrack = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            let sorted = pieces.sorted { $0.baseStart < $1.baseStart }
            var trackEnd = CMTime.zero
            for p in sorted {
                let at = CMTime(seconds: p.baseStart, preferredTimescale: 600)
                if CMTimeCompare(at, trackEnd) > 0 {
                    aTrack.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: at))
                }
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
        addAudioTrack(baseAudio)
        addAudioTrack(overlayAudio)

        let item = AVPlayerItem(asset: comp)
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = mixParams
            item.audioMix = mix
        }
        item.audioTimePitchAlgorithm = .spectral
        return item
    }
}
