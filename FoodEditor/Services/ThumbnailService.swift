import AVFoundation
import UIKit

/// Generates still frames from a video for thumbnails (clip rows in M1, segment cards in M5).
enum ThumbnailService {
    /// A thumbnail from `seconds` into the clip (default: the very start).
    static func thumbnail(for url: URL, at seconds: Double = 0.1, maxSize: CGFloat = 400) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // respect orientation
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            let result = try await generator.image(at: time)
            return UIImage(cgImage: result.image)
        } catch {
            Log.video("Thumbnail failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }
}
