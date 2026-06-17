import AVFoundation

/// Configures the app's audio session for video playback. Without this the default `.ambient`
/// category is silenced by the hardware ring/silent switch — so previews would play with no sound.
/// `.playback` plays audio regardless of the switch (standard for any video app).
enum AudioSession {
    static func configureForPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            Log.app("Audio session → .playback (sound plays even on silent mode).")
        } catch {
            Log.app("Audio session config failed: \(error.localizedDescription)")
        }
    }
}
