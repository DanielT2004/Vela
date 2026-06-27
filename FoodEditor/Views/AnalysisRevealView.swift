import SwiftUI
import UIKit

/// The reward moment after analysis finishes (in-session OR after reopening from a push): a warm,
/// celebratory "we finished your analysis" screen with a teaser stat line and a fanned sneak-peek of the
/// first few moments, then a **swipe up** (with a one-shot hint nudge) to reveal the full breakdown.
/// Reached from `ProcessingView` when `analysis.phase == .done`; leads to `.segments`.
struct AnalysisRevealView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    @State private var appeared = false        // entrance spring
    @State private var hintNudge = false       // one-shot "swipe up" teach animation
    @State private var dragY: CGFloat = 0       // live upward-drag follow
    @State private var thumbs: [Int: UIImage] = [:]

    private var plan: EditPlan? { session.store?.plan }
    private let swipeThreshold: CGFloat = -90

    var body: some View {
        ZStack {
            // Warm radial wash — food is the hero, chrome recedes.
            Color.veCream.ignoresSafeArea()
            RadialGradient(colors: [Color.veTerracotta.opacity(0.14), .clear],
                           center: .top, startRadius: 8, endRadius: 460)
                .ignoresSafeArea()

            if let plan {
                content(plan)
                    .offset(y: dragY)                       // follow the finger a touch while swiping up
                    .gesture(swipeUp)
            } else {
                ProgressView().tint(Color.veTerracotta)     // defensive — store not ready yet
            }
        }
        .task { await loadThumbs() }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appeared = true }
            // One-shot hint: nudge the swipe affordance up, then settle back to rest — teaches the gesture
            // without leaving anything off-center (rest state stays straight, per the motion playbook).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { hintNudge = true }
                try? await Task.sleep(nanoseconds: 480_000_000)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { hintNudge = false }
            }
        }
    }

    // MARK: - Content

    private func content(_ plan: EditPlan) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            // Celebration mark
            ZStack {
                Circle().fill(Color.veTerracotta.opacity(0.12)).frame(width: 92, height: 92)
                Image(systemName: "sparkles")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(Color.veTerracotta)
            }
            .scaleEffect(appeared ? 1 : 0.5)
            .opacity(appeared ? 1 : 0)

            Text("We finished your\nanalysis")
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

            sneakPeek(plan)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.92)

            Spacer(minLength: 18)

            swipeAffordance
                .padding(.bottom, 6)

            Button { goToResults() } label: {
                Text("See the breakdown")
                    .font(VeFont.sans(13, weight: .bold))
                    .foregroundStyle(Color.veWarmGray)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 22)
            .opacity(appeared ? 1 : 0)
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

    /// A fanned deck of the first few moments, peeking up from the bottom with a soft fade — a tease.
    private func sneakPeek(_ plan: EditPlan) -> some View {
        let picks = teaserSegments(plan)
        let angles: [Double] = [-9, 0, 9]
        let offsets: [CGFloat] = [-78, 0, 78]
        return ZStack {
            ForEach(Array(picks.enumerated()), id: \.element.id) { idx, seg in
                peekTile(seg)
                    .rotationEffect(.degrees(appeared ? angles[idx % 3] : 0))
                    .offset(x: appeared ? offsets[idx % 3] : 0, y: CGFloat(idx) * -4)
                    .zIndex(idx == 1 ? 3 : Double(1))
            }
        }
        .frame(height: 188)
        // Fade the bottom so the deck feels like it's still emerging — "more below."
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

    private var swipeAffordance: some View {
        VStack(spacing: 4) {
            Image(systemName: "chevron.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.veTerracotta)
            Text("Swipe up to see your results")
                .font(VeFont.sans(13, weight: .semibold))
                .foregroundStyle(Color.veNoteText)
        }
        .offset(y: hintNudge ? -8 : 0)               // one-shot teach nudge
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Swipe / navigation

    private var swipeUp: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard abs(v.translation.height) > abs(v.translation.width) else { return }
                dragY = min(0, v.translation.height) * 0.6      // resisted upward follow
            }
            .onEnded { v in
                if v.translation.height < swipeThreshold {
                    goToResults()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { dragY = 0 }
                }
            }
    }

    private func goToResults() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        router.go(.segments)
    }

    // MARK: - Teaser data

    private func teaserSegments(_ plan: EditPlan) -> [Segment] {
        let order = plan.finalEditOrder.isEmpty ? plan.segments.map(\.id) : plan.finalEditOrder
        let byId = Dictionary(plan.segments.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let picked = order.compactMap { byId[$0] }
        return Array((picked.isEmpty ? plan.segments : picked).prefix(3))
    }

    private func loadThumbs() async {
        guard let url = session.merged?.url, let plan else { return }
        for seg in teaserSegments(plan) where thumbs[seg.id] == nil {
            if let img = await ThumbnailService.thumbnail(for: url, at: seg.startSeconds + 0.2) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }
}
