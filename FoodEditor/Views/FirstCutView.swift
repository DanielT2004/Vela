import SwiftUI
import UIKit

/// The post-analysis reveal — the **Cut Card** (route `.segments`). One celebratory, gift-sized frame:
/// "Here's your cut.", the assembled filmstrip of the user's OWN clips, one plain fact line, and a
/// pinned "Start sorting" — with **"The Read"** (the full breakdown, [BreakdownSheet](FoodEditor/Views/BreakdownSheet.swift))
/// literally peeking up from the bottom edge as a drawn sheet lip.
///
/// De-annotated by design (2026-07-14 beta simplicity pass — "analytics app with an editor attached"):
/// the card shows WHAT we made, so the filmstrip here renders `annotated: false` (no flags/stars/
/// legend/band words); every annotation and analysis section lives in The Read, one tap or drag away
/// (detents half → full). Gesture grammar: buttons move between rooms, swipes act inside rooms — Sort
/// entry is the TAP on "Start sorting", never a swipe (deck swipe-up already means "make it the hook").
struct FirstCutView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(TemplateService.self) private var templates

    @State private var thumbs: [Int: UIImage] = [:]
    @State private var preview: SlicePreview?
    @State private var appeared = false
    @State private var showCurtain = false
    @State private var showBreakdown = false
    /// One-shot spring nudge on the Read lip after the curtain lifts (hint-nudge playbook) — rests at 0.
    @State private var lipNudge: CGFloat = 0

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// A [start,end] proxy slice to preview (from a filmstrip tile).
    private struct SlicePreview: Identifiable {
        let id = UUID()
        let start: Double
        let end: Double
        let caption: String
    }

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()
            if let store, let read = makeRead(store) {
                content(store: store, read: read)
            } else {
                ProgressView().tint(Color.veTerracotta)
            }
        }
        .overlay {
            if showCurtain {
                RevealCurtain(
                    onRevealStart: {
                        // Curtain begins lifting: play the card's entrance underneath + the "ready" haptic.
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
                    },
                    onRevealEnd: {
                        showCurtain = false   // curtain fully gone → remove it
                        nudgeLip()            // one-shot "I'm alive" hint on the Read lip
                    }
                )
                .transition(.identity)   // the curtain animates its own slide-off; don't double-animate
                .zIndex(10)
            }
        }
        .task { await loadThumbnails() }
        .onAppear {
            // Show the celebratory curtain exactly once, only on a fresh reveal (never on Back-from-editor).
            let reveal = session.pendingReveal
            session.pendingReveal = false
            if reveal {
                showCurtain = true       // entrance + haptic deferred to the curtain's onReveal (at lift)
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
            }
        }
        .sheet(item: $preview) { p in
            if let url = proxyURL {
                SlicePlayerSheet(url: url, start: p.start, end: p.end, caption: p.caption)
            }
        }
        .sheet(isPresented: $showBreakdown) {
            if let store, let read = makeRead(store) {
                BreakdownSheet(store: store, read: read, thumbs: thumbs, proxyURL: proxyURL)
                    .presentationDetents([.fraction(0.55), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func makeRead(_ store: EditPlanStore) -> RetentionRead? {
        guard !store.order.isEmpty || !store.plan.segments.isEmpty else { return nil }
        return RetentionRead(plan: store.plan, store: store, brief: session.brief)
    }

    // MARK: - Content (one frame; scrolls only when it must, e.g. SE-class screens)

    private func content(store: EditPlanStore, read: RetentionRead) -> some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header(store: store)
                    filmCard(store: store).padding(.top, 20)
                    if let name = templates.active?.name { styleChip(name).padding(.top, 12) }
                }
                .padding(.horizontal, 22)
                .padding(.top, 52)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(.bottom, 186, for: .scrollContent)   // clearance above the pinned cluster

            bottomCluster(read: read)
        }
    }

    // MARK: - Header

    private func header(store: EditPlanStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                BackChevronButton { router.back() }
                Spacer()
                HomeButton { router.home() }
            }
            .padding(.bottom, 16)

            Text("YOUR FIRST CUT")
                .font(VeFont.sans(11.5, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Color.veTerracotta)
            Text("Here's your cut.")
                .font(VeFont.serif(29))
                .foregroundStyle(Color.veCharcoal)
                .padding(.top, 6)
            if !store.plan.videoSummary.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(store.plan.videoSummary)
                    .font(VeFont.serif(15.5, italic: true))
                    .foregroundStyle(Color.veNoteText)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    // MARK: - The film card (naked strip — WHAT we made; the annotations live in The Read)

    private func filmCard(store: EditPlanStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RetentionMapStrip(store: store, thumbs: thumbs, read: nil, appeared: appeared, annotated: false) { clip in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let seg = store.segment(clip.sourceSegmentId)
                preview = SlicePreview(start: clip.inPoint, end: clip.outPoint,
                                       caption: seg?.description ?? "")
            }

            Text(factLine(store))
                .font(VeFont.serif(14.5, italic: true))
                .foregroundStyle(Color.veNoteText)
                .fixedSize(horizontal: false, vertical: true)

            Text("tap any moment to preview it")
                .font(VeFont.sans(11.5))
                .foregroundStyle(Color.veWarmGray)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.06), radius: 10, y: 3)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 14)
    }

    /// Plain facts, no band words: "14 moments · about 28s — opens on the cheese pull".
    private func factLine(_ store: EditPlanStore) -> String {
        let count = store.order.count
        let secs = Int(store.totalDuration.rounded())
        var line = "\(count) moment\(count == 1 ? "" : "s") · about \(secs)s"
        let opener = (store.hookId.flatMap { store.segment($0) }
                      ?? store.order.first.flatMap { store.segment($0.sourceSegmentId) })?.description ?? ""
        let trimmed = opener.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let short = trimmed.count > 46 ? String(trimmed.prefix(44)) + "…" : trimmed
            line += " — opens on \(short.prefix(1).lowercased() + short.dropFirst())"
        }
        return line
    }

    private func styleChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
            Text("Cut in your style — \(name)").font(VeFont.sans(12.5, weight: .semibold))
        }
        .foregroundStyle(Color.veSage)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.veSage.opacity(0.12), in: Capsule())
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - Pinned bottom cluster: Start sorting + the Read lip

    private func bottomCluster(read: RetentionRead) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                PrimaryActionButton(title: "Start sorting") {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    session.editorStage = .sort
                    router.go(.editor)
                }
                Text("swipe → keep · ← cut · ↑ hook")
                    .font(VeFont.sans(11.5))
                    .foregroundStyle(Color.veFaintGray)
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(
                Color.veCream
                    .shadow(color: Color.veCharcoal.opacity(0.06), radius: 8, y: -3)
            )

            readLip(read: read)
        }
        .opacity(appeared ? 1 : 0)
    }

    /// The drawn sheet edge — a plain Button (no DragGesture; the real sheet's detents provide the
    /// drag-up). Bleeds under the home indicator so it reads as a drawer tucked below the screen.
    private func readLip(read: RetentionRead) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showBreakdown = true
        } label: {
            VStack(spacing: 7) {
                Capsule().fill(Color.veCharcoal.opacity(0.18)).frame(width: 36, height: 4.5)
                HStack(spacing: 6) {
                    Text("THE ANALYSIS")
                        .font(VeFont.sans(11, weight: .heavy)).tracking(1.0)
                        .foregroundStyle(Color.veTerracotta)
                    Spacer(minLength: 8)
                    lipChip("bolt.fill", read.scrollStop.shortLabel)
                    lipChip("waveform", read.pace.word)
                    lipChip("timer", read.lengthTitle)
                    lipChip("star.fill", read.payoff.chip)
                }
            }
            .padding(.top, 10).padding(.horizontal, 20).padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The lip LOOKS like a drawer, so it must also answer a pull: a deliberate upward swipe opens
        // the sheet (whose presentation animates up from exactly here, so the hand-off reads as one
        // motion). Fixed chrome, not scroll content — the direction-guarded drag breaks no rules.
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { v in
                    guard !showBreakdown,
                          v.translation.height < -18,
                          abs(v.translation.height) > abs(v.translation.width) else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showBreakdown = true
                }
        )
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous)
                .fill(Color.white)
                .shadow(color: Color.veCharcoal.opacity(0.10), radius: 10, y: -4)
                .ignoresSafeArea(edges: .bottom)
        )
        .offset(y: lipNudge)
    }

    private func lipChip(_ symbol: String, _ word: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(Color.veWarmGray)
            Text(word).font(VeFont.sans(10, weight: .bold)).foregroundStyle(Color.veCharcoal)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Color.veSurface, in: Capsule())
    }

    /// One-shot hint (playbook): spring the lip up a touch, then settle back to rest at zero.
    private func nudgeLip() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.6)) { lipNudge = -7 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { lipNudge = 0 }
        }
    }

    // MARK: - Thumbnails

    private func loadThumbnails() async {
        guard let store, let url = proxyURL, thumbs.isEmpty else { return }
        // Spine clips (sampled a touch into the used slice), then the top hook candidates + cut tray
        // (the extras feed The Read's hook cards and set-aside tray).
        var jobs: [(Int, Double)] = []
        for c in store.order where !jobs.contains(where: { $0.0 == c.sourceSegmentId }) {
            jobs.append((c.sourceSegmentId, c.inPoint + 0.3))
        }
        let extras = store.plan.segments
            .sorted { $0.hookScore > $1.hookScore }.prefix(3).map(\.id) + store.cutTray
        for id in extras where !jobs.contains(where: { $0.0 == id }) {
            if let s = store.segment(id) {
                jobs.append((id, s.startSeconds + min(0.4, max(0, (s.endSeconds - s.startSeconds) / 2))))
            }
        }
        // Bounded concurrency (cap 3) so the decode burst can't spike frames during the reveal. `.task`
        // runs on the MainActor, so assigning `thumbs` after each `group.next()` is main-actor-safe; the
        // child tasks only call the (off-main, cached) generator and return values.
        await withTaskGroup(of: (Int, UIImage?).self) { group in
            let limit = 3
            var iter = jobs.makeIterator()
            var inFlight = 0
            func submitNext() {
                guard let (id, t) = iter.next() else { return }
                inFlight += 1
                group.addTask { (id, await ThumbnailService.thumbnail(for: url, at: t)) }
            }
            for _ in 0..<limit { submitNext() }
            while inFlight > 0, let (id, img) = await group.next() {
                inFlight -= 1
                if let img { thumbs[id] = img }
                submitNext()
            }
        }
    }
}

