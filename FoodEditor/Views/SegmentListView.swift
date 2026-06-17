import SwiftUI
import AVKit

/// M5 — read-only "Your breakdown". Faithfully visualizes the parsed Edit Plan: one card per
/// analyzed segment (in timeline order) with a real thumbnail from the merged proxy at that moment,
/// scene type, duration, hook score, edit note, and voiceover/cut/review tags. Tapping a card plays
/// just that slice. No editing yet — that's M6.
struct SegmentListView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    @State private var thumbs: [Int: UIImage] = [:]
    @State private var previewSegment: Segment?

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// Segments in chronological (timeline) order.
    private var segments: [Segment] {
        (store?.plan.segments ?? []).sorted { $0.startSeconds < $1.startSeconds }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if segments.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(segments) { seg in
                            SegmentCard(
                                segment: seg,
                                isHook: store?.hookId == seg.id,
                                thumbnail: thumbs[seg.id]
                            ) { previewSegment = seg }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    .padding(.bottom, 120)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.veCream.ignoresSafeArea())
        .overlay(alignment: .bottom) { bottomBar }
        .task { await loadThumbnails() }
        .sheet(item: $previewSegment) { seg in
            if let proxyURL {
                SlicePlayerSheet(url: proxyURL,
                                 start: seg.startSeconds,
                                 end: seg.trimToSeconds ?? seg.endSeconds,
                                 caption: seg.description)
            }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            BackChevronButton { router.back() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Your breakdown")
                    .font(VeFont.serif(22))
                    .foregroundStyle(Color.veCharcoal)
                Text("\(segments.count) moments · tap any to preview")
                    .font(VeFont.sans(12.5))
                    .foregroundStyle(Color.veWarmGray)
            }
            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.top, 60)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No segments to show")
                .font(VeFont.serif(20)).foregroundStyle(Color.veCharcoal)
            Text("The analysis didn't return any segments.")
                .font(VeFont.sans(13)).foregroundStyle(Color.veWarmGray)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var bottomBar: some View {
        VStack {
            PrimaryActionButton(title: "Start editing") { router.go(.triage) }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 28)
        .background(
            LinearGradient(colors: [Color.veCream.opacity(0), Color.veCream],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
    }

    // MARK: thumbnails

    private func loadThumbnails() async {
        guard let proxyURL, thumbs.isEmpty else { return }
        for seg in segments {
            // Sample a touch into the segment so we don't catch a cut frame at the boundary.
            let t = seg.startSeconds + min(0.4, max(0, (seg.endSeconds - seg.startSeconds) / 2))
            if let img = await ThumbnailService.thumbnail(for: proxyURL, at: t) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }
}

// MARK: - Segment card

private struct SegmentCard: View {
    let segment: Segment
    let isHook: Bool
    let thumbnail: UIImage?
    let onTap: () -> Void

    private var durationText: String {
        let end = segment.trimToSeconds ?? segment.endSeconds
        return "\(Int((end - segment.startSeconds).rounded()))s"
    }
    private var rangeText: String {
        "\(timecode(segment.startSeconds))–\(timecode(segment.endSeconds))"
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                thumb
                VStack(alignment: .leading, spacing: 7) {
                    tagRow
                    if !segment.description.isEmpty {
                        Text(segment.description)
                            .font(VeFont.sans(13.5, weight: .semibold))
                            .foregroundStyle(Color.veCharcoal)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Text("\(rangeText) · \(durationText) · hook \(Int(segment.hookScore))/10")
                        .font(VeFont.sans(11.5))
                        .foregroundStyle(Color.veWarmGray)
                    if !segment.editNote.isEmpty {
                        ReasonNote(text: segment.editNote)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isHook ? Color.veTerracotta.opacity(0.5) : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: Color.veCharcoal.opacity(0.05), radius: 6, y: 2)
            .opacity(segment.keep ? 1 : 0.62)
        }
        .buttonStyle(.plain)
    }

    private var thumb: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                FoodTile(tone: segment.sceneType.foodTone, cornerRadius: 12)
                ProgressView().tint(.white)
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
        }
        .frame(width: 62, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            if isHook {
                badge("★ HOOK", fg: .white, bg: Color.veTerracotta)
            }
            SceneChip(text: segment.sceneType.label)
            if segment.voiceoverCandidate {
                badge("VO", fg: Color.veTerracotta, bg: Color.veTerracotta.opacity(0.12))
            }
            if !segment.keep {
                badge("CUT", fg: Color.veWarmGray, bg: Color.veSurface)
            }
            if segment.isLowConfidence {
                badge("⚠ review", fg: Color(hex: 0x9A7350), bg: Color(hex: 0x9A7350).opacity(0.12))
            }
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(VeFont.sans(10.5, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg, in: Capsule())
    }
}

private func timecode(_ seconds: Double) -> String {
    let t = Int(seconds.rounded())
    return String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: - Slice player

/// Plays (and gently loops) a single [start, end] slice of the merged proxy.
struct SlicePlayerSheet: View {
    let url: URL
    let start: Double
    let end: Double
    let caption: String

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var observer: Any?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.veCharcoal.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()

            VStack {
                Spacer()
                if !caption.isEmpty {
                    Text(caption)
                        .font(VeFont.serif(16, italic: true))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.black.opacity(0.4), in: Capsule())
                        .padding(.bottom, 40)
                }
            }

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.top, 16).padding(.trailing, 16)
        }
        .onAppear(perform: start_)
        .onDisappear {
            if let observer { player?.removeTimeObserver(observer) }
            player?.pause()
        }
    }

    private func start_() {
        AudioSession.configureForPlayback()   // ensure sound plays even on silent mode
        let p = AVPlayer(url: url)
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        p.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
        p.play()
        // Loop the slice: when we pass the end, jump back to the start.
        observer = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { time in
            if time.seconds >= end - 0.05 {
                p.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                p.play()
            }
        }
        player = p
    }
}
