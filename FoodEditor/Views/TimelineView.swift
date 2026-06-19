import SwiftUI
import AVFoundation
import UIKit

/// M7 — Layer 2: the Living Timeline. The cut becomes a stack of vertical blocks whose **height ∝
/// duration**, with a pinned live preview that re-stitches the proxy whenever you change anything.
/// Interactions (each on its own conflict-free surface):
///   • grab the right-hand grip and drag to **reorder** (other blocks reflow to open a gap);
///   • drag the bottom handle to **trim** (the block shrinks/grows in real time);
///   • swipe a block left to **cut** it into the Cut Tray;
///   • voiceover blocks expose **Swap b-roll** (choose a food close-up to cover the talking);
///   • "Change hook" opens the Hook Spotlight.
/// Every edit mutates the shared `EditPlanStore` and rebuilds the pinned preview.
private enum TimelineTab { case main, broll }

struct TimelineView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    // Pinned preview
    @State private var player = AVPlayer()
    @State private var previewPlaying = true

    // Thumbnails for every segment (blocks + b-roll picker)
    @State private var thumbs: [Int: UIImage] = [:]

    // Reorder (driven by the grip handle)
    @State private var draggingId: UUID?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropInsertion: Int?

    // Trim (driven by the bottom handle)
    @State private var trimming: (id: UUID, base: Double)?

    // Which layer the timeline is showing.
    @State private var tab: TimelineTab = .main

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// Layout constants: points per second of footage, and the gap between blocks.
    private let pps: CGFloat = 16
    private let gap: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            hookBar
            tabBar
            Group {
                if tab == .main { timelineScroll } else { brollList }
            }
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
        .task { await loadThumbnails() }
        .task(id: previewSignature) { await rebuildPreview() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            // Loop the stitched preview.
            player.seek(to: .zero)
            if previewPlaying { player.play() }
        }
        .onDisappear { player.pause() }
    }

    // MARK: - Layer tabs

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabPill("Main", count: store?.order.count ?? 0, active: tab == .main) { tab = .main }
            tabPill("B-roll", count: store?.brollClips.count ?? 0, active: tab == .broll) { tab = .broll }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 4)
    }

    private func tabPill(_ title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(VeFont.sans(13, weight: .bold))
                Text("\(count)")
                    .font(VeFont.sans(11, weight: .bold))
                    .foregroundStyle(active ? Color.veOnTerracotta : Color.veWarmGray)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(active ? Color.white.opacity(0.22) : Color.veSurface, in: Capsule())
            }
            .foregroundStyle(active ? Color.veOnTerracotta : Color.veWarmGray)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(active ? Color.veTerracotta : Color.white, in: Capsule())
            .overlay(Capsule().stroke(active ? Color.clear : Color.veCharcoal.opacity(0.1), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - B-roll tab (the Layer 2 bucket)

    private var brollList: some View {
        Group {
            if (store?.brollClips.isEmpty ?? true) {
                brollEmptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("These play silently over your cut — arrange them on the Polish page.")
                            .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray)
                            .padding(.bottom, 2)
                        ForEach(store?.brollClips ?? [], id: \.self) { id in
                            if let seg = store?.segment(id) { brollRow(seg) }
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 24)
                }
            }
        }
    }

    private var brollEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "square.on.square").font(.system(size: 28)).foregroundStyle(Color.veFaintGray)
            Text("No B-roll yet").font(VeFont.serif(20)).foregroundStyle(Color.veCharcoal)
            Text("Swipe a clip down in Triage, or tap “Make B-roll” on a main clip.")
                .font(VeFont.sans(13)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func brollRow(_ seg: Segment) -> some View {
        HStack(spacing: 12) {
            ZStack {
                if let img = thumbs[seg.id] { Image(uiImage: img).resizable().scaledToFill() }
                else { FoodTile(tone: seg.sceneType.foodTone, cornerRadius: 10) }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(seg.description.isEmpty ? seg.sceneType.label : seg.description)
                    .font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                Text("\(seg.sceneType.label) · \(Int((seg.endSeconds - seg.startSeconds).rounded()))s")
                    .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
            }
            Spacer(minLength: 0)
            Button { toMain(seg.id) } label: {
                Text("→ Main")
                    .font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veSage)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Color.veSage.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            Button { cut(seg.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.veWarmGray).frame(width: 28, height: 28)
                    .background(Color.veSurface, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 4, y: 1)
    }

    private func toMain(_ id: Int) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { store?.unmarkBroll(id) }
        Log.app("🎞️ Moved segment \(id) back to Main. \(store?.vibeText ?? "")")
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            BackChevronButton { player.pause(); router.back() }
            Spacer()
            VibeMeterPill(text: store?.vibeText ?? "")
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 10)
    }

    // MARK: - Pinned live preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.veCharcoal)
            PlayerLayerView(player: player, gravity: .resizeAspect)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // tap anywhere to play/pause
            Button(action: togglePlay) { Color.clear }
                .buttonStyle(.plain)

            VStack {
                HStack {
                    Text("PREVIEW")
                        .font(VeFont.sans(10, weight: .bold)).tracking(1)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text("\(store?.order.count ?? 0) clips · \(Int((store?.totalDuration ?? 0).rounded()))s")
                        .font(VeFont.sans(11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Spacer()
            }
            .padding(14)

            if !previewPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.35), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 224)
        .padding(.horizontal, 22)
        .shadow(color: Color.veCharcoal.opacity(0.18), radius: 14, y: 8)
    }

    private func togglePlay() {
        previewPlaying.toggle()
        if previewPlaying { player.play() } else { player.pause() }
    }

    // MARK: - Hook bar

    private var hookBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("OPENS WITH")
                    .font(VeFont.sans(10, weight: .bold)).tracking(1)
                    .foregroundStyle(Color.veFaintGray)
                Text(hookDescription)
                    .font(VeFont.serif(15, italic: true))
                    .foregroundStyle(Color.veCharcoal)
                    .lineLimit(1)
            }
            Spacer()
            Button { router.go(.hook) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "star")
                        .font(.system(size: 12, weight: .bold))
                    Text("Change hook")
                        .font(VeFont.sans(12.5, weight: .bold))
                }
                .foregroundStyle(Color.veTerracotta)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Color.veTerracotta.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var hookDescription: String {
        if let id = store?.hookId, let seg = store?.segment(id), !seg.description.isEmpty {
            return seg.description
        }
        return store?.plan.recommendedHook ?? "—"
    }

    // MARK: - Timeline (the blocks)

    private var timelineScroll: some View {
        Group {
            if (store?.order.isEmpty ?? true) {
                emptyState
            } else {
                ScrollView {
                    blockStack
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                }
                .scrollDisabled(draggingId != nil || trimming != nil)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Everything's cut")
                .font(VeFont.serif(20)).foregroundStyle(Color.veCharcoal)
            Text("Go back to Triage and restore a clip from the Cut Tray.")
                .font(VeFont.sans(13)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 260)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var blockStack: some View {
        let order = store?.order ?? []
        let pTops = tops(previewOrder)
        return ZStack(alignment: .top) {
            ForEach(order) { clip in
                blockRow(clip, pTops: pTops)
            }
        }
        .frame(height: contentHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }

    // MARK: - One block (positioned + hold-to-reorder)

    /// Places the diffable `TimelineBlockView` at its computed top and attaches the hold-to-reorder
    /// gesture. Lifting requires a ~0.3s long-press, so quick vertical drags pass through to the
    /// ScrollView (smooth scrolling) and a quick tap still seeks the preview.
    @ViewBuilder
    private func blockRow(_ clip: Clip, pTops: [UUID: CGFloat]) -> some View {
        if let store, let seg = store.segment(clip.sourceSegmentId) {
            let dragging = draggingId == clip.id
            let top = dragging ? (staticTop(clip.id) + dragTranslation) : (pTops[clip.id] ?? 0)
            TimelineBlockView(
                segment: seg,
                duration: clip.sourceDuration,
                durationText: durationText(clip.sourceDuration),
                isHook: store.hookId == clip.sourceSegmentId,
                isTrimming: trimming?.id == clip.id,
                isDragging: dragging,
                canMakeBroll: store.hookId != clip.sourceSegmentId,
                thumbnail: thumbs[clip.sourceSegmentId],
                onTapSeek: { seekPreview(to: clip.id) },
                onCut: { cut(clip.sourceSegmentId) },
                onMakeBroll: { makeBroll(clip.sourceSegmentId) },
                onTrim: { dy in applyTrim(clip.id, dy: dy) },
                onTrimEnd: { endTrim(clip.id) }
            )
            .frame(height: blockHeight(clip))
            .frame(maxWidth: .infinity)
            .offset(y: top)
            .zIndex(dragging ? 100 : 1)
            .animation(dragging ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: top)
            // simultaneousGesture (not .gesture) so a quick vertical swipe still scrolls the list;
            // the long-press only "lifts" a clip after a hold, and scrollDisabled then stops the pan.
            .simultaneousGesture(reorderGesture(clip.id))
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button { player.pause(); router.go(.polish) } label: {
                Text("Polish")
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal)
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.veCharcoal.opacity(0.12), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            PrimaryActionButton(title: "Export · \(Int((store?.totalDuration ?? 0).rounded()))s") {
                player.pause()
                router.go(.export)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 26)
        .background(
            LinearGradient(colors: [Color.veCream.opacity(0), Color.veCream],
                           startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        )
    }

    // MARK: - Geometry helpers

    /// Block height encodes duration, but never shorter than its content needs (a voiceover block
    /// carries an extra "Swap b-roll" row), so content can't overflow onto the next block.
    private func blockHeight(_ clip: Clip) -> CGFloat {
        // Non-hook blocks carry a "Make B-roll" row, so they need a little more floor.
        let floor: CGFloat = (store?.hookId == clip.sourceSegmentId) ? 96 : 112
        return max(floor, min(210, CGFloat(clip.sourceDuration) * pps))
    }

    /// Cumulative top offsets for a given order.
    private func tops(_ order: [Clip]) -> [UUID: CGFloat] {
        var result: [UUID: CGFloat] = [:]
        var y: CGFloat = 0
        for clip in order {
            result[clip.id] = y
            y += blockHeight(clip) + gap
        }
        return result
    }

    private func staticTop(_ cid: UUID) -> CGFloat { tops(store?.order ?? [])[cid] ?? 0 }

    private var contentHeight: CGFloat {
        let clips = store?.order ?? []
        let h = clips.reduce(CGFloat(0)) { $0 + blockHeight($1) }
        return h + CGFloat(max(0, clips.count - 1)) * gap
    }

    /// The order to render while a block is mid-drag (dragged clip moved to its drop slot).
    private var previewOrder: [Clip] {
        guard let store else { return [] }
        guard let dragId = draggingId, let insertion = dropInsertion,
              let clip = store.order.first(where: { $0.id == dragId }) else { return store.order }
        var arr = store.order
        arr.removeAll { $0.id == dragId }
        arr.insert(clip, at: max(0, min(insertion, arr.count)))
        return arr
    }

    /// Insertion index among the *other* blocks for the current finger position.
    private func computeInsertion(_ translationY: CGFloat) -> Int {
        guard let store, let dragId = draggingId,
              let dragClip = store.order.first(where: { $0.id == dragId }) else { return 0 }
        let staticTops = tops(store.order)
        let center = (staticTops[dragId] ?? 0) + blockHeight(dragClip) / 2 + translationY
        var count = 0
        for clip in store.order where clip.id != dragId {
            let c = (staticTops[clip.id] ?? 0) + blockHeight(clip) / 2
            if c < center { count += 1 }
        }
        return count
    }

    // MARK: - Gestures

    /// Hold (~0.3s) to lift a clip, then drag to reorder. Because lifting requires a long-press,
    /// a quick vertical drag is never captured here — it falls through to the ScrollView.
    private func reorderGesture(_ cid: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard let store, case .second(true, let drag) = value else { return }
                if draggingId != cid {
                    draggingId = cid
                    dropInsertion = store.order.firstIndex(where: { $0.id == cid })
                    dragTranslation = 0
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()   // "lifted" cue
                }
                let t = drag?.translation.height ?? 0
                dragTranslation = t
                let ins = computeInsertion(t)
                if ins != dropInsertion {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dropInsertion = ins }
                }
            }
            .onEnded { _ in
                guard let store, let did = draggingId, let ins = dropInsertion else {
                    draggingId = nil; dropInsertion = nil; dragTranslation = 0; return
                }
                store.reorder(cid: did, to: ins)
                Log.app("🎞️ Reorder clip → index \(ins). \(store.vibeText)")
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    draggingId = nil; dropInsertion = nil; dragTranslation = 0
                }
            }
    }

    /// Called continuously while the bottom handle is dragged (translation in points).
    private func applyTrim(_ cid: UUID, dy: CGFloat) {
        guard let store, let clip = store.order.first(where: { $0.id == cid }) else { return }
        if trimming?.id != cid { trimming = (id: cid, base: clip.sourceDuration) }
        let base = trimming?.base ?? clip.sourceDuration
        store.setSourceDuration(cid, seconds: base + Double(dy / pps))
    }

    private func endTrim(_ cid: UUID) {
        guard let store, let clip = store.order.first(where: { $0.id == cid }) else { trimming = nil; return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Log.app("🎞️ Trim clip → \(durationText(clip.sourceDuration)). \(store.vibeText)")
        trimming = nil
    }

    private func cut(_ id: Int) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            store?.cut(id)
        }
        Log.app("🎞️ Cut segment \(id) from timeline. \(store?.vibeText ?? "")")
    }

    private func makeBroll(_ id: Int) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            store?.markBroll(id)
            tab = .broll
        }
        Log.app("🎞️ Marked segment \(id) as B-roll. \(store?.vibeText ?? "")")
    }

    // MARK: - Preview seek / rebuild

    private func seekPreview(to cid: UUID) {
        guard let store else { return }
        var t: Double = 0
        for c in store.order { if c.id == cid { break }; t += c.sourceDuration }
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        previewPlaying = true
        player.play()
    }

    /// Signature of everything that affects the stitched preview (order + per-clip in/out points).
    private var previewSignature: String {
        guard let store else { return "" }
        return store.order.map { "\($0.id)@\(Int($0.inPoint * 100))-\(Int($0.outPoint * 100))" }.joined(separator: ",")
    }

    private func rebuildPreview() async {
        guard let store, let proxyURL else { return }
        let ranges: [TimelinePreview.Range] = store.order.map { clip in
            TimelinePreview.Range(start: clip.inPoint, end: clip.outPoint)
        }
        guard !ranges.isEmpty, let item = await TimelinePreview.makeItem(proxyURL: proxyURL, ranges: ranges) else {
            return
        }
        await MainActor.run {
            AudioSession.configureForPlayback()
            player.replaceCurrentItem(with: item)
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if previewPlaying { player.play() }
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let proxyURL, thumbs.isEmpty else { return }
        for seg in store?.plan.segments ?? [] {
            let t = seg.startSeconds + min(0.4, max(0, (seg.endSeconds - seg.startSeconds) / 2))
            if let img = await ThumbnailService.thumbnail(for: proxyURL, at: t) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }

    private func durationText(_ d: Double) -> String {
        String(format: d < 10 ? "%.1fs" : "%.0fs", d)
    }

}

// MARK: - Timeline block (a real View struct so SwiftUI diffs it — keeps drag smooth)

/// One clip block in the Living Timeline. Pure presentation + small controls; the parent owns the
/// reorder gesture and geometry. Being a concrete `View` (not an `AnyView`) lets SwiftUI diff it, so
/// a drag only moves the one block instead of rebuilding every block + thumbnail each frame.
private struct TimelineBlockView: View {
    let segment: Segment
    let duration: Double
    let durationText: String
    let isHook: Bool
    let isTrimming: Bool
    let isDragging: Bool
    let canMakeBroll: Bool           // false for the hook (it always stays on the main spine)
    let thumbnail: UIImage?
    let onTapSeek: () -> Void
    let onCut: () -> Void
    let onMakeBroll: () -> Void
    let onTrim: (CGFloat) -> Void
    let onTrimEnd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumb
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    if isHook { miniTag("★ HOOK", fg: .white, bg: .veTerracotta) }
                    SceneChip(text: segment.sceneType.label)
                    if segment.voiceoverCandidate {
                        miniTag("VO", fg: .veTerracotta, bg: Color.veTerracotta.opacity(0.12))
                    }
                    Spacer(minLength: 0)
                    Text(durationText)
                        .font(VeFont.sans(12.5, weight: .bold))
                        .foregroundStyle(isTrimming ? Color.veTerracotta : Color.veWarmGray)
                    cutButton
                }
                if !segment.description.isEmpty {
                    Text(segment.description)
                        .font(VeFont.sans(13, weight: .semibold))
                        .foregroundStyle(Color.veCharcoal)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                if canMakeBroll { makeBrollRow }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isHook ? Color.veTerracotta.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: .bottom) { trimHandle }
        .shadow(color: Color.veCharcoal.opacity(isDragging ? 0.22 : 0.06),
                radius: isDragging ? 16 : 5, y: isDragging ? 12 : 2)
        .scaleEffect(isDragging ? 1.03 : 1)
        .contentShape(Rectangle())
        .onTapGesture { onTapSeek() }
    }

    private var thumb: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                FoodTile(tone: segment.sceneType.foodTone, cornerRadius: 0)
            }
        }
        .frame(width: 46)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var cutButton: some View {
        Button(action: onCut) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.veWarmGray)
                .frame(width: 24, height: 24)
                .background(Color.veSurface, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func miniTag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(VeFont.sans(10, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(bg, in: Capsule())
    }

    private var makeBrollRow: some View {
        Button(action: onMakeBroll) {
            HStack(spacing: 6) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.veTerracotta)
                Text("Make B-roll")
                    .font(VeFont.sans(11, weight: .bold))
                    .foregroundStyle(Color.veTerracotta)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.veNote, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Bottom trim handle — drag vertically to lengthen/shorten. Its own high-priority drag so a touch
    /// on the handle trims instead of triggering reorder. The hit area is a small CENTERED grabber
    /// (not full-width) so the rest of the row stays free for the ScrollView to pan.
    private var trimHandle: some View {
        Capsule().fill(Color.veSurface)
            .frame(width: 44, height: 5)
            .overlay(Capsule().stroke(Color.veFaintGray.opacity(0.6), lineWidth: 1))
            .frame(width: 90, height: 20)          // small centered hit target
            .contentShape(Rectangle())
            .padding(.bottom, 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { onTrim($0.translation.height) }
                    .onEnded { _ in onTrimEnd() }
            )
    }
}

// MARK: - Controls-free player layer (externally owned AVPlayer)

/// A thin SwiftUI wrapper over `AVPlayerLayer` for an `AVPlayer` the parent owns and drives.
/// Used for the pinned timeline preview (no AVKit transport controls).
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.playerLayer.videoGravity = gravity
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

// MARK: - Live preview compositor

/// Builds a lightweight single-asset composition that stitches the ordered `[start, end]` proxy
/// slices into one playable item — the timeline's live preview. (Final full-resolution assembly is M8.)
enum TimelinePreview {
    struct Range { let start: Double; let end: Double }

    static func makeItem(proxyURL: URL, ranges: [Range]) async -> AVPlayerItem? {
        let asset = AVURLAsset(url: proxyURL)
        guard let srcVideo = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let srcAudio = try? await asset.loadTracks(withMediaType: .audio).first
        let assetDuration = (try? await asset.load(.duration).seconds) ?? .greatestFiniteMagnitude

        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let aTrack = (srcAudio != nil)
            ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var cursor = CMTime.zero
        for r in ranges {
            let start = max(0, r.start)
            let end = min(r.end, assetDuration)
            guard end > start + 0.05 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                    end: CMTime(seconds: end, preferredTimescale: 600))
            try? vTrack.insertTimeRange(range, of: srcVideo, at: cursor)
            if let aTrack, let srcAudio { try? aTrack.insertTimeRange(range, of: srcAudio, at: cursor) }
            cursor = cursor + range.duration
        }

        if let t = try? await srcVideo.load(.preferredTransform) { vTrack.preferredTransform = t }
        guard cursor > .zero else { return nil }
        return AVPlayerItem(asset: comp)
    }
}