// MARK: - Retention Map strip (proportional filmstrip; annotations optional)

/// Lays the real assembled spine as a horizontal filmstrip (tile width ∝ clip.timelineDuration).
/// With `annotated: true` (The Read) the viral arc is drawn on the SAME base-second axis: a terracotta
/// scroll-stop flag at the hook, ochre b-roll ticks + lane where `brollLane` sits, and a gold payoff
/// star at the bite/verdict beat — positioned by `xForTime`, a piecewise-linear map from timeline
/// seconds → x, so marks line up with tiles even when a short clip is floored to a minimum width.
/// With `annotated: false` (the Cut Card) it's tiles only — the user's clips, no vocabulary.
/// Tiles are real `View` structs (no `AnyView`). Shared by FirstCutView + BreakdownSheet.
struct RetentionMapStrip: View {
    let store: EditPlanStore
    let thumbs: [Int: UIImage]
    /// Only needed for the annotation layer; the naked card strip passes nil.
    let read: RetentionRead?
    let appeared: Bool
    var annotated: Bool = true
    let onTap: (Clip) -> Void

    private let pps: CGFloat = 22       // points per timeline-second
    private let gap: CGFloat = 3
    private let minTile: CGFloat = 26
    private let tileH: CGFloat = 96
    private let arcH: CGFloat = 22
    private let laneH: CGFloat = 8

