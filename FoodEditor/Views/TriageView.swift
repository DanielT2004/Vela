import SwiftUI
import UIKit
import Observation

private enum TriageAction { case keep, cut, hook, broll }

/// The front card's playback position, fed by `LoopingPlayerView.onTime` (~10Hz). A tiny
/// `@Observable` box so ONLY the leaf views that read `seconds` in their body (the footage bar's
/// playhead + the trim-zone pill) re-render on each tick — never the whole card.
@Observable final class PlaybackClock {
    var seconds: Double = 0
}

/// A clip's current standing in the live edit — drives the synced Sort card's styling so the deck
/// reflects exactly what Arrange/Polish show (hook outlined, B-roll tinted, cut dimmed).
enum ClipStatus { case hook, broll, cut, normal }

/// Ochre accent for the B-roll action (distinct from cut's terracotta and keep's sage).
private let veBrollTone = Color(hex: 0x9A7350)

/// Duration with a decimal under 10s — the words must agree with the footage bar's geometry
/// ("1s of 3s" drawn at 44% reads as a contradiction; "1.4s of 3.2s" doesn't).
private func fmtDur(_ d: Double) -> String {
    d < 10 ? String(format: "%.1fs", d) : "\(Int(d.rounded()))s"
}

/// The AI's single recommendation for a segment, surfaced on each Triage card so the creator can
/// decide fast — while keeping the final say. Derived purely from fields Gemini already returns.
private enum AIVerdict {
    case cut, unsure, broll, voiceover, strongKeep, keeper

    init(_ seg: Segment) {
        // confidence 0 = a coverage-fill segment the AI never analyzed (EditPlanRepair.fillCoverageGaps)
        // — "Your call", never "Suggested cut" (there is no suggestion to show).
        if !seg.keep { self = seg.confidence <= 0 ? .unsure : .cut }
        else if seg.isLowConfidence { self = .unsure }
        else if seg.sceneType == .foodCloseup { self = .broll }
        else if seg.voiceoverCandidate { self = .voiceover }
        else if seg.hookScore >= 7.5 { self = .strongKeep }
        else { self = .keeper }
    }

    var label: String {
        switch self {
        case .cut:        return "Suggested cut"
        case .unsure:     return "Your call"
        case .broll:      return "Good for B-roll"
        case .voiceover:  return "Good for voiceover"
        case .strongKeep: return "Strong keep"
        case .keeper:     return "Keeper"
        }
    }

    var icon: String {
        switch self {
        case .cut:        return "scissors"
        case .unsure:     return "questionmark.circle.fill"
        case .broll:      return "square.on.square"
        case .voiceover:  return "mic.fill"
        case .strongKeep: return "star.fill"
        case .keeper:     return "checkmark"
        }
    }

    var tone: Color {
        switch self {
        case .cut, .voiceover:     return .veTerracotta
        case .unsure, .broll:      return veBrollTone        // ochre
        case .strongKeep, .keeper: return .veSage
        }
    }

