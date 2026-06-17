import SwiftUI
import UIKit

private enum TriageAction { case keep, cut, hook }

/// The AI's single recommendation for a segment, surfaced on each Triage card so the creator can
/// decide fast — while keeping the final say. Derived purely from fields Gemini already returns.
private enum AIVerdict {
    case cut, unsure, voiceover, strongKeep, keeper

    init(_ seg: Segment) {
        if !seg.keep { self = .cut }
        else if seg.isLowConfidence { self = .unsure }
        else if seg.voiceoverCandidate { self = .voiceover }
        else if seg.hookScore >= 7.5 { self = .strongKeep }
        else { self = .keeper }
    }

    var label: String {
        switch self {
        case .cut:        return "Suggested cut"
        case .unsure:     return "Your call"
        case .voiceover:  return "Good for voiceover"
        case .strongKeep: return "Strong keep"
        case .keeper:     return "Keeper"
        }
    }

    var icon: String {
        switch self {
        case .cut:        return "scissors"
        case .unsure:     return "questionmark.circle.fill"
        case .voiceover:  return "mic.fill"
        case .strongKeep: return "star.fill"
        case .keeper:     return "checkmark"
        }
    }

    var tone: Color {
        switch self {
        case .cut, .voiceover:     return .veTerracotta
        case .unsure:              return Color(hex: 0x9A7350)   // ochre — matches the "review" badge
        case .strongKeep, .keeper: return .veSage
        }
    }

    /// Resting lean for the front card: -1 = cut (left), +1 = keep (right), 0 = neutral.
    var lean: CGFloat {
        switch self {
        case .cut:                            return -1
        case .unsure:                         return 0
        case .voiceover, .strongKeep, .keeper: return 1
        }
    }

    /// The "why" line, contextual to the verdict (so the user understands before overriding).
    func reason(_ seg: Segment) -> String {
        switch self {
        case .cut:
            return seg.editNote.isEmpty ? "Lower-impact than your other clips." : seg.editNote
        case .unsure:
            return seg.editNote.isEmpty ? "We weren't sure on this one — you decide." : seg.editNote
        case .voiceover:
            if let r = seg.voiceoverReason, !r.isEmpty { return r }
            return seg.editNote.isEmpty ? "Could play under a voiceover." : seg.editNote
        case .strongKeep, .keeper:
            return seg.editNote
        }
    }
}

