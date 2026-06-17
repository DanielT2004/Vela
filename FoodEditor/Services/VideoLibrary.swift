import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Video metadata

/// Lightweight stats about a video file, read with AVFoundation.
struct VideoMetadata: Equatable {
    let duration: Double      // seconds
    let width: Int            // display width (orientation-corrected)
    let height: Int           // display height (orientation-corrected)
    let fileSizeBytes: Int64

    var resolutionText: String { "\(width)×\(height)" }
    var durationText: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
    /// TikTok wants vertical 9:16 — flag when the source isn't already portrait.
    var isPortrait: Bool { height >= width }
}

/// Reads metadata from a local video file using modern async AVFoundation loading.
enum VideoInspector {
    static func metadata(for url: URL) async -> VideoMetadata? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = CMTimeGetSeconds(try await asset.load(.duration))

            var w = 0, h = 0
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let resolved = size.applying(transform)
                w = Int(abs(resolved.width).rounded())
                h = Int(abs(resolved.height).rounded())
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

            return VideoMetadata(duration: duration, width: w, height: h, fileSizeBytes: fileSize)
        } catch {
            Log.video("Failed to read metadata: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - PHPicker wrapper

/// One newly-picked clip, copied to a temp file we own, tagged with its photo-library identifier
/// (when known) so we can dedup against the existing selection.
struct PickedClip {
    let assetIdentifier: String?
    let url: URL
}

/// A SwiftUI wrapper around `PHPickerViewController` (videos only, **multi-select, ordered**). The
/// picker is **preselected** with the clips already in the session, so re-opening it ("Add more")
/// shows them as checked. Only genuinely-new selections are copied out and handed back — duplicates
/// are skipped. PHPicker needs no photo-library permission prompt.
struct VideoPicker: UIViewControllerRepresentable {
    /// Asset identifiers already in the session — shown as preselected so they aren't re-added.
    let preselectedIdentifiers: [String]
    /// Called with the newly-added clips (already deduped against the preselection), in pick order.
    let onPicked: ([PickedClip]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        // A photo-library-backed config is required for asset identifiers, ordered selection, and
        // preselection — none of which prompt for library access (the picker stays out-of-process).
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 0            // 0 = unlimited multi-select
        config.selection = .ordered          // results follow tap order; shows order numbers
        config.preferredAssetRepresentationMode = .current
        config.preselectedAssetIdentifiers = preselectedIdentifiers
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: VideoPicker
        init(_ parent: VideoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Drop anything already in the session — only ingest new selections. (This also makes
            // Cancel a safe no-op, since a cancel returns the unchanged preselected set.)
            let preselected = Set(parent.preselectedIdentifiers)
            let newResults = results.filter { result in
                guard let id = result.assetIdentifier else { return true } // no id → treat as new
                return !preselected.contains(id)
            }
            Log.video("Picker closed: \(results.count) selected, \(newResults.count) new to ingest.")

            guard !newResults.isEmpty else {
                DispatchQueue.main.async { self.parent.onPicked([]) }
                return
            }

            let movieType = UTType.movie.identifier
            let group = DispatchGroup()
            let lock = NSLock()
            var byIndex: [Int: PickedClip] = [:]   // preserve pick order

            for (index, result) in newResults.enumerated() {
                let provider = result.itemProvider
                let assetID = result.assetIdentifier
                guard provider.hasItemConformingToTypeIdentifier(movieType) else {
                    Log.video("New item \(index) is not a movie — skipping.")
                    continue
                }
                group.enter()
                provider.loadFileRepresentation(forTypeIdentifier: movieType) { url, error in
                    defer { group.leave() }
                    if let error {
                        Log.video("Item \(index) load error: \(error.localizedDescription)")
                        return
                    }
                    guard let url else {
                        Log.video("Item \(index) returned no URL.")
                        return
                    }
                    // The provided URL is deleted once this closure returns — copy it first.
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let dest = FileManager.default.temporaryDirectory
                        .appendingPathComponent("vela-source-\(UUID().uuidString)")
                        .appendingPathExtension(ext)
                    do {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: url, to: dest)
                        lock.lock(); byIndex[index] = PickedClip(assetIdentifier: assetID, url: dest); lock.unlock()
                        Log.video("Copied new item \(index) → \(dest.lastPathComponent)")
                    } catch {
                        Log.video("Item \(index) copy failed: \(error.localizedDescription)")
                    }
                }
            }

            group.notify(queue: .main) {
                let ordered = (0..<newResults.count).compactMap { byIndex[$0] }
                Log.video("Handing back \(ordered.count) new clip(s).")
                self.parent.onPicked(ordered)
            }
        }
    }
}