    private struct Tile { let clip: Clip; let seg: Segment?; let tStart: Double; let tEnd: Double; let x: CGFloat; let w: CGFloat }

    private var tiles: [Tile] {
        var out: [Tile] = []
        var t = 0.0
        var x: CGFloat = 0
        for clip in store.order {
            let dur = clip.timelineDuration
            let w = max(minTile, CGFloat(dur) * pps)
            out.append(Tile(clip: clip, seg: store.segment(clip.sourceSegmentId),
                            tStart: t, tEnd: t + dur, x: x, w: w))
            x += w + gap
            t += dur
        }
        return out
    }

    private var contentWidth: CGFloat { max(1, (tiles.last.map { $0.x + $0.w }) ?? 1) }

    /// Piecewise-linear timeline-seconds → x, honoring floored tile widths.
    private func xForTime(_ tt: Double) -> CGFloat {
        guard let first = tiles.first else { return 0 }
        if tt <= first.tStart { return first.x }
        for tile in tiles where tt >= tile.tStart && tt <= tile.tEnd {
            let frac = tile.tEnd > tile.tStart ? CGFloat((tt - tile.tStart) / (tile.tEnd - tile.tStart)) : 0
            return tile.x + frac * tile.w
        }
        return contentWidth
    }

    private var payoffTile: Tile? {
        tiles.first { t in
            guard let s = t.seg else { return false }
            return s.sceneType == .biteReaction || s.section == .end
        }
    }

