import SwiftUI
import UIKit

/// M7 — the Hook Spotlight (screen S6). The first 1–2 seconds decide whether the video gets watched,
/// so we surface the AI's strongest openers: the top-3 segments by `hook_score` as large cards. Tap
/// one to crown it the hook (it moves to the front of the cut). The current hook glows terracotta.
struct HookSpotlightView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    @State private var thumbs: [Int: UIImage] = [:]

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// The three best openers, by hook score (ties broken by earliest moment).
    private var candidates: [Segment] {
        (store?.plan.segments ?? [])
            .sorted { ($0.hookScore, $1.startSeconds) > ($1.hookScore, $0.startSeconds) }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(candidates) { seg in
                        candidateCard(seg, rank: (candidates.firstIndex(of: seg) ?? 0) + 1)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.veCream.ignoresSafeArea())
        .task { await loadThumbnails() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                BackChevronButton { router.back() }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Pick your hook")
                    .font(VeFont.serif(26))
                    .foregroundStyle(Color.veCharcoal)
                Text("The first moment that stops the scroll. We ranked your strongest openers.")
                    .font(VeFont.sans(13.5))
                    .foregroundStyle(Color.veWarmGray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 14)
    }

    private func candidateCard(_ seg: Segment, rank: Int) -> some View {
        let isHook = store?.hookId == seg.id

        return Button {
            store?.setHook(seg.id)
            Log.app("🎞️ Hook set → segment \(seg.id) (\(seg.sceneType.label), score \(Int(seg.hookScore))). \(store?.vibeText ?? "")")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            router.back()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    thumb(seg)
                    HStack(spacing: 6) {
                        rankBadge(rank)
                        Spacer()
                        if isHook {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                                Text("CURRENT HOOK").font(VeFont.sans(10, weight: .bold)).tracking(0.5)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.veTerracotta, in: Capsule())
                        }
                    }
                    .padding(12)
                }
                .frame(height: 168)
                .frame(maxWidth: .infinity)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                                  bottomTrailingRadius: 0, topTrailingRadius: 18,
                                                  style: .continuous))

                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        SceneChip(text: seg.sceneType.label)
                        Spacer()
                        hookScoreMeter(seg.hookScore)
                    }
                    if !seg.description.isEmpty {
                        Text(seg.description)
                            .font(VeFont.sans(14, weight: .semibold))
                            .foregroundStyle(Color.veCharcoal)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(isHook ? "This opens your video" : "Tap to open with this")
                        .font(VeFont.sans(12.5, weight: .bold))
                        .foregroundStyle(isHook ? Color.veSage : Color.veTerracotta)
                }
                .padding(14)
            }
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isHook ? Color.veTerracotta : Color.clear, lineWidth: 2)
            )
            .shadow(color: isHook ? Color.veTerracotta.opacity(0.28) : Color.veCharcoal.opacity(0.07),
                    radius: isHook ? 16 : 7, y: isHook ? 8 : 3)
        }
        .buttonStyle(.plain)
    }

    private func thumb(_ seg: Segment) -> some View {
        ZStack {
            if let img = thumbs[seg.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                FoodTile(tone: seg.sceneType.foodTone, cornerRadius: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func rankBadge(_ rank: Int) -> some View {
        Text("#\(rank)")
            .font(VeFont.serif(15))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.42), in: Circle())
    }

    /// A small 10-segment meter visualizing hook_score / 10.
    private func hookScoreMeter(_ score: Double) -> some View {
        let filled = Int(score.rounded())
        return HStack(spacing: 5) {
            Text("HOOK")
                .font(VeFont.sans(9.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color.veFaintGray)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Color.veTerracotta : Color.veSurface)
                        .frame(width: 5, height: 9)
                }
            }
            Text("\(filled)/10")
                .font(VeFont.sans(11, weight: .bold))
                .foregroundStyle(Color.veWarmGray)
        }
    }

    private func loadThumbnails() async {
        guard let proxyURL, thumbs.isEmpty else { return }
        for seg in candidates {
            let t = seg.startSeconds + min(0.4, max(0, (seg.endSeconds - seg.startSeconds) / 2))
            if let img = await ThumbnailService.thumbnail(for: proxyURL, at: t) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }
}
