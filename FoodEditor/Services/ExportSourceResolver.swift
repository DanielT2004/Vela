import Foundation
import AVFoundation
import Photos

/// Decides which source clips the export renders from.
///
/// - **Fresh session:** the originals are still on disk as picker temp files — use them (full-res).
/// - **Resumed session:** try to re-resolve the FULL-RESOLUTION originals from the camera roll via the
///   saved PHAsset IDs (needs Photos access). If access is denied or any clip is missing (e.g. deleted
///   from the camera roll), fall back to exporting from the saved ~720p **proxy** so export still works.
enum ExportSourceResolver {
    struct Result {
        let sources: [EditPlanAssembler.AssetSpan]
        /// True when we couldn't get the originals and rendered from the proxy instead (~720p).
        let usedProxyFallback: Bool
    }

    static func resolve(session: VideoSession) async -> Result {
        // Fresh session — originals are on-disk temp files referenced by the merged source spans.
        guard let origin = session.originSources else {
            let spans = session.merged?.sourceSpans ?? []
            return Result(sources: spans.map(assetSpan(fromTempSpan:)), usedProxyFallback: false)
        }

        // Resumed session — attempt full-resolution re-resolution from the camera roll.
        if !origin.isEmpty, let fullRes = await resolveFullRes(origin) {
            Log.assembly("Resumed export: re-resolved \(fullRes.count) original(s) at full resolution.")
            return Result(sources: fullRes, usedProxyFallback: false)
        }

        Log.assembly("Resumed export: originals unavailable — rendering from the saved proxy (~720p).")
        return Result(sources: proxyFallback(session), usedProxyFallback: true)
    }

    // MARK: - Builders

    private static func assetSpan(fromTempSpan span: SourceSpan) -> EditPlanAssembler.AssetSpan {
        EditPlanAssembler.AssetSpan(
            key: span.url.path,
            asset: AVURLAsset(url: span.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]),
            startInMerged: span.startInMerged, duration: span.duration)
    }

    private static func proxyFallback(_ session: VideoSession) -> [EditPlanAssembler.AssetSpan] {
        guard let merged = session.merged else { return [] }
        // One identity span over the whole proxy: proxy time maps 1:1 to source time.
        return [EditPlanAssembler.AssetSpan(
            key: merged.url.path,
            asset: AVURLAsset(url: merged.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]),
            startInMerged: 0, duration: merged.metadata.duration)]
    }

    /// Returns full-res asset spans only if EVERY original re-resolves; otherwise nil → caller falls
    /// back to the proxy (mixing proxy + full-res sources would desync the timeline).
    private static func resolveFullRes(_ spans: [PersistedSpan]) async -> [EditPlanAssembler.AssetSpan]? {
        guard spans.allSatisfy({ $0.assetIdentifier != nil }) else { return nil }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            Log.assembly("Photos read access not granted (\(status.rawValue)).")
            return nil
        }

        var out: [EditPlanAssembler.AssetSpan] = []
        for span in spans {
            guard let id = span.assetIdentifier, let asset = await avAsset(localId: id) else { return nil }
            out.append(EditPlanAssembler.AssetSpan(key: id, asset: asset,
                                                   startInMerged: span.startInMerged, duration: span.duration))
        }
        return out
    }

    private static func avAsset(localId: String) async -> AVAsset? {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil)
        guard let phAsset = assets.firstObject else { return nil }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true        // allow download if the original lives in iCloud
        opts.deliveryMode = .highQualityFormat
        opts.version = .current
        return await withCheckedContinuation { (cont: CheckedContinuation<AVAsset?, Never>) in
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: opts) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }
    }
}
