import Foundation
import UIKit
import Observation

/// One selected source clip from the camera roll (copied to a temp file we own). Metadata and a
/// first-frame thumbnail load asynchronously after selection.
struct SourceClip: Identifiable {
    let id = UUID()
    let url: URL
    /// The photo-library local identifier (when available) — used to preselect/dedup in "Add more".
    var assetIdentifier: String? = nil
    var metadata: VideoMetadata? = nil
    var thumbnail: UIImage? = nil
}

/// Holds the state for one editing session as it flows through the pipeline. Creators can select
/// MULTIPLE clips (e.g. several recordings to stitch); they're concatenated in order downstream
/// (M2) so everything after still operates on a single video timeline.
@Observable
final class VideoSession {
    /// The selected source clips, in the order they'll be stitched.
    var clips: [SourceClip] = []

    /// The clips concatenated + compressed into one 720p file (M2) — the video sent to Gemini.
    var merged: ProcessedVideo?

    /// The parsed analysis result + editable state (M4) — the single source of truth for editing.
    var store: EditPlanStore?

    var count: Int { clips.count }
    var isEmpty: Bool { clips.isEmpty }

    /// Photo-library identifiers of the current selection — fed back to the picker so already-added
    /// clips show as selected ("Add more" won't create duplicates).
    var selectedAssetIdentifiers: [String] { clips.compactMap { $0.assetIdentifier } }

    /// Combined duration of all clips with known metadata (seconds).
    var totalDuration: Double { clips.reduce(0) { $0 + ($1.metadata?.duration ?? 0) } }

    var totalDurationText: String {
        let t = Int(totalDuration.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Combined file size of all clips with known metadata.
    var totalSizeText: String {
        let bytes = clips.reduce(Int64(0)) { $0 + ($1.metadata?.fileSizeBytes ?? 0) }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: mutations

    func add(_ clip: SourceClip) { clips.append(clip) }

    func remove(atOffsets offsets: IndexSet) { clips.remove(atOffsets: offsets) }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        clips.move(fromOffsets: source, toOffset: destination)
    }

    func updateDetails(id: UUID, metadata: VideoMetadata?, thumbnail: UIImage?) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        if let metadata { clips[idx].metadata = metadata }
        if let thumbnail { clips[idx].thumbnail = thumbnail }
    }

    func reset() { clips.removeAll() }
}