    private var hasBroll: Bool { !store.brollLane.isEmpty }

    var body: some View {
        let topPad: CGFloat = annotated ? arcH + 6 : 0
        let totalH = topPad + tileH + (annotated && hasBroll ? 6 + laneH : 0)
        ScrollView(.horizontal, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // Tiles
                ForEach(Array(tiles.enumerated()), id: \.element.clip.id) { idx, tile in
                    FilmClipTile(seg: tile.seg,
                                 timelineDuration: tile.clip.timelineDuration,
                                 speed: tile.clip.speed,
                                 thumb: tile.seg.flatMap { thumbs[$0.id] },
                                 isHook: annotated && tile.clip.sourceSegmentId == store.hookId)
                        .frame(width: tile.w, height: tileH)
                        .offset(x: tile.x, y: topPad)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.92, anchor: .bottom)
                        .animation(.spring(response: 0.4, dampingFraction: 0.8).delay(Double(idx) * 0.03), value: appeared)
                        .onTapGesture { onTap(tile.clip) }
                }

                if annotated {
                    // Arc rail — scroll-stop flag at the hook tile
                    if let hookTile = tiles.first(where: { $0.clip.sourceSegmentId == store.hookId }) ?? tiles.first {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.veTerracotta)
                            .offset(x: hookTile.x + 2, y: 0)
                            .opacity(appeared ? 1 : 0)
                    }

                    // b-roll ticks on the arc rail
                    ForEach(Array(store.brollLane.enumerated()), id: \.element.id) { _, o in
                        Capsule().fill(Color(hex: 0x9A7350))
                            .frame(width: 3, height: 12)
                            .offset(x: xForTime((o.startOnBase + o.endOnBase) / 2) - 1.5, y: 4)
                            .opacity(appeared ? 1 : 0)
                    }

                    // Payoff star
                    if let p = payoffTile {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color(hex: 0xE8B65E))
                            .offset(x: min(contentWidth - 12, xForTime((p.tStart + p.tEnd) / 2) - 6), y: 0)
                            .scaleEffect(appeared ? 1 : 0.3)
                            .animation(.spring(response: 0.45, dampingFraction: 0.6).delay(Double(tiles.count) * 0.03 + 0.1), value: appeared)
                    }

                    // b-roll lane beneath the strip
                    if hasBroll {
                        ForEach(Array(store.brollLane.enumerated()), id: \.element.id) { _, o in
                            let x0 = xForTime(o.startOnBase)
                            let x1 = xForTime(o.endOnBase)
                            Capsule().fill(Color(hex: 0x9A7350).opacity(0.85))
                                .frame(width: max(3, x1 - x0), height: laneH)
                                .offset(x: x0, y: topPad + tileH + 6)
                                .opacity(appeared ? 1 : 0)
                        }
                    }
                }
            }
            .frame(width: contentWidth, height: totalH, alignment: .topLeading)
            .padding(.trailing, 8)
        }
        .mask(
            LinearGradient(colors: [.black, .black, .black, .black.opacity(0.35)],
                           startPoint: .leading, endPoint: .trailing)
        )
    }
}

/// One clip in the filmstrip: real thumbnail (or FoodTile), a duration chip, an optional ★HOOK pennant
/// (annotated strip only), and a speed badge when the clip isn't at 1×. A real `View` struct (never
/// `AnyView`) so scrolling stays smooth.
struct FilmClipTile: View {
    let seg: Segment?
    let timelineDuration: Double
    let speed: Double
    let thumb: UIImage?
    let isHook: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumb {
                Image(uiImage: thumb).resizable().scaledToFill()
            } else {
                FoodTile(tone: (seg?.sceneType ?? .unknown).foodTone, cornerRadius: 10)
            }
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .bottom, endPoint: .center)

            Text("\(Int(timelineDuration.rounded()))s")
                .font(VeFont.sans(9, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)

            if isHook {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").font(.system(size: 7, weight: .bold))
                    Text("HOOK").font(VeFont.sans(8, weight: .bold)).tracking(0.3)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.veTerracotta, in: Capsule())
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if abs(speed - 1) > 0.01 {
                Text(String(format: "%.1f×", speed))
                    .font(VeFont.sans(9, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.5), in: Capsule())
                    .padding(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white.opacity(0.5), lineWidth: 0.5))
    }
}