    /// Resting lean for the front card: -1 = cut (left), +1 = keep (right), 0 = neutral/down.
    var lean: CGFloat {
        switch self {
        case .cut:                             return -1
        case .unsure, .broll:                  return 0
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
        case .broll:
            return seg.editNote.isEmpty ? "A clean food shot — great as overlay B-roll. Swipe down." : seg.editNote
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
/// The front card always auto-plays its slice (with sound) so you watch before deciding — the deck's
/// core promise; a quiet look lives in the tap-to-preview sheet. (The old Autoplay on/off toggle was
/// removed 2026-07-14: a viewing preference that degraded decisions to thumbnail guesses, and the
/// trigger surface of the beta's player-lifecycle bug.) Each action gives visual + haptic feedback
/// and mutates the shared `EditPlanStore`.
struct TriageView: View {
    @Environment(VideoSession.self) private var session
    @Environment(AppRouter.self) private var router

    @State private var triageIndex = 0
    @State private var dragOffset: CGSize = .zero
    @State private var thumbs: [Int: UIImage] = [:]
    @State private var showCutTray = false
    @State private var previewSegment: Segment?
    @State private var flash: TriageAction?
    /// "The Read" presented from the done-card's built-on link (same sheet as the Cut Card's lip).
    @State private var showBreakdown = false
    /// First-deck teaching: the swipe instruction line shows on the first two decks ever, then never.
    @AppStorage("veFirstDeckHints") private var firstDeckHints = 0
    /// The deck order, **frozen on appear** (see `buildDeck`). Derived from the live edit so Sort shows
    /// the current cut — but captured once so swiping (which mutates the store) can't reshuffle mid-pass.
    @State private var deckIds: [Int] = []

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    /// Every segment as a card, grouped into the AI's **content sections** by `topic` (all the
    /// chicken-sandwich clips together, the fries together, …) so the creator swipes section-by-section
    /// instead of through jumbled footage. Sections order by upload appearance and stay chronological
    /// within; an untagged plan falls back to plain chronological order (see `TopicGrouping`). Each card
    /// still shows the AI's verdict + live status; swiping keeps/cuts the clip without reshuffling the
    /// deck (it's frozen into `deckIds` on appear by buildDeck()).
    private var liveDeckIds: [Int] {
        guard let store else { return [] }
        let chrono = store.plan.segments.sorted { $0.startSeconds < $1.startSeconds }.map(\.id)
        return TopicGrouping.groupedOrder(chrono, segmentsById: store.segmentsById)
    }

    /// The content-section the current card belongs to (its `topic`), or "" when untagged.
    private var currentSection: String { currentSegment.map(TopicGrouping.sectionLabel) ?? "" }

    private var queue: [Segment] {
        (deckIds.isEmpty ? liveDeckIds : deckIds).compactMap { store?.segment($0) }
    }
    private var isDone: Bool { triageIndex >= queue.count }
    private var currentSegment: Segment? { isDone ? nil : queue[triageIndex] }

    /// Freeze the deck order from the current edit. Called on appear so the deck is stable for the swipe
    /// session while each card still reflects live status/range.
    private func buildDeck() {
        deckIds = liveDeckIds
        if triageIndex > deckIds.count { triageIndex = deckIds.count }
        if firstDeckHints <= 2 { firstDeckHints += 1 }   // teaching line retires after the second deck
    }

    /// Restore a cut clip and make it the **front card** so the user can immediately re-edit it. The clip
    /// goes back onto the spine (Kept) and is inserted at the current `triageIndex`, so restoring several
    /// in a row stacks them newest-first (C, B, A) ahead of the previously-current card. The Cut Tray
    /// stays open (the row just leaves `cutTray`) so multiple clips can be restored in one pass.
    private func restoreToFront(_ id: Int) {
        store?.restore(id)
        deckIds.removeAll { $0 == id }
        deckIds.insert(id, at: min(triageIndex, deckIds.count))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// 🔒 Sort is the RAW-footage layer: every card (and its preview sheet) plays the segment's FULL
    /// bounds — never an AI trim or a live spine trim. A trim once hid the exact moment a card's
    /// description promised (the "thumbs up" bug: footage past `trim_to_seconds` was unwatchable
    /// anywhere in the app). The creator must be able to watch every second before deciding; trims are
    /// shown by the footage bar and applied only at commit.
    private func range(_ segId: Int) -> (start: Double, end: Double) {
        let s = store?.segment(segId)
        return (s?.startSeconds ?? 0, s?.endSeconds ?? 0)
    }

    // MARK: trim keep-mode (the footage-bar toggle)

    /// Per-card "what does keep include" override for trimmed segments, set by the card's
    /// Best-part/Full-clip picker. nil = derive from the live spine clip (full-span → full clip,
    /// else Vela's pick).
    @State private var keepModeOverrides: [Int: Bool] = [:]

    /// Whether a keep-swipe on this segment commits the FULL clip (true) or Vela's pick (false).
    private func keepsFullClip(_ seg: Segment) -> Bool {
        if let choice = keepModeOverrides[seg.id] { return choice }
        guard let clip = store?.order.first(where: { $0.sourceSegmentId == seg.id }) else { return false }
        return abs(clip.inPoint - seg.startSeconds) < 0.05 && abs(clip.outPoint - seg.endSeconds) < 0.05
    }

    private func setKeepMode(_ seg: Segment, full: Bool) {
        guard keepsFullClip(seg) != full else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            keepModeOverrides[seg.id] = full
        }
    }

    /// The clip's current standing in the edit (drives card styling).
    private func status(_ segId: Int) -> ClipStatus {
        if store?.hookId == segId { return .hook }
        if store?.brollClips.contains(segId) == true { return .broll }
        if store?.cutTray.contains(segId) == true { return .cut }
        return .normal
    }

    /// Whether the inline front-card player should be running (paused while a sheet covers it).
    private var playerActive: Bool { previewSegment == nil && !showCutTray }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                progressHeader
                sectionBanner
                    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: currentSection)
                // The AI-reset shortcut only on the very first pass — once you've edited, hide it so a
                // stray tap can't wipe your work ("Re-sort everything" is the deliberate path for that).
                if !isDone && session.furthestStage == .sort { acceptPicksBanner }
                deck
                actionButtons
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if showCutTray { cutTraySheet }
        }
        .background(Color.veCream.ignoresSafeArea())
        .onAppear(perform: buildDeck)
        .task { await loadThumbnails() }
        .sheet(item: $previewSegment) { seg in
            if let proxyURL {
                let r = range(seg.id)
                SlicePlayerSheet(url: proxyURL, start: r.start, end: r.end, caption: seg.description)
            }
        }
        .sheet(isPresented: $showBreakdown) {
            if let store {
                BreakdownSheet(store: store,
                               read: RetentionRead(plan: store.plan, store: store, brief: session.brief),
                               thumbs: thumbs, proxyURL: proxyURL)
                    .presentationDetents([.fraction(0.55), .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var progressHeader: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(isDone ? "All sorted" : "Reviewing · \(min(triageIndex + 1, queue.count)) of \(queue.count)")
                    .font(VeFont.sans(12.5, weight: .semibold))
                    .foregroundStyle(Color.veWarmGray)
                // First-deck teaching only (counted per deck in buildDeck) — the one-shot hint nudge
                // on the card is the permanent gesture teacher; persistent copy was reading tax.
                if !isDone && firstDeckHints <= 2 {
                    Text("Swipe the card, or tap a button below")
                        .font(VeFont.sans(11))
                        .foregroundStyle(Color.veFaintGray)
                }
            }
            HStack {
                Spacer()
                cutTrayPill
            }
            .padding(.trailing, 22)
        }
        .padding(.bottom, 6)
    }

    /// The Cut Tray entry, relocated from the deleted bottom row (its "Fine-tune" twin was redundant
    /// with the StageSwitcher + done-card) — the reclaimed row is what lets the cards grow.
    private var cutTrayPill: some View {
        Button { withAnimation { showCutTray = true } } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.veWarmGray)
                Text("\(store?.cutTray.count ?? 0)")
                    .font(VeFont.sans(11, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18)
                    .background(Color.veTerracotta, in: Capsule())
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.veSurface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Shows the content-section the current card belongs to; the `.id(currentSection)` swaps it with a
    /// slide-in whenever the creator enters a new section, so they always know "what's this part about".
    @ViewBuilder private var sectionBanner: some View {
        if !isDone, !currentSection.isEmpty {
            SectionPill(label: currentSection)
                .id(currentSection)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
                .padding(.bottom, 6)
        }
    }

    /// The "do the thinking for me" shortcut: apply every AI pick and jump to the timeline.
    private var acceptPicksBanner: some View {
        Button {
            store?.applyAISuggestions()
            Log.app("✨ Accepted all AI suggestions. \(store?.vibeText ?? "")")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { session.editorStage = .arrange }
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
            let cardHeight = max(260, geo.size.height - 18)
            ZStack {
                if isDone {
                    doneCard
                } else if let seg = currentSegment {
                    // The cards "behind" are PLAIN decorative shapes — no video, thumbnail, or chip —
                    // so a second video can never peek out, whatever the clip's size. The deck shows
                    // exactly ONE real, content-bearing card at a time.
                    backPlaceholder(height: cardHeight, inset: 26, yOffset: 18, opacity: 0.45)
                    backPlaceholder(height: cardHeight, inset: 13, yOffset: 9, opacity: 0.75)

                    TriageCardView(segment: seg,
                                   height: cardHeight,
                                   thumbnail: thumbs[seg.id],
                                   status: status(seg.id),
                                   rangeStart: range(seg.id).start,
                                   rangeEnd: range(seg.id).end,
                                   isFront: true,
                                   playerActive: playerActive,
                                   proxyURL: proxyURL,
                                   dragOffset: dragOffset,
                                   keepsFullClip: keepsFullClip(seg),
                                   onSelectKeepMode: { full in setKeepMode(seg, full: full) },
                                   onTapPreview: { previewSegment = seg })
                        .frame(width: geo.size.width)
                        .id(seg.id)   // fresh inline player per segment
                        .gesture(dragGesture(seg))
                }
                if let flash { flashView(flash).zIndex(999) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .padding(.horizontal, 16)   // was 26 — the "dating profile" ask: footage as big as the deck allows
        .padding(.top, 6)
    }

    /// A plain rounded-rectangle card "edge" peeking behind the front card (no content).
    private func backPlaceholder(height: CGFloat, inset: CGFloat, yOffset: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .padding(.horizontal, inset)
            .frame(height: height)
            .offset(y: yOffset)
            .shadow(color: Color.veCharcoal.opacity(0.08), radius: 10, y: 6)
            .allowsHitTesting(false)
    }

    private func flashView(_ action: TriageAction) -> some View {
        let (icon, color): (String, Color) = {
            switch action {
            case .keep:  return ("checkmark", Color.veSage)
            case .cut:   return ("xmark", Color.veTerracotta)
            case .hook:  return ("star.fill", Color.veCharcoal)
            case .broll: return ("square.on.square", veBrollTone)
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

    /// The deck's finish line ACTS instead of talking: for the off-vibes creator this is the end of the
    /// journey, so Export is right here (the store is shared — exporting from Sort renders the same cut
    /// the header's Export would). Facts, not vibe bands, per the honesty model.
    private var doneCard: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.veSage).frame(width: 64, height: 64)
                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            Text("All sorted").font(VeFont.serif(25)).foregroundStyle(Color.veCharcoal)
            Text("All \(deckIds.count) clips sorted — your cut is ~\(Int((store?.totalDuration ?? 0).rounded()))s.")
                .font(VeFont.sans(13.5)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 260)

            PrimaryActionButton(title: "Export my video") {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                router.go(.export)
            }
            .padding(.horizontal, 26)
            .padding(.top, 4)

            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { session.editorStage = .arrange }
            } label: {
                Text("Fine-tune first →")
                    .font(VeFont.sans(13.5, weight: .bold)).foregroundStyle(Color.veCharcoal)
            }
            .buttonStyle(.plain)

            Button { showBreakdown = true } label: {
                Text("See what your cut is built on →")
                    .font(VeFont.sans(12.5, weight: .semibold)).foregroundStyle(Color.veTerracotta)
            }
            .buttonStyle(.plain)
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: action buttons

    private var actionButtons: some View {
        HStack(alignment: .top, spacing: 16) {
            circleButton(systemName: "xmark", label: "Cut", fg: Color.veTerracotta,
                         bg: .white, border: Color.veTerracotta.opacity(0.4), size: 56) {
                if let s = currentSegment { performSwipe(.cut, s) }
            }
            circleButton(systemName: "arrow.up", label: "Hook", fg: .white,
                         bg: Color.veCharcoal, border: .clear, size: 48) {
                if let s = currentSegment { performSwipe(.hook, s) }
            }
            .padding(.top, 4)
            circleButton(systemName: "square.on.square", label: "B-roll", fg: .white,
                         bg: veBrollTone, border: .clear, size: 48) {
                if let s = currentSegment { performSwipe(.broll, s) }
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

            VStack(alignment: .leading, spacing: 3) {
                Text(seg.description.isEmpty ? seg.sceneType.label : seg.description)
                    .font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                    .fixedSize(horizontal: false, vertical: true)  // wrap the FULL AI description; row grows to fit
                    .multilineTextAlignment(.leading)
                Text("\(seg.sceneType.label) · \(Int((seg.endSeconds - seg.startSeconds).rounded()))s")
                    .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
            }
            Spacer(minLength: 0)
            Button { restoreToFront(seg.id) } label: {
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
                else if dy > 110 && abs(dy) > abs(dx) { performSwipe(.broll, seg) }
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
            case .keep:  dragOffset = CGSize(width: 700, height: 60)
            case .cut:   dragOffset = CGSize(width: -700, height: 60)
            case .hook:  dragOffset = CGSize(width: 0, height: -900)
            case .broll: dragOffset = CGSize(width: 0, height: 900)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            // The card commits what the footage bar shows: keep/hook honor the trimmed card's
            // "Vela's cut / full clip" toggle (untrimmed cards always pass full — same bounds).
            let full = keepsFullClip(seg)
            switch action {
            case .keep:
                if seg.hasTrim { store?.keep(seg.id, fullClip: full) } else { store?.keep(seg.id) }
            case .cut:
                store?.cut(seg.id)
            case .hook:
                if seg.hasTrim { store?.setHook(seg.id, fullClip: full) } else { store?.setHook(seg.id) }
            case .broll:
                store?.markBroll(seg.id)
            }
            let mode = seg.hasTrim ? (full ? " [full clip]" : " [Vela's cut]") : ""
            Log.app("Triage \(action)\(mode) → segment \(seg.id) (\(seg.sceneType.label)). \(store?.vibeText ?? "")")
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
        case .broll:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
    let height: CGFloat
    let thumbnail: UIImage?
    /// The clip's current standing in the live edit (hook / B-roll / cut / normal) — drives styling.
    let status: ClipStatus
    /// The segment's FULL bounds — the card always plays every second of its footage (Sort is the
    /// raw-footage layer; the AI trim is shown by the footage bar, never hidden from playback).
    let rangeStart: Double
    let rangeEnd: Double
    let isFront: Bool
    let playerActive: Bool
    let proxyURL: URL?
    let dragOffset: CGSize
    /// Trimmed cards: whether a keep-swipe commits the full clip (true) or Vela's pick (false).
    let keepsFullClip: Bool
    /// The Best-part/Full-clip picker changed (true = full clip).
    let onSelectKeepMode: (Bool) -> Void
    let onTapPreview: () -> Void

    private var isHook: Bool { status == .hook }

    private var showsPlayer: Bool { isFront && proxyURL != nil }
    private var showsHints: Bool { isFront && dragOffset == .zero }
    /// Playback position for the footage-bar playhead + trim-zone pill (one clock per card — the
    /// deck recreates the card per segment via `.id(seg.id)`).
    @State private var clock = PlaybackClock()
    /// Live position feedback only makes sense while the inline player is actually running.
    private var playheadLive: Bool { showsPlayer && playerActive }

    /// One-shot "swipe hint": when the card appears it slides toward its suggested side, then springs
    /// back to rest — a quick preview of the recommended swipe. 0 at rest, →1 at full nudge.
    @State private var hint: CGFloat = 0

    private var verdict: AIVerdict { AIVerdict(segment) }
    /// 1 at rest, fading to 0 as the front card is dragged — so the hint never fights the gesture.
    private var leanFactor: CGFloat {
        guard isFront else { return 0 }
        return max(0, 1 - hypot(dragOffset.width, dragOffset.height) / 120)
    }
    /// The one-shot nudge offset/rotation, gated by `leanFactor` so grabbing the card cancels it.
    /// At rest `hint == 0`, so the card always starts and ends perfectly vertical (no static tilt).
    private var hintX: CGFloat { verdict.lean * 60 * hint * leanFactor }
    private var hintDegrees: Double { Double(verdict.lean) * 5 * Double(hint) * Double(leanFactor) }

    // Status styling — hook outlined, B-roll tinted ochre, cut dimmed (applied on the body).
    private var cardBackground: Color { status == .broll ? veBrollTone.opacity(0.10) : .white }
    private var outlineColor: Color {
        switch status {
        case .hook:  return Color.veTerracotta
        case .broll: return veBrollTone
        default:     return .clear
        }
    }
    private var outlineWidth: CGFloat {
        switch status {
        case .hook:  return 3
        case .broll: return 2
        default:     return 0
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            hero
            footer
        }
        // Lock to an EXACT height and clip to it *here* (inside the card), so no matter the video
        // aspect or caption/reason length the content can never render outside the card and overlap
        // a neighbour. This is the fix for the deck-overlap regression.
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Status outline: hook → terracotta, B-roll → ochre, so the deck reads at a glance.
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(outlineColor, lineWidth: outlineWidth)
        )
        .opacity(status == .cut ? 0.62 : 1)
        .shadow(color: Color.veCharcoal.opacity(0.16), radius: 18, y: 14)
        .offset(x: dragOffset.width + hintX, y: dragOffset.height)
        .rotationEffect(.degrees(Double(dragOffset.width) * 0.04 + hintDegrees))
        .onTapGesture { onTapPreview() }
        .onAppear(perform: playHint)
    }

    /// Plays the one-shot swipe-hint nudge (front card with a suggested direction only).
    private func playHint() {
        guard isFront, verdict.lean != 0 else { return }
        withAnimation(.easeInOut(duration: 0.42).delay(0.35)) { hint = 1 }     // slide out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.77) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { hint = 0 }  // spring back
        }
    }

    private var hero: some View {
        ZStack {
            if showsPlayer, let url = proxyURL {
                LoopingPlayerView(url: url,
                                  start: rangeStart,
                                  end: rangeEnd,
                                  isPlaying: playerActive,
                                  onTime: { [clock] t in clock.seconds = t })
            } else if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                FoodTile(tone: segment.sceneType.foodTone, cornerRadius: 0)
            }

            // Wordless trim preview: while the loop plays footage that won't be included ("Best
            // part" selected), the video gently dims — bright = in your video, dimmed = out.
            if segment.hasTrim {
                TrimDimOverlay(segment: segment, keepsFullClip: keepsFullClip,
                               live: playheadLive, clock: clock)
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

            // live swipe badges (while dragging) — on a trimmed card the KEEP badge names the exact
            // amount the swipe commits, so the toggle's meaning is restated at the moment of decision.
            badge(keepBadgeText, color: Color.veSage, rotation: 8, opacity: keepOpacity, alignment: .topTrailing)
            badge("CUT", color: Color.veTerracotta, rotation: -8, opacity: cutOpacity, alignment: .topLeading)
            badge("★ HOOK", color: Color.veCharcoal, rotation: 0, opacity: hookOpacity, alignment: .top)
            badge("↓ B-ROLL", color: veBrollTone, rotation: 0, opacity: brollOpacity, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var directionHints: some View {
        ZStack {
            hintPill("↑ HOOK").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 12)
            hintPill("← CUT").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(.leading, 10)
            hintPill("KEEP →").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 10)
            hintPill("↓ B-ROLL").frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 12)
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
                if status == .broll { tag("B-ROLL", fg: .white, bg: veBrollTone) }
                if status == .cut { tag("CUT", fg: Color.veWarmGray, bg: Color.veSurface) }
                SceneChip(text: segment.sceneType.label)
                if segment.voiceoverCandidate { tag("VO", fg: Color.veTerracotta, bg: Color.veTerracotta.opacity(0.12)) }
                Spacer()
                Text("\(Int((rangeEnd - rangeStart).rounded()))s")
                    .font(VeFont.sans(12.5, weight: .semibold)).foregroundStyle(Color.veWarmGray)
            }
            if segment.hasTrim {
                TrimFootageBar(segment: segment, keepsFullClip: keepsFullClip,
                               live: playheadLive, clock: clock,
                               onSelect: onSelectKeepMode)
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

    /// "KEEP 1.4s" / "KEEP ALL · 3.2s" on trimmed cards; plain "KEEP" otherwise.
    private var keepBadgeText: String {
        guard segment.hasTrim else { return "KEEP" }
        if keepsFullClip { return "KEEP ALL · \(fmtDur(segment.endSeconds - segment.startSeconds))" }
        return "KEEP \(fmtDur((segment.trimToSeconds ?? segment.endSeconds) - segment.startSeconds))"
    }

    private var isVertical: Bool { abs(dragOffset.height) > abs(dragOffset.width) }
    private var keepOpacity: Double { (!isVertical && dragOffset.width > 0) ? min(1, dragOffset.width / 90) : 0 }
    private var cutOpacity: Double { (!isVertical && dragOffset.width < 0) ? min(1, -dragOffset.width / 90) : 0 }
    private var hookOpacity: Double { (isVertical && dragOffset.height < 0) ? min(1, -dragOffset.height / 110) : 0 }
    private var brollOpacity: Double { (isVertical && dragOffset.height > 0) ? min(1, dragOffset.height / 110) : 0 }
}

// MARK: - Trim footage bar

/// The trimmed card's trim strip: a miniature of the segment's footage (sage = the kept window,
/// dim = what's out, one live playhead) over a two-option PICKER — "✨ Best part" (Vela's pick,
/// default) vs "Full clip". The highlighted side is what a keep-swipe commits; there is no other
/// trim state or action anywhere on the card. The card plays the full footage either way.
private struct TrimFootageBar: View {
    let segment: Segment
    let keepsFullClip: Bool
    /// Whether the inline player is running (the playhead only shows then).
    let live: Bool
    let clock: PlaybackClock
    /// The picker changed (true = full clip).
    let onSelect: (Bool) -> Void

    /// One-time coach line on the first trimmed card a user EVER sees (per install), then never again.
    @AppStorage("velaTrimCoachShown") private var coachShown = false
    @State private var showCoach = false

    /// Fraction of the segment Vela keeps (trim point as 0…1 of the full span).
    private var trimFraction: CGFloat {
        let full = segment.endSeconds - segment.startSeconds
        guard full > 0, let t = segment.trimToSeconds else { return 1 }
        return CGFloat(max(0, min(1, (t - segment.startSeconds) / full)))
    }
    /// Current playback position as 0…1 of the full span (reads the clock → 10Hz re-render of this
    /// strip only).
    private var playFraction: CGFloat {
        let full = segment.endSeconds - segment.startSeconds
        guard full > 0 else { return 0 }
        return CGFloat(max(0, min(1, (clock.seconds - segment.startSeconds) / full)))
    }

    private var fullText: String { fmtDur(segment.endSeconds - segment.startSeconds) }
    private var keptText: String {
        fmtDur((segment.trimToSeconds ?? segment.endSeconds) - segment.startSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            bar
            if showCoach {
                Text("Vela picked the best \(keptText) of this clip. Tap Full clip to keep everything.")
                    .font(VeFont.sans(11.5))
                    .foregroundStyle(Color.veNoteText)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            picker
        }
        .onAppear(perform: startCoach)
    }

    /// The footage strip: sage kept window, dim remainder (the boundary IS the cut point), and the
    /// single live playhead gliding with playback. Picking "Full clip" floods the strip sage.
    private var bar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.veFaintGray.opacity(0.35))
                Capsule()
                    .fill(Color.veSage)
                    .frame(width: max(6, keepsFullClip ? w : w * trimFraction))
                if live {
                    RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                        .fill(Color.veCharcoal.opacity(0.75))
                        .frame(width: 2.5, height: 14)
                        .offset(x: max(0, min(w - 2.5, w * playFraction - 1.25)))
                }
            }
        }
        .frame(height: 9)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: keepsFullClip)
    }

    /// The ONLY trim control: two equal options, the highlighted one is what you keep.
    private var picker: some View {
        HStack(spacing: 4) {
            segmentButton(selected: !keepsFullClip, icon: "wand.and.stars",
                          label: "Best part · \(keptText)") { choose(false) }
            segmentButton(selected: keepsFullClip, icon: nil,
                          label: "Full clip · \(fullText)") { choose(true) }
        }
        .padding(3)
        .background(Color.veNote, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func segmentButton(selected: Bool, icon: String?, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(label)
                    .font(VeFont.sans(11.5, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? .white : Color.veNoteText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(selected ? Color.veSage : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func choose(_ full: Bool) {
        dismissCoach()
        onSelect(full)
    }

    /// Show the coach line exactly once per install: flag flips immediately on first appearance so
    /// no other card can show it; the line itself fades out after ~6s or on first picker tap.
    private func startCoach() {
        guard !coachShown else { return }
        coachShown = true
        withAnimation(.easeIn(duration: 0.25)) { showCoach = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { dismissCoach() }
    }

    private func dismissCoach() {
        guard showCoach else { return }
        withAnimation(.easeOut(duration: 0.3)) { showCoach = false }
    }
}

// MARK: - Trim dim overlay (wordless WYSIWYG)

/// While the loop plays footage that won't be included ("Best part" selected), the video gently
/// dims with a small ✂ — bright = in your video, dimmed = out. No text, no pill; the footage
/// itself previews the cut. Reads the clock in its own body so the 10Hz ticks re-render only this
/// overlay, never the whole card. Never shown when "Full clip" is selected (nothing gets trimmed)
/// or while the player is paused/off.
private struct TrimDimOverlay: View {
    let segment: Segment
    let keepsFullClip: Bool
    let live: Bool
    let clock: PlaybackClock

    private var dimmed: Bool {
        guard live, !keepsFullClip, let t = segment.trimToSeconds else { return false }
        return clock.seconds >= t
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(dimmed ? 0.35 : 0)
            Image(systemName: "scissors")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .padding(12)
                .opacity(dimmed ? 1 : 0)
        }
        .animation(.easeInOut(duration: 0.25), value: dimmed)
        .allowsHitTesting(false)
    }
}