/// M6 — Layer 1 Triage (the Swipe Deck). The signature interaction: review the AI's segments as a
/// stack of cards. Swipe right = keep, left = cut (into the Cut Tray), up = make it the hook.
/// The front card auto-plays its slice (with sound) so you watch before deciding; an Autoplay toggle
/// turns that off. Each action gives visual + haptic feedback and mutates the shared `EditPlanStore`.
struct TriageView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    @State private var triageIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var showCutTray = false
    @State private var previewSegment: Segment?
    @State private var autoPlay = true
    @State private var flash: TriageAction?

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    private var queue: [Segment] {
        (store?.plan.segments ?? []).sorted { $0.startSeconds < $1.startSeconds }
    }
    private var isDone: Bool { triageIndex >= queue.count }
    private var currentSegment: Segment? { isDone ? nil : queue[triageIndex] }

    /// Whether the inline front-card player should be running (paused while a sheet covers it).
    private var playerActive: Bool { previewSegment == nil && !showCutTray }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                progressHeader
                if !isDone { acceptPicksBanner }
                deck
                actionButtons
                bottomRow
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if showCutTray { cutTraySheet }
        }
        .background(Color.veCream.ignoresSafeArea())
        .task { await loadThumbnails() }
        .sheet(item: $previewSegment) { seg in
            if let proxyURL {
                SlicePlayerSheet(url: proxyURL, start: seg.startSeconds,
                                 end: seg.trimToSeconds ?? seg.endSeconds, caption: seg.description)
            }
        }
    }

    // MARK: top bar

    private var topBar: some View {
        HStack {
            Button("Cancel") { router.back() }
                .font(VeFont.sans(13, weight: .semibold))
                .foregroundStyle(Color.veWarmGray)
            Spacer()
            VibeMeterPill(text: store?.vibeText ?? "")
            Spacer()
            Button("Done") { router.go(.export) }
                .font(VeFont.sans(13, weight: .bold))
                .foregroundStyle(Color.veTerracotta)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var progressHeader: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(isDone ? "All sorted" : "Reviewing · \(min(triageIndex + 1, queue.count)) of \(queue.count)")
                    .font(VeFont.sans(12.5, weight: .semibold))
                    .foregroundStyle(Color.veWarmGray)
                if !isDone {
                    Text("Swipe the card, or tap a button below")
                        .font(VeFont.sans(11))
                        .foregroundStyle(Color.veFaintGray)
                }
            }
            HStack {
                Spacer()
                autoPlayToggle
            }
            .padding(.trailing, 22)
        }
        .padding(.bottom, 6)
    }

    private var autoPlayToggle: some View {
        Button { withAnimation { autoPlay.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: autoPlay ? "play.circle.fill" : "pause.circle")
                    .font(.system(size: 13, weight: .bold))
                Text("Autoplay")
                    .font(VeFont.sans(12, weight: .bold))
            }
            .foregroundStyle(autoPlay ? Color.veSage : Color.veWarmGray)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(autoPlay ? Color.veSage.opacity(0.12) : Color.veSurface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The "do the thinking for me" shortcut: apply every AI pick and jump to the timeline.
    private var acceptPicksBanner: some View {
        Button {
            store?.applyAISuggestions()
            Log.app("✨ Accepted all AI suggestions. \(store?.vibeText ?? "")")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            router.go(.timeline)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .bold))
                Text("Accept Vela's picks").font(VeFont.sans(13, weight: .bold))
                Text("· fine-tune later").font(VeFont.sans(12)).foregroundStyle(Color.veNoteText)
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Color.veTerracotta)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.veTerracotta.opacity(0.08), in: Capsule())
            .overlay(Capsule().stroke(Color.veTerracotta.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: deck

    private var deck: some View {
        GeometryReader { geo in
            // Every card gets the SAME explicit height, so the stacked cards behind the front one
            // peek by a consistent few points instead of poking out unevenly (the M7.1 regression).
            let cardHeight = max(260, geo.size.height - 18)
            ZStack {
                if isDone {
                    doneCard
                } else {
                    ForEach(visibleIndices.reversed(), id: \.self) { idx in
                        let seg = queue[idx]
                        let depth = idx - triageIndex
                        TriageCardView(segment: seg,
                                       thumbnail: thumbs[seg.id],
                                       isHook: store?.hookId == seg.id,
                                       isFront: depth == 0,
                                       autoPlay: autoPlay,
                                       playerActive: playerActive,
                                       proxyURL: proxyURL,
                                       dragOffset: depth == 0 ? dragOffset : .zero,
                                       onTapPreview: { previewSegment = seg })
                            .frame(width: geo.size.width, height: cardHeight)
                            .scaleEffect(1 - CGFloat(depth) * 0.03)
                            .offset(y: CGFloat(depth) * 12)
                            .zIndex(Double(queue.count - idx))
                            .allowsHitTesting(depth == 0)
                            .gesture(dragGesture(seg))   // only the front card hit-tests (above)
                    }
                }
                if let flash { flashView(flash).zIndex(999) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, 26)
        .padding(.top, 6)
    }

    private var visibleIndices: [Int] {
        Array(triageIndex ..< min(triageIndex + 3, queue.count))
    }

    private func flashView(_ action: TriageAction) -> some View {
        let (icon, color): (String, Color) = {
            switch action {
            case .keep: return ("checkmark", Color.veSage)
            case .cut:  return ("xmark", Color.veTerracotta)
            case .hook: return ("star.fill", Color.veCharcoal)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 92, height: 92)
            .background(color, in: Circle())
            .shadow(color: color.opacity(0.4), radius: 16, y: 6)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
    }

    private var doneCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.veSage).frame(width: 64, height: 64)
                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            Text("All sorted").font(VeFont.serif(25)).foregroundStyle(Color.veCharcoal)
            Text("\(store?.vibeText ?? ""). Polish the shape, or export now.")
                .font(VeFont.sans(13.5)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: action buttons

    private var actionButtons: some View {
        HStack(alignment: .top, spacing: 22) {
            circleButton(systemName: "xmark", label: "Cut", fg: Color.veTerracotta,
                         bg: .white, border: Color.veTerracotta.opacity(0.4), size: 56) {
                if let s = currentSegment { performSwipe(.cut, s) }
            }
            circleButton(systemName: "arrow.up", label: "Hook", fg: .white,
                         bg: Color.veCharcoal, border: .clear, size: 48) {
                if let s = currentSegment { performSwipe(.hook, s) }
            }
            .padding(.top, 4)
            circleButton(systemName: "checkmark", label: "Keep", fg: .white,
                         bg: Color.veSage, border: .clear, size: 56) {
                if let s = currentSegment { performSwipe(.keep, s) }
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
        .opacity(isDone ? 0.35 : 1)
        .disabled(isDone)
    }

    private func circleButton(systemName: String, label: String, fg: Color, bg: Color,
                              border: Color, size: CGFloat, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(fg)
                    .frame(width: size, height: size)
                    .background(bg, in: Circle())
                    .overlay(Circle().stroke(border, lineWidth: 1.5))
                    .shadow(color: Color.veCharcoal.opacity(0.12), radius: 6, y: 3)
            }
            .buttonStyle(.plain)
            Text(label).font(VeFont.sans(11, weight: .bold)).foregroundStyle(fg == .white ? bg : fg)
        }
    }

    // MARK: bottom row

    private var bottomRow: some View {
        HStack(spacing: 10) {
            Button { withAnimation { showCutTray = true } } label: {
                HStack(spacing: 9) {
                    Image(systemName: "tray")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.veWarmGray)
                    Text("Cut Tray").font(VeFont.sans(13, weight: .semibold)).foregroundStyle(Color.veNoteText)
                    Spacer()
                    Text("\(store?.cutTray.count ?? 0)")
                        .font(VeFont.sans(12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 20)
                        .background(Color.veTerracotta, in: Capsule())
                }
                .padding(.horizontal, 15).padding(.vertical, 10)
                .background(Color.veSurface, in: Capsule())
            }
            .buttonStyle(.plain)

            Button { router.go(.timeline) } label: {
                Text("Fine-tune →")
                    .font(VeFont.sans(13.5, weight: .bold)).foregroundStyle(Color.veCream)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Color.veCharcoal, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: cut tray sheet

    private var cutTraySheet: some View {
        ZStack(alignment: .bottom) {
            Color.veCharcoal.opacity(0.4).ignoresSafeArea()
                .onTapGesture { withAnimation { showCutTray = false } }
            VStack(spacing: 0) {
                Capsule().fill(Color(hex: 0xD8D0C2)).frame(width: 40, height: 4).padding(.top, 14).padding(.bottom, 16)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cut Tray").font(VeFont.serif(21)).foregroundStyle(Color.veCharcoal)
                        Text("Nothing's deleted — tap to put it back.")
                            .font(VeFont.sans(12.5)).foregroundStyle(Color.veWarmGray)
                    }
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 10) {
                        let cut = store?.cutTray ?? []
                        if cut.isEmpty {
                            Text("No clips cut yet.")
                                .font(VeFont.sans(13)).foregroundStyle(Color.veFaintGray)
                                .padding(.vertical, 30)
                        }
                        ForEach(cut, id: \.self) { id in
                            if let seg = store?.segment(id) { cutTrayRow(seg) }
                        }
                    }
                    .padding(.horizontal, 22).padding(.bottom, 30)
                }
                .frame(maxHeight: 360)
            }
            .frame(maxWidth: .infinity)
            .background(Color.veCream)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: 28,
                                              style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.2), radius: 20, y: -6)
            .transition(.move(edge: .bottom))
        }
        .zIndex(200)
    }

    private func cutTrayRow(_ seg: Segment) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = thumbs[seg.id] {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    FoodTile(tone: seg.sceneType.foodTone, cornerRadius: 10)
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(seg.description.isEmpty ? seg.sceneType.label : seg.description)
                    .font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                Text("\(seg.sceneType.label) · \(Int((seg.endSeconds - seg.startSeconds).rounded()))s")
                    .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
            }
            Spacer(minLength: 0)
            Button { store?.restore(seg.id) } label: {
                Text("Restore")
                    .font(VeFont.sans(12.5, weight: .bold)).foregroundStyle(Color.veSage)
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .background(Color.veSage.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 4, y: 1)
    }

    // MARK: gestures + commit

    private func dragGesture(_ seg: Segment) -> some Gesture {
        DragGesture()
            .onChanged { dragOffset = $0.translation }
            .onEnded { v in
                let dx = v.translation.width, dy = v.translation.height
                if dy < -110 && abs(dy) > abs(dx) { performSwipe(.hook, seg) }
                else if dx > 95 { performSwipe(.keep, seg) }
                else if dx < -95 { performSwipe(.cut, seg) }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragOffset = .zero } }
            }
    }

    private func performSwipe(_ action: TriageAction, _ seg: Segment) {
        haptic(for: action)
        withAnimation(.snappy(duration: 0.2)) { flash = action }
        withAnimation(.easeIn(duration: 0.26)) {
            switch action {
            case .keep: dragOffset = CGSize(width: 700, height: 60)
            case .cut:  dragOffset = CGSize(width: -700, height: 60)
            case .hook: dragOffset = CGSize(width: 0, height: -900)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            switch action {
            case .keep: store?.keep(seg.id)
            case .cut:  store?.cut(seg.id)
            case .hook: store?.setHook(seg.id)
            }
            Log.app("Triage \(action) → segment \(seg.id) (\(seg.sceneType.label)). \(store?.vibeText ?? "")")
            triageIndex += 1
            dragOffset = .zero
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            withAnimation(.easeOut(duration: 0.2)) { flash = nil }
        }
    }

    private func haptic(for action: TriageAction) {
        switch action {
        case .cut:
            // A clear bump on remove (the user's preference).
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .keep:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .hook:
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        }
    }

    // MARK: thumbnails

    private func loadThumbnails() async {
        guard let proxyURL, thumbs.isEmpty else { return }
        for seg in queue {
            let t = seg.startSeconds + min(0.4, max(0, (seg.endSeconds - seg.startSeconds) / 2))
            if let img = await ThumbnailService.thumbnail(for: proxyURL, at: t) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }
}

// MARK: - Card

private struct TriageCardView: View {
    let segment: Segment
    let thumbnail: UIImage?
    let isHook: Bool
    let isFront: Bool
    let autoPlay: Bool
    let playerActive: Bool
    let proxyURL: URL?
    let dragOffset: CGSize
    let onTapPreview: () -> Void

    private var showsPlayer: Bool { isFront && autoPlay && proxyURL != nil }
    private var showsHints: Bool { isFront && dragOffset == .zero }

    private var verdict: AIVerdict { AIVerdict(segment) }
    /// 1 at rest, fading to 0 as the front card is dragged — so the lean never fights the gesture.
    private var leanFactor: CGFloat {
        guard isFront else { return 0 }
        return max(0, 1 - hypot(dragOffset.width, dragOffset.height) / 120)
    }
    private var leanX: CGFloat { verdict.lean * 10 * leanFactor }
    private var leanDegrees: Double { Double(verdict.lean) * 2.5 * Double(leanFactor) }

    var body: some View {
        VStack(spacing: 0) {
            hero
            footer
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.16), radius: 18, y: 14)
        .offset(x: dragOffset.width + leanX, y: dragOffset.height)
        .rotationEffect(.degrees(Double(dragOffset.width) * 0.04 + leanDegrees))
        .onTapGesture { onTapPreview() }
    }

    private var hero: some View {
        ZStack {
            if showsPlayer, let url = proxyURL {
                LoopingPlayerView(url: url,
                                  start: segment.startSeconds,
                                  end: segment.trimToSeconds ?? segment.endSeconds,
                                  isPlaying: playerActive)
            } else if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                FoodTile(tone: segment.sceneType.foodTone, cornerRadius: 0)
            }

            // caption + tap-to-enlarge affordance
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    Text(segment.description)
                        .font(VeFont.serif(15, italic: true))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                }
                .padding(16)
                .background(LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .top))
            }

            // AI verdict chip (top-left) — the recommendation, marked like the hook
            verdictChip
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(12)

            // persistent direction hints (idle only)
            directionHints.opacity(showsHints ? 1 : 0)

            // live swipe badges (while dragging)
            badge("KEEP", color: Color.veSage, rotation: 8, opacity: keepOpacity, alignment: .topTrailing)
            badge("CUT", color: Color.veTerracotta, rotation: -8, opacity: cutOpacity, alignment: .topLeading)
            badge("★ HOOK", color: Color.veCharcoal, rotation: 0, opacity: hookOpacity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var directionHints: some View {
        ZStack {
            hintPill("↑ HOOK").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 12)
            hintPill("← CUT").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.leading, 10)
            hintPill("KEEP →").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 10)
        }
        .allowsHitTesting(false)
    }

    private var verdictChip: some View {
        HStack(spacing: 5) {
            Image(systemName: verdict.icon).font(.system(size: 10.5, weight: .bold))
            Text(verdict.label).font(VeFont.sans(11.5, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(verdict.tone.opacity(0.92), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }

    private func hintPill(_ text: String) -> some View {
        Text(text)
            .font(VeFont.sans(10.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.black.opacity(0.32), in: Capsule())
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                if isHook { tag("★ HOOK", fg: .white, bg: Color.veTerracotta) }
                SceneChip(text: segment.sceneType.label)
                if segment.voiceoverCandidate { tag("VO", fg: Color.veTerracotta, bg: Color.veTerracotta.opacity(0.12)) }
                Spacer()
                Text("\(Int((( segment.trimToSeconds ?? segment.endSeconds) - segment.startSeconds).rounded()))s")
                    .font(VeFont.sans(12.5, weight: .semibold)).foregroundStyle(Color.veWarmGray)
            }
            let why = verdict.reason(segment)
            if !why.isEmpty { ReasonNote(text: why) }
        }
        .padding(15)
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text).font(VeFont.sans(11, weight: .bold)).foregroundStyle(fg)
            .padding(.horizontal, 9).padding(.vertical, 4).background(bg, in: Capsule())
    }

    private func badge(_ text: String, color: Color, rotation: Double, opacity: Double, alignment: Alignment) -> some View {
        Text(text)
            .font(VeFont.sans(15, weight: .heavy)).foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(color, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var isVertical: Bool { abs(dragOffset.height) > abs(dragOffset.width) }
    private var keepOpacity: Double { (!isVertical && dragOffset.width > 0) ? min(1, dragOffset.width / 90) : 0 }
    private var cutOpacity: Double { (!isVertical && dragOffset.width < 0) ? min(1, -dragOffset.width / 90) : 0 }
    private var hookOpacity: Double { (isVertical && dragOffset.height < 0) ? min(1, -dragOffset.height / 110) : 0 }
}
