import SwiftUI
import UIKit

/// **"The Read"** — the full breakdown behind the Cut Card. Every analysis section that used to live on
/// the mandatory results page moved here VERBATIM (2026-07-14 simplicity pass): the card shows WHAT we
/// made; this sheet shows WHY it works. Presented with detents `[.fraction(0.55), .large]` — the half
/// height is the taste (annotated map + Our read + length card), a drag up reveals the hook, arc,
/// tuning, set-aside tray, and style notes. Same strict honesty model as ever (`RetentionRead` bands,
/// never fabricated numbers — see the rules in [RetentionRead.swift](FoodEditor/Models/RetentionRead.swift)).
struct BreakdownSheet: View {
    @Environment(AppRouter.self) private var router
    @Environment(TemplateService.self) private var templates
    @Environment(\.dismiss) private var dismiss

    let store: EditPlanStore
    let read: RetentionRead
    let thumbs: [Int: UIImage]
    let proxyURL: URL?

    @State private var setAsideOpen = false
    @State private var preview: SlicePreview?
    /// Presenters that already hold thumbnails (Cut Card, deck) pass them in; the editor shell passes
    /// `[:]` and the sheet loads its own here — same cached `ThumbnailService`, so re-opens are free.
    @State private var loadedThumbs: [Int: UIImage] = [:]

    private var allThumbs: [Int: UIImage] { thumbs.isEmpty ? loadedThumbs : thumbs }

    /// A [start,end] proxy slice to preview (from a filmstrip tile or a hook/cut card).
    private struct SlicePreview: Identifiable {
        let id = UUID()
        let start: Double
        let end: Double
        let caption: String
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                mapSection.padding(.top, 18)
                darkSummaryCard.padding(.top, 16)
                viralReadSection
                hookSection
                arcSection
                tunedSection
                if !store.cutTray.isEmpty { setAsideSection }
                styleSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .background(Color.veCream.ignoresSafeArea())
        .task { await loadThumbsIfNeeded() }
        .sheet(item: $preview) { p in
            if let url = proxyURL {
                SlicePlayerSheet(url: url, start: p.start, end: p.end, caption: p.caption)
            }
        }
    }

    private func loadThumbsIfNeeded() async {
        guard thumbs.isEmpty, loadedThumbs.isEmpty, let url = proxyURL else { return }
        var jobs: [(Int, Double)] = []
        for c in store.order where !jobs.contains(where: { $0.0 == c.sourceSegmentId }) {
            jobs.append((c.sourceSegmentId, c.inPoint + 0.3))   // same bucket as the Cut Card's tiles
        }
        let extras = store.plan.segments
            .sorted { $0.hookScore > $1.hookScore }.prefix(3).map(\.id) + store.cutTray
        for id in extras where !jobs.contains(where: { $0.0 == id }) {
            if let s = store.segment(id) {
                jobs.append((id, s.startSeconds + min(0.4, max(0, (s.endSeconds - s.startSeconds) / 2))))
            }
        }
        for (id, t) in jobs {
            if let img = await ThumbnailService.thumbnail(for: url, at: t) { loadedThumbs[id] = img }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("THE ANALYSIS")
                .font(VeFont.sans(11.5, weight: .heavy)).tracking(1.2)
                .foregroundStyle(Color.veTerracotta)
            Text("Why this cut works.")
                .font(VeFont.serif(26))
                .foregroundStyle(Color.veCharcoal)
                .padding(.top, 6)
        }
    }

