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

    func makeUIView(context: Context) -> LoopingPlayerUIView {
        LoopingPlayerUIView(url: url, start: start, end: end)
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
    private var observer: Any?

    init(url: URL, start: Double, end: Double) {
        self.startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        self.endSeconds = end
        super.init(frame: .zero)

        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.actionAtItemEnd = .none
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        player.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)

        // Loop within [start, end].
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            if time.seconds >= self.endSeconds - 0.05 {
                self.player.seek(to: self.startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.player.play()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPlaying(_ playing: Bool) {
        if playing {
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
