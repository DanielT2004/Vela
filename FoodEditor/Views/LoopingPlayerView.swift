import SwiftUI
import AVFoundation

/// A controls-free inline video view that plays (and loops) a single `[start, end]` slice of a
/// video, aspect-filling its frame. Used for the auto-playing front card in triage (and reusable
/// for the timeline preview). `isPlaying` lets the parent pause it (e.g. while a sheet is open).
struct LoopingPlayerView: UIViewRepresentable {
    let url: URL
    let start: Double
    let end: Double
    var isPlaying: Bool
    /// Playback position (in source seconds), reported ~10×/s — drives the Sort card's footage-bar
    /// playhead. Optional so other call sites pay nothing.
    var onTime: ((Double) -> Void)? = nil

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(url: url, start: start, end: end, onTime: onTime)
    }

    func updateUIView(_ uiView: LoopingPlayerUIView, context: Context) {
        uiView.setPlaying(isPlaying)
    }

    static func dismantleUIView(_ uiView: LoopingPlayerUIView, coordinator: ()) {
        uiView.teardown()
    }
}

final class LoopingPlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    private let player = AVPlayer()
    private let startTime: CMTime
    private let endSeconds: Double
    private let onTime: ((Double) -> Void)?
    private var observer: Any?
    /// The parent's last `setPlaying` intent. LOAD-BEARING: the loop branch only replays while this is
    /// true, so a player the parent paused (e.g. under the tap-to-preview sheet, or on backgrounding)
    /// can never wake ITSELF back up. Without this guard the periodic observer's unconditional `play()`
    /// un-paused a deliberately-paused player — the latent defect behind the beta's "player broken"
    /// report (its known trigger, the Autoplay toggle, is gone; this closes the remaining doors).
    private var wantsPlay = false

    init(url: URL, start: Double, end: Double, onTime: ((Double) -> Void)? = nil) {
        self.startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        // Clamp the loop window: a degenerate [start,end] (≤0.25s, e.g. from a bad trim) would make the
        // loop point fire on every 0.1s tick AND every seek's time-jump → a main-queue seek/play storm.
        self.endSeconds = max(end, max(0, start) + 0.25)
        self.onTime = onTime
        super.init(frame: .zero)

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // Loop within [start, end]. 0.1s tick: fine enough for a smooth footage-bar playhead,
        // still trivial work (was 0.2s when it only drove the loop check).
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            if time.seconds >= self.endSeconds - 0.05 {
                self.player.seek(to: self.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                if self.wantsPlay { self.player.play() }   // never un-pause a paused player
                self.onTime?(self.startTime.seconds)
            } else {
                self.onTime?(time.seconds)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlaying(_ playing: Bool) {
        wantsPlay = playing
        if playing {
            // The Sort card's play path never armed the audio session (launch/other players did, but not
            // this one) — arm it here so sound plays on the silent switch and survives an interruption.
            AudioSession.configureForPlayback()
            if player.timeControlStatus != .playing { player.play() }
        } else {
            player.pause()
        }
    }

    func teardown() {
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}
