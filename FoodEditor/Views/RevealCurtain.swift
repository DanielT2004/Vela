import SwiftUI
import UIKit

/// The celebratory "curtain" shown over the freshly-mounted Cut Card (`FirstCutView`) right after an
/// analysis lands: "Your first cut is ready", a fanned sneak-peek of the first moments, and a
/// continuously bouncing arrow inviting a swipe. Swiping up (1:1) lifts the whole curtain off-screen to
/// expose the pixel-complete map underneath (Spotify-Wrapped style), then calls `onReveal`. It does NOT
/// navigate — the map is already mounted beneath it, so there's no hand-off jank on the swipe.
struct RevealCurtain: View {
    @Environment(VideoSession.self) private var session
    /// Fired the instant the swipe commits, as the curtain BEGINS sliding off — so the map's entrance
    /// choreography plays underneath while the curtain lifts (the "unrolling" reveal).
    let onRevealStart: () -> Void
    /// Fired when the slide-off finishes — remove the (now off-screen) curtain from the hierarchy.
    let onRevealEnd: () -> Void

    @State private var appeared = false
    @State private var curtainY: CGFloat = 0
    @State private var dragging = false
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var screenH: CGFloat = 1000

    private var plan: EditPlan? { session.store?.plan }
    private var proxyURL: URL? { session.merged?.url }
    private let upThreshold: CGFloat = -110

    var body: some View {
        ZStack {
            Color.veCream
            RadialGradient(colors: [Color.veTerracotta.opacity(0.14), .clear],
                           center: .top, startRadius: 8, endRadius: 460)
            if let plan { content(plan) }
        }
        .ignoresSafeArea()
        .background(GeometryReader { g in Color.clear.onAppear { screenH = g.size.height } })
        .offset(y: curtainY)
        .gesture(swipe)
        .task { await loadThumbs() }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) { appeared = true }
        }
    }

    // MARK: - Content

    private func content(_ plan: EditPlan) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            ZStack {
                Circle().fill(Color.veTerracotta.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.veTerracotta)
            }
            .scaleEffect(appeared ? 1 : 0.5)
            .opacity(appeared ? 1 : 0)

            Text("Your first cut\nis ready")
                .font(VeFont.serif(34))
                .foregroundStyle(Color.veCharcoal)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .padding(.top, 18)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            teaser(plan)
                .padding(.top, 12)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 10)

            Spacer(minLength: 18)

            SneakPeekDeck(segments: teaserSegments(plan), thumbs: thumbs, appeared: appeared)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92)

            Spacer(minLength: 18)

            Button { revealNow() } label: {
                VStack(spacing: 6) {
                    BounceArrow()
                    Text("Swipe up to see your cut")
                        .font(VeFont.sans(13, weight: .semibold))
                        .foregroundStyle(Color.veNoteText)
                }
            }
            .buttonStyle(.plain)
            .opacity(appeared ? 1 : 0)
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Anticipation, not the full data: a couple of headline numbers + a "hook found" chip.
    private func teaser(_ plan: EditPlan) -> some View {
        let moments = plan.segments.count
        let secs = Int(plan.recommendedDuration.rounded())
        return VStack(spacing: 10) {
            (Text("\(moments) moments").foregroundStyle(Color.veTerracotta).fontWeight(.bold)
             + Text(" found · ~\(secs)s cut suggested").foregroundStyle(Color.veWarmGray))
                .font(VeFont.sans(14.5))
                .multilineTextAlignment(.center)

            if !plan.recommendedHook.trimmingCharacters(in: .whitespaces).isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 9))
                    Text("Your hook is picked").font(VeFont.sans(12, weight: .semibold))
                }
                .foregroundStyle(Color.veTerracotta)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.veTerracotta.opacity(0.1), in: Capsule())
            }
        }
    }

    // MARK: - Reveal / swipe

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard abs(v.translation.height) > abs(v.translation.width) else { return }
                dragging = true
                curtainY = min(0, v.translation.height)        // 1:1 upward follow
            }
            .onEnded { v in
                dragging = false
                let far = v.translation.height < upThreshold
                let flick = v.predictedEndTranslation.height < -350 && v.translation.height < -30
                if far || flick {
                    revealNow()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { curtainY = 0 }
                }
            }
    }

    /// Slide the whole curtain up off-screen; the map beneath animates in concurrently (onRevealStart),
    /// and the curtain is removed once it's fully gone (onRevealEnd).
    private func revealNow() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onRevealStart()
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            curtainY = -(screenH + 80)
        } completion: {
            onRevealEnd()
        }
    }

    // MARK: - Teaser data

    private func teaserSegments(_ plan: EditPlan) -> [Segment] {
        let order = plan.finalEditOrder.isEmpty ? plan.segments.map(\.id) : plan.finalEditOrder
        let byId = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = order.compactMap { byId[$0] }
        return Array((picked.isEmpty ? plan.segments : picked).prefix(3))
    }

    private func loadThumbs() async {
        guard let url = proxyURL, let plan else { return }
        // Sample at +0.3s to share cache buckets with FirstCutView's spine tiles (inPoint + 0.3).
        for seg in teaserSegments(plan) where thumbs[seg.id] == nil {
            if let img = await ThumbnailService.thumbnail(for: url, at: seg.startSeconds + 0.3) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }
}

// MARK: - Bouncing arrow (self-contained looping animation)

/// The up-chevron that bounces up/down forever to invite the swipe. Owns its own animation so it's
/// isolated from the curtain's drag re-evaluations.
private struct BounceArrow: View {
    @State private var up = false
    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(Color.veTerracotta)
            .offset(y: up ? -9 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { up = true }
            }
    }
}

// MARK: - Fanned sneak-peek deck (extracted so the curtain drag never re-bodies it)

/// A fanned deck of the first few moments peeking up from the bottom with a soft fade. Extracted into
/// its own `View` struct with stable inputs so that while the curtain is being dragged (only `curtainY`
/// changes), SwiftUI diffs this as unchanged and skips re-rendering the masked/shadowed tiles.
private struct SneakPeekDeck: View {
    let segments: [Segment]
    let thumbs: [Int: UIImage]
    let appeared: Bool

    private let angles: [Double] = [-9, 0, 9]
    private let offsets: [CGFloat] = [-78, 0, 78]

    var body: some View {
        ZStack {
            ForEach(Array(segments.enumerated()), id: \.element.id) { idx, seg in
                peekTile(seg)
                    .rotationEffect(.degrees(appeared ? angles[idx % 3] : 0))
                    .offset(x: appeared ? offsets[idx % 3] : 0, y: CGFloat(idx) * -4)
                    .zIndex(idx == 1 ? 3 : 1)
            }
        }
        .frame(height: 188)
        .mask(LinearGradient(colors: [.black, .black, .black.opacity(0.35)],
                             startPoint: .top, endPoint: .bottom))
    }

    private func peekTile(_ seg: Segment) -> some View {
        ZStack {
            if let img = thumbs[seg.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                FoodTile(tone: seg.sceneType.foodTone, cornerRadius: 16)
            }
            LinearGradient(colors: [.black.opacity(0.42), .clear], startPoint: .bottom, endPoint: .center)
        }
        .frame(width: 118, height: 178)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.6), lineWidth: 1))
        .shadow(color: Color.veCharcoal.opacity(0.18), radius: 12, y: 6)
    }
}