    // MARK: - The Retention Map (annotated — the flags/stars/legend live HERE, not on the Cut Card)

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("THE RETENTION MAP")
                    .font(VeFont.sans(11.5, weight: .heavy)).tracking(0.7)
                    .foregroundStyle(Color.veTerracotta)
                Rectangle().fill(Color.veTerracotta.opacity(0.22)).frame(height: 1)
                Text("\(store.order.count)")
                    .font(VeFont.sans(11, weight: .bold)).foregroundStyle(Color.veWarmGray)
            }

            RetentionMapStrip(store: store, thumbs: allThumbs, read: read, appeared: true, annotated: true) { clip in
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                let seg = store.segment(clip.sourceSegmentId)
                preview = SlicePreview(start: clip.inPoint, end: clip.outPoint,
                                       caption: seg?.description ?? "")
            }

            // Legend
            HStack(spacing: 14) {
                legendItem(color: Color.veTerracotta, symbol: "flag.fill", text: "scroll-stop")
                legendItem(color: Color(hex: 0x9A7350), symbol: "rectangle.fill", text: "b-roll")
                legendItem(color: Color(hex: 0xE8B65E), symbol: "star.fill", text: "payoff")
                Spacer()
            }

            Text(read.shapeLine)
                .font(VeFont.serif(14.5, italic: true))
                .foregroundStyle(Color.veNoteText)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(store.order.count) clips · b-roll \(read.brollLabel) · tap any to preview")
                .font(VeFont.sans(11.5))
                .foregroundStyle(Color.veWarmGray)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.06), radius: 10, y: 3)
    }

    private func legendItem(color: Color, symbol: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(color)
            Text(text).font(VeFont.sans(10.5, weight: .semibold)).foregroundStyle(Color.veFaintGray)
        }
    }

    // MARK: - Dark summary card

    private var darkSummaryCard: some View {
        let dark = Color(hex: 0x1C1A18)
        let ochre = Color(hex: 0xE8B65E)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(read.lengthTitle)
                    .font(VeFont.serif(30)).foregroundStyle(Color.veCream)
                if !read.targetTitle.isEmpty {
                    Text(read.targetTitle)
                        .font(VeFont.sans(12.5, weight: .semibold)).foregroundStyle(ochre)
                }
                Spacer()
                Text(read.onTarget ? "on target" : "our target")
                    .font(VeFont.sans(11, weight: .bold))
                    .foregroundStyle(ochre)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .overlay(Capsule().stroke(ochre.opacity(0.5), lineWidth: 1))
            }
            lengthBar(ochre: ochre)
            HStack(spacing: 8) {
                darkStat("KEPT", "\(read.keptCount)", ochre)
                darkStat("B-ROLL", read.brollLabel.capitalized, ochre)
                darkStat("SET ASIDE", "\(read.setAsideCount)", ochre)
            }
            Text("Long enough to land the story, short enough that people finish — finishing is what the feed rewards.")
                .font(VeFont.sans(12)).foregroundStyle(Color.veCream.opacity(0.82)).lineSpacing(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func lengthBar(ochre: Color) -> some View {
        let span = max(read.totalDuration, read.targetDuration, 1)
        let fill = max(0.02, read.totalDuration / span)
        let target = read.targetDuration > 0 ? read.targetDuration / span : nil
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.veCream.opacity(0.14)).frame(height: 6)
                Capsule().fill(ochre).frame(width: geo.size.width * fill, height: 6)
                if let target {
                    Rectangle().fill(Color.veCream.opacity(0.55))
                        .frame(width: 1.5, height: 12)
                        .offset(x: geo.size.width * target - 0.75)
                }
            }
            .frame(height: 12)
        }
        .frame(height: 12)
    }

    private func darkStat(_ label: String, _ value: String, _ ochre: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(VeFont.serif(19)).foregroundStyle(Color.veCream)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(VeFont.sans(9.5, weight: .bold)).tracking(0.5).foregroundStyle(ochre.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Our read (four-lever evidence, beneath the picture)

    private var viralReadSection: some View {
        section("Our read") {
            VStack(alignment: .leading, spacing: 10) {
                Text("our read of your footage — not a prediction")
                    .font(VeFont.serif(13, italic: true)).foregroundStyle(Color.veNoteText)
                HStack(spacing: 10) {
                    ReadCell(icon: "bolt.fill", label: "SCROLL-STOP", band: read.scrollStop.shortLabel,
                             line: read.hookWhy, tint: Color.veTerracotta)
                    ReadCell(icon: "waveform", label: "PACE", band: read.pace.word,
                             line: read.pace.line, tint: Color.veTerracotta)
                }
                HStack(spacing: 10) {
                    ReadCell(icon: "timer", label: "LENGTH", band: read.lengthTitle,
                             line: read.length.line, tint: Color.veSage)
                    ReadCell(icon: "checkmark.seal.fill", label: "PAYOFF", band: read.payoff.chip,
                             line: read.payoff.line, tint: Color(hex: 0x9A7350))
                }
            }
        }
    }

    // MARK: - The Hook (crowned scroll-stopper)

    private var hookSection: some View {
        let candidates = Array(
            store.plan.segments
                .sorted { ($0.hookScore, $1.startSeconds) > ($1.hookScore, $0.startSeconds) }
                .prefix(3)
        )
        let winner = store.hookId.flatMap { store.segment($0) } ?? candidates.first
        return section("The hook") {
            VStack(alignment: .leading, spacing: 10) {
                if let winner {
                    hookWinnerCard(winner)
                    let runners = candidates.filter { $0.id != winner.id }.prefix(2)
                    if !runners.isEmpty {
                        Text("ALSO CONSIDERED")
                            .font(VeFont.sans(10.5, weight: .bold)).tracking(0.5)
                            .foregroundStyle(Color.veFaintGray)
                            .padding(.top, 2)
                        ForEach(Array(runners)) { seg in runnerRow(seg) }
                    }
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        // Dismiss-then-navigate: RootView remounts on route change, which tears this
                        // sheet's parent down — dismiss first so the transition starts from the card.
                        dismiss()
                        router.go(.hook)
                    } label: {
                        Text("Change the hook →")
                            .font(VeFont.sans(13, weight: .bold))
                            .foregroundStyle(Color.veTerracotta)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func hookWinnerCard(_ seg: Segment) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                thumbView(for: seg, height: 168, corners: .top)
                HStack(spacing: 6) {
                    RankBadge(rank: 1)
                    Spacer()
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill").font(.system(size: 10, weight: .bold))
                        Text("CHOSEN OPENER").font(VeFont.sans(10, weight: .bold)).tracking(0.5)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Color.veTerracotta, in: Capsule())
                }
                .padding(12)
            }
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    SceneChip(text: seg.sceneType.label)
                    Spacer()
                    HookScoreMeter(score: seg.hookScore)
                }
                Text(read.scrollStop.label)
                    .font(VeFont.sans(13, weight: .bold)).foregroundStyle(Color.veTerracotta)
                let why = store.plan.recommendedHook.trimmingCharacters(in: .whitespaces)
                if !why.isEmpty {
                    ReasonNote(text: why)
                } else if !seg.description.isEmpty {
                    Text(seg.description)
                        .font(VeFont.sans(14, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.veTerracotta, lineWidth: 2))
        .shadow(color: Color.veTerracotta.opacity(0.24), radius: 16, y: 8)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            preview = SlicePreview(start: seg.startSeconds,
                                   end: seg.trimToSeconds ?? seg.endSeconds,
                                   caption: seg.description)
        }
    }

    private func runnerRow(_ seg: Segment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            thumbView(for: seg, height: 62, width: 46, corners: .all)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    SceneChip(text: seg.sceneType.label)
                    Spacer()
                    HookScoreMeter(score: seg.hookScore, showLabel: false)
                }
                Text(runnerWhy(seg))
                    .font(VeFont.sans(12)).foregroundStyle(Color.veFaintGray)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 5, y: 2)
        .opacity(0.72)
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            preview = SlicePreview(start: seg.startSeconds,
                                   end: seg.trimToSeconds ?? seg.endSeconds,
                                   caption: seg.description)
        }
    }

    private func runnerWhy(_ seg: Segment) -> String {
        if seg.hookScore >= 8 { return "a close call — also a strong opener" }
        if seg.hookScore >= 5 { return "a solid alternative opener" }
        return "a quieter open — lands later"
    }

    // MARK: - The Arc

    private var arcSection: some View {
        section("The arc") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    arcBlock("INTRO", read.introKept, missing: read.missingSections.contains(.intro))
                    arcConnector
                    arcBlock("MIDDLE", read.middleKept, missing: read.missingSections.contains(.middle))
                    arcConnector
                    arcBlock("END", read.endKept, missing: read.missingSections.contains(.end))
                }
                if read.missingSections.isEmpty {
                    Text("A real spine — a setup, the tasting, and a verdict to close. Each stretch does a job.")
                        .font(VeFont.serif(14, italic: true)).foregroundStyle(Color.veNoteText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ReasonNote(text: missingCopy(read.missingSections))
                }
            }
        }
    }

    private func arcBlock(_ label: String, _ count: Int, missing: Bool) -> some View {
        VStack(spacing: 4) {
            Text("\(count)").font(VeFont.serif(20))
                .foregroundStyle(missing ? Color(hex: 0x9A7350) : Color.veCharcoal)
            Text(label).font(VeFont.sans(10, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color.veWarmGray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.veSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(missing ? Color(hex: 0x9A7350).opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    private var arcConnector: some View {
        Rectangle().fill(Color.veTerracotta.opacity(0.4)).frame(width: 10, height: 1.5)
    }

    private func missingCopy(_ missing: [VideoSection]) -> String {
        let names = missing.map { $0.label.lowercased() }.joined(separator: " & ")
        return "No \(names) kept — worth checking you didn't lose that beat."
    }

    // MARK: - How we tuned it

    private var tunedSection: some View {
        section("How we tuned it") {
            VStack(spacing: 0) {
                if read.secondsTrimmed > 0 {
                    tuneRow("scissors", "Trimmed slow lead-ins", "every second earns its place",
                            "−\(read.secondsTrimmed)s")
                    tuneDivider
                }
                tuneRow("waveform.path", "Pacing", "shots turn over to reset attention",
                        read.pace.word)
                tuneDivider
                if read.broll != .none {
                    tuneRow("rectangle.on.rectangle", "B-roll over the talk", "the eye never stalls on a face",
                            read.brollLabel.capitalized)
                    tuneDivider
                }
                tuneRow("crop", "Reframed to 9:16", "food fills the phone", "All")
            }
            .padding(4)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.05), radius: 6, y: 2)

            // Honest about a light b-roll result — it's footage-bound, not a miss, and hand-editable.
            // When the creator EXPLICITLY asked high and the footage couldn't deliver, say so in their
            // terms — the override must never read as ignored.
            if read.brollAskShortfall {
                ReasonNote(text: "You asked for more b-roll than this footage offers — every usable shot is on the shelf in Polish. Want more next time? Shoot extra food close-ups and cutaways.")
            } else if read.brollIsLight {
                ReasonNote(text: "B-roll is light on this cut — that's down to how much food-cutaway footage there was to layer over the talking. Want more? Add food shots over any clip in Polish.")
            }
        }
    }

    private func tuneRow(_ icon: String, _ title: String, _ subtitle: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.veTerracotta)
                .frame(width: 34, height: 34)
                .background(Color.veSurface, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                Text(subtitle).font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
            }
            Spacer()
            Text(value).font(VeFont.sans(14, weight: .bold)).foregroundStyle(Color.veTerracotta)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
    }

    private var tuneDivider: some View {
        Rectangle().fill(Color.veCharcoal.opacity(0.06)).frame(height: 1).padding(.horizontal, 10)
    }

    // MARK: - What we set aside

    private var setAsideSection: some View {
        section("What we set aside") {
            VStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { setAsideOpen.toggle() }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(store.cutTray.count) moment\(store.cutTray.count == 1 ? "" : "s") set aside")
                                .font(VeFont.sans(14, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                            Text("Nothing deleted — restore any in the editor.")
                                .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray)
                        }
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.veWarmGray)
                            .rotationEffect(.degrees(setAsideOpen ? 180 : 0))
                    }
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .shadow(color: Color.veCharcoal.opacity(0.05), radius: 5, y: 2)
                }
                .buttonStyle(.plain)

                if setAsideOpen {
                    ForEach(store.cutTray, id: \.self) { id in
                        if let seg = store.segment(id) { cutCard(seg) }
                    }
                }
            }
        }
    }

    private func cutCard(_ seg: Segment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            thumbView(for: seg, height: 60, width: 44, corners: .all).opacity(0.7)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    SceneChip(text: seg.sceneType.label)
                    if seg.isLowConfidence {
                        Text("⚠ review")
                            .font(VeFont.sans(10, weight: .bold))
                            .foregroundStyle(Color(hex: 0x9A7350))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color(hex: 0x9A7350).opacity(0.12), in: Capsule())
                    }
                }
                if !seg.description.isEmpty {
                    Text(seg.description)
                        .font(VeFont.sans(12.5)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                }
                if !seg.editNote.isEmpty {
                    Text(seg.editNote).font(VeFont.sans(11.5)).foregroundStyle(Color.veNoteText).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.veNote, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            preview = SlicePreview(start: seg.startSeconds,
                                   end: seg.trimToSeconds ?? seg.endSeconds,
                                   caption: seg.description)
        }
    }

    // MARK: - Your style (conditional)

    /// The AI's style accountability note, PLUS the cut-time bridges for habits Vela can't auto-apply:
    /// supplied-footage habits (e.g. the borrowed-clip montage) point at the manual Polish path, and a
    /// written text signature says it's pre-loaded in the text tool. Template-driven, zero prompt cost —
    /// celebration in the Reveal must never end in silence at cut time.
    @ViewBuilder
    private var styleSection: some View {
        let notes = (store.plan.styleMatchNotes ?? "").trimmingCharacters(in: .whitespaces)
        let suppliedHabits = templates.active?.habits.filter {
            $0.kind == HabitKind.suppliedFootage && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
        } ?? []
        let textLine = templates.active?.profile.verbalStyle.recurringLines.first {
            $0.medium == "text-overlay" && $0.confirmation != "out" && !$0.quote.isEmpty
        }
        if !notes.isEmpty || !suppliedHabits.isEmpty || textLine != nil {
            section("Your style") {
                VStack(alignment: .leading, spacing: 10) {
                    if !notes.isEmpty { ReasonNote(text: notes) }
                    ForEach(suppliedHabits) { habit in
                        ReasonNote(text: "Your videos usually include “\(habit.label)” — Vela can't auto-build that yet. Add those clips yourself in the editor.")
                    }
                    if let line = textLine {
                        ReasonNote(text: "Your on-screen text signature (“\((line.pattern?.isEmpty == false ? line.pattern! : line.quote))”) is pre-loaded in the editor's text tool.")
                    }
                }
            }
        }
    }

    // MARK: - Section helper (mirrors BriefView)

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(VeFont.sans(12, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color.veWarmGray)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 24)
    }

    // MARK: - Thumbnails

    private enum ThumbCorners { case top, all }

    private func thumbView(for seg: Segment, height: CGFloat, width: CGFloat? = nil,
                           corners: ThumbCorners) -> some View {
        let shape: AnyShape = corners == .top
            ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                              bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous))
            : AnyShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        return ZStack {
            if let img = allThumbs[seg.id] {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                FoodTile(tone: seg.sceneType.foodTone, cornerRadius: corners == .top ? 0 : 11)
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipShape(shape)
    }
}

// MARK: - Read cell (one of the four read levers)

struct ReadCell: View {
    let icon: String
    let label: String
    let band: String
    let line: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                Text(label).font(VeFont.sans(10.5, weight: .bold)).tracking(0.5)
                    .foregroundStyle(Color.veWarmGray)
            }
            Text(band).font(VeFont.sans(14.5, weight: .bold)).foregroundStyle(Color.veCharcoal)
            Text(line).font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.veCharcoal.opacity(0.06), lineWidth: 1))
    }
}
