import Photos

enum PhotoSaveError: LocalizedError {
    case denied
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .denied:          return "Vela needs permission to add the video to your camera roll (Settings → Photos)."
        case .failed(let m):   return "Couldn't save to Photos: \(m)"
        }
    }
}

/// Saves a finished video file to the user's camera roll (add-only permission).
enum PhotoLibrary {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            Log.assembly("🔔 Photos add permission not granted (\(status.rawValue)).")
            throw PhotoSaveError.denied
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, error in
                if ok {
                    Log.assembly("✅ Saved final cut to camera roll.")
                    cont.resume()
                } else {
                    cont.resume(throwing: PhotoSaveError.failed(error?.localizedDescription ?? "unknown error"))
                }
            }
        }
    }
}
