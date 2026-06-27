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
    @State private var dragTranslation: CGFloat = 0    // dragRawTranslation + autoPanY (content-space delta)
    @State private var dropInsertion: Int?

    // Drag-past-the-edge auto-scroll (mirrors PolishView's horizontal version). During a lift the native
    // scroll is frozen and we scroll by a manual content offset (`dragScrollY`) — reliable, unlike
    // programmatic scrollTo under scrollDisabled. On release we scrollTo so the dropped clip stays in view.
    @State private var autoScroller = EdgeAutoScroller(axis: .vertical)
    @State private var dragRawTranslation: CGFloat = 0  // finger movement in viewport space since lift
    @State private var autoPanY: CGFloat = 0            // = dragScrollY; content-space delta from scroll
    @State private var dragScrollY: CGFloat = 0         // manual scroll offset applied during the lift
    @State private var viewportHeight: CGFloat = 0      // ScrollView viewport height
    @State private var contentMinY: CGFloat = 0         // blockStack top in the fixed viewport space (resting)
    @State private var contentMinYAtLift: CGFloat = 0
    @State private var scrollProxy: ScrollViewProxy?

    // Trim (driven by the bottom handle)
    @State private var trimming: (id: UUID, base: Double)?

    // Which layer the timeline is showing.
    @State private var tab: TimelineTab = .main

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// Layout constants: points per second of footage, and the gap between blocks.
    private let pps: CGFloat = 16
    private let gap: CGFloat = 10
    /// Full-width content-section header row inserted before the first clip of each `topic` section.
    private let sectionHeaderHeight: CGFloat = 30
    private let sectionHeaderGap: CGFloat = 6

    /// Auto-scroll plumbing. The blocks are `.offset`-positioned in a fixed-height ZStack, so per-block
    /// `scrollTo` anchors don't work (every block shares one layout slot). Instead an invisible ruler of
    /// real-layout anchors gives `scrollTo` something to aim at; the live scroll offset is measured.
    private let timelineSpace = "tlv"
    private let anchorPitch: CGFloat = 8
    private enum AnchorID: Hashable { case row(Int) }
    private struct ScrollOffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// Tracks the timeline's vertical scroll offset into `contentMinY`. iOS 18+ uses the reliable
    /// `onScrollGeometryChange`; a GeometryReader inside ScrollView content returns 0 regardless of scroll
    /// on iOS 26 (that was the "can't drag up" bug). Emits the blockStack top in viewport space (≈ `topPadding`
    /// at the top, negative as you scroll down). Skips updates mid-lift so the manual `dragScrollY` offset
    /// can't perturb the captured resting position.
    private struct ScrollOffsetReader: ViewModifier {
        let topPadding: CGFloat
        let isDragging: Bool
        let onResting: (CGFloat) -> Void
        func body(content: Content) -> some View {
            if #available(iOS 18.0, *) {
                content.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                    if !isDragging { onResting(topPadding - y) }
                }
            } else {
                content
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(seg.description.isEmpty ? seg.sceneType.label : seg.description)
                    .font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                HStack(spacing: 6) {
                    let section = TopicGrouping.sectionLabel(seg)
                    if !section.isEmpty {
                        Text(section.uppercased())
                            .font(VeFont.sans(10, weight: .bold)).tracking(0.4)
                            .foregroundStyle(Color.veTerracotta).lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.veTerracotta.opacity(0.1), in: Capsule())
                    }
                    Text("\(seg.sceneType.label) · \(Int((seg.endSeconds - seg.startSeconds).rounded()))s")
                        .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
                }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        ZStack(alignment: .top) {
                            anchorRuler                    // first-class targets for the release scrollTo
                            blockStack
                        }
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScrollOffsetKey.self,
                                                   value: g.frame(in: .named(timelineSpace)).minY)
                        })
                        .offset(y: -dragScrollY)           // manual auto-scroll while a clip is lifted
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                    }
                    .scrollDisabled(draggingId != nil || trimming != nil)
                    .coordinateSpace(name: timelineSpace)
                    // Scroll offset → `contentMinY` (blockStack top in viewport space: ≈6 at the top, negative
                    // as you scroll down). iOS 18+ uses the reliable `onScrollGeometryChange`; a GeometryReader
                    // inside ScrollView content reports 0 regardless of scroll on iOS 26 (that was the bug).
                    .modifier(ScrollOffsetReader(topPadding: 6, isDragging: draggingId != nil) { y in
                        contentMinY = y
                    })
                    // iOS 17 fallback only — the in-content GeometryReader measurement (above).
                    .onPreferenceChange(ScrollOffsetKey.self) { y in
                        if draggingId == nil, #unavailable(iOS 18.0) { contentMinY = y }
                    }
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { viewportHeight = g.size.height; scrollProxy = proxy }
                            .onChange(of: g.size.height) { _, h in viewportHeight = h }
                    })
                }
            }
        }
    }

    /// Invisible ruler of real-layout anchors (one every `anchorPitch` pts) that `scrollTo` can target.
    private var anchorRuler: some View {
        let n = max(2, Int((contentHeight / anchorPitch).rounded(.up)))
        return VStack(spacing: 0) {
            ForEach(Array(0..<n), id: \.self) { i in
                Color.clear.frame(height: anchorPitch).id(AnchorID.row(i))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
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
        // Headers + tops reflow with the live drop preview while a clip is lifted.
        let lay = layout(previewOrder)
        return ZStack(alignment: .top) {
            ForEach(lay.headers) { h in
                SectionHeaderRow(label: h.label, count: h.count)
                    .frame(height: sectionHeaderHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: h.y)
                    .animation(.spring(response: 0.32, dampingFraction: 0.82), value: h.y)
                    .allowsHitTesting(false)
            }
            ForEach(order) { clip in
                blockRow(clip, pTops: lay.tops)
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
        // Forward CTA only — lateral moves use the shell's StageSwitcher, and Export lives in the shell
        // header. (Matches the mockup's Arrange screen: a single "Continue to Polish".)
        PrimaryActionButton(title: "Continue to Polish") {
            player.pause()
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { session.editorStage = .polish }
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
        // Every block carries a "Make B-roll" row (the hook can become B-roll too), so they all need
        // the same floor to fit it.
        let floor: CGFloat = 112
        return max(floor, min(210, CGFloat(clip.sourceDuration) * pps))
    }

    /// A section-header placement in content space (keyed by the first clip of its run for a stable
    /// SwiftUI identity, so it animates with reflow rather than re-inserting).
    private struct SectionHeaderPlacement: Identifiable {
        let id: UUID        // first clip's id
        let label: String
        let count: Int
        let y: CGFloat
    }
    /// One layout pass over an order: per-clip top offsets, the section-header rows, and total height.
    private struct TimelineLayout {
        var tops: [UUID: CGFloat] = [:]
        var headers: [SectionHeaderPlacement] = []
        var total: CGFloat = 0
    }

    /// Single source of all y-positions: walks `order`, inserting a header row before the first clip
    /// of each new `topic` section (so the spine reads section-by-section). Every geometry consumer
    /// (`tops`, `contentHeight`, the drag insertion, auto-scroll) goes through this, so the header
    /// offsets stay consistent and the reorder math needs no special-casing. With no topics present it
    /// emits no headers — identical to the pre-feature layout.
    private func layout(_ order: [Clip]) -> TimelineLayout {
        var out = TimelineLayout()
        var y: CGFloat = 0
        var prevKey: String? = nil
        var i = 0
        while i < order.count {
            let clip = order[i]
            let seg = store?.segment(clip.sourceSegmentId)
            let k = TopicGrouping.key(seg?.topic ?? "")
            if let k, k != prevKey {
                // Count this section's contiguous run (for the header's clip count).
                var n = 0, j = i
                while j < order.count,
                      TopicGrouping.key(store?.segment(order[j].sourceSegmentId)?.topic ?? "") == k {
                    n += 1; j += 1
                }
                out.headers.append(SectionHeaderPlacement(
                    id: clip.id, label: seg.map(TopicGrouping.sectionLabel) ?? "", count: n, y: y))
                y += sectionHeaderHeight + sectionHeaderGap
            }
            out.tops[clip.id] = y
            y += blockHeight(clip) + gap
            if k != nil { prevKey = k }
            i += 1
        }
        out.total = max(0, y - gap)
        return out
    }

    /// Cumulative top offsets for a given order (header rows included — see `layout`).
    private func tops(_ order: [Clip]) -> [UUID: CGFloat] { layout(order).tops }

    private func staticTop(_ cid: UUID) -> CGFloat { tops(store?.order ?? [])[cid] ?? 0 }

    private var contentHeight: CGFloat { layout(store?.order ?? []).total }

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

    /// Insertion index among the *other* blocks for the dragged block's center in content space.
    private func computeInsertion(draggedCenter center: CGFloat) -> Int {
        guard let store, let dragId = draggingId else { return 0 }
        let staticTops = tops(store.order)
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
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)))
            .onChanged { value in
                guard let store, case .second(true, let drag) = value else { return }
                if draggingId != cid {
                    draggingId = cid
                    dropInsertion = store.order.firstIndex(where: { $0.id == cid })
                    dragRawTranslation = 0; autoPanY = 0; dragTranslation = 0; dragScrollY = 0
                    contentMinYAtLift = contentMinY
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()   // "lifted" cue
                }
                dragRawTranslation = drag?.translation.height ?? 0
                dragTranslation = dragRawTranslation + autoPanY
                updateInsertion()
                driveAutoScroll(fingerY: draggedViewportCenter())
            }
            .onEnded { _ in
                autoScroller.stop()
                let pan = dragScrollY
                guard let store, let did = draggingId, let ins = dropInsertion else {
                    draggingId = nil; dropInsertion = nil; dragTranslation = 0; autoPanY = 0; dragScrollY = 0; return
                }
                store.reorder(cid: did, to: ins)
                Log.app("🎞️ Reorder clip → index \(ins). \(store.vibeText)")
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Removing the manual offset would snap the list back to the pre-auto-scroll spot, so if we
                // auto-scrolled, hand the position to the real ScrollView: scroll the dropped clip into view.
                if abs(pan) > 1 {
                    let n = max(2, Int((contentHeight / anchorPitch).rounded(.up)))
                    let idx = max(0, min(Int(((tops(store.order)[did] ?? 0) / anchorPitch).rounded()), n - 1))
                    scrollProxy?.scrollTo(AnchorID.row(idx), anchor: .center)
                }
                draggingId = nil; dropInsertion = nil; dragTranslation = 0; autoPanY = 0; dragScrollY = 0
            }
    }

    /// Apply a measured content-scroll amount: refresh the dragged block's content-space delta and the
    /// live drop index. Called from the scroll-offset preference as the timeline auto-scrolls.
    private func applyAutoPan(_ pan: CGFloat) {
        autoPanY = pan
        dragTranslation = dragRawTranslation + autoPanY
        updateInsertion()
    }

    /// While lifted and the finger is in the top/bottom edge band, scroll the timeline (via the manual
    /// `dragScrollY` content offset) so the clip can be carried past the visible clips. Bounds keep it
    /// from scrolling past either content end; the gate requires actually dragging toward that edge.
    private func driveAutoScroll(fingerY: CGFloat) {
        // dragScrollY range: how far the content can move up (toward the top) / down (toward the bottom)
        // from the resting offset captured at lift, without exposing blank space past either end.
        let restMin = contentMinYAtLift - 6                                          // top rest ≈ 6pt padding
        let restMax = contentMinYAtLift - (viewportHeight - contentHeight - 24)       // bottom (24pt padding)
        // Over-pan past the natural top/bottom rest while lifted, so the dragged clip's center can cross the
        // first/last clip's center even when the finger is pinned inside the edge band (the cause of the old
        // "can't drag a clip all the way up" bug). Mirrors PolishView's centered-playhead headroom, but only
        // during a lift (resting layout stays tight) and only when the list overflows (short lists need no
        // scroll, so 0 headroom keeps them from drifting). Headroom covers the edge band (64) plus the dragged
        // block's own half-height, so even a tall (up to 210pt) first/last clip's center can be pushed across.
        let draggedHalf = draggingId.flatMap { id in store?.order.first { $0.id == id } }
            .map { blockHeight($0) / 2 } ?? 56
        let headroom: CGFloat = contentHeight > viewportHeight ? 64 + draggedHalf : 0
        let minPan = restMin - headroom
        let maxPan = restMax + headroom
        let dy = dragRawTranslation
        let lastIndex = max(0, (store?.order.count ?? 0) - 1)
        let canUp = dragScrollY > minPan && dy < -8 && (dropInsertion ?? 1) > 0
        let canDown = dragScrollY < maxPan && dy > 8 && (dropInsertion ?? -1) < lastIndex
        autoScroller.onTick = { delta in
            guard maxPan > minPan else { return }
            dragScrollY = max(minPan, min(dragScrollY + delta, maxPan))
            applyAutoPan(dragScrollY)
        }
        // Stop pulling once the live drop index is already at an end, so it won't scroll into blank.
        autoScroller.update(location: fingerY, viewportLength: viewportHeight,
                            canScrollStart: canUp, canScrollEnd: canDown)
    }

    private func updateInsertion() {
        // Plain assignment — NOT withAnimation. This runs from the auto-scroll CADisplayLink tick (via
        // applyAutoPan), and calling withAnimation from a display-link callback bases the animation on the
        // link's timestamp, colliding with SwiftUI's clock ("Invalid sample … time 0.0 > last time" spam).
        // The reflow still springs: the blocks (`.animation(value: top)`) and section headers
        // (`.animation(value: h.y)`) animate the change themselves in SwiftUI's normal update cycle.
        let ins = computeInsertion(draggedCenter: currentDraggedCenter())
        if ins != dropInsertion { dropInsertion = ins }
    }

    /// The dragged block's center in content space (static slot + finger movement + auto-scroll).
    private func currentDraggedCenter() -> CGFloat {
        guard let store, let dragId = draggingId,
              let dragClip = store.order.first(where: { $0.id == dragId }) else { return 0 }
        return staticTop(dragId) + blockHeight(dragClip) / 2 + dragTranslation
    }

    /// The dragged block's center in the FIXED viewport, for edge-band auto-scroll detection. Derived from
    /// the resting content offset captured at lift + the finger delta — NOT from `drag.location`, whose y in
    /// a ScrollView-named coordinate space is content-relative (it grows as you scroll down), which made the
    /// top edge band unreachable so the timeline never auto-scrolled UP. The block's own `+dragScrollY`
    /// offset cancels the content's `-dragScrollY` offset, so this is independent of how far we've
    /// auto-scrolled — keeping the detection point stable in the viewport while the finger is held.
    private func draggedViewportCenter() -> CGFloat {
        guard let store, let dragId = draggingId,
              let dragClip = store.order.first(where: { $0.id == dragId }) else { return 0 }
        return contentMinYAtLift + staticTop(dragId) + blockHeight(dragClip) / 2 + dragRawTranslation
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
                makeBrollRow
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
    /// An extra affine transform on the player layer (used for per-clip crop zoom/pan). Applied to a
    /// SUBLAYER, not via SwiftUI `.scaleEffect` (which rasterizes the live video to black) nor the
    /// backing layer (which UIKit resets from `view.transform` on every layout pass).
    var contentTransform: CGAffineTransform = .identity

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.clipsToBounds = true
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        return v
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
        uiView.playerLayer.videoGravity = gravity
        uiView.contentTransform = contentTransform
    }
}

/// Hosts an `AVPlayerLayer` as a **sublayer** (not the backing layer) so a per-clip crop transform on it
/// survives UIKit's layout passes. The sublayer is sized to bounds each layout; `contentTransform` zooms
/// /pans it about its center, clipped by the host's `clipsToBounds`.
final class PlayerHostView: UIView {
    let playerLayer = AVPlayerLayer()
    var contentTransform: CGAffineTransform = .identity { didSet { applyTransform() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        playerLayer.setAffineTransform(contentTransform)
        CATransaction.commit()
    }

    private func applyTransform() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.setAffineTransform(contentTransform)
        CATransaction.commit()
    }
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
