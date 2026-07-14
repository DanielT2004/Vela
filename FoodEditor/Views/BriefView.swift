import SwiftUI
import UIKit

/// The per-video brief — "Before we cut · Anything special for this one?". Gated between the
/// picker and processing so the creator confirms what THIS video needs before the slow, paid analysis.
///
/// **Radically collapsed by design (2026-07-14 beta simplicity pass; target user = casual creator, not
/// pros).** Four plain questions, no fold: TARGET LENGTH and the voiceover intent (the two with no safe
/// default — voiceover is genuinely bimodal, narration-led vs talking-led cut very differently), the
/// screen-time lean while talking (defaulted, one dynamic explainer line), and the free-text note — the
/// universal "off-vibes" escape valve (`BriefPromptBuilder` honors anything typed there, including
/// specific hook ideas). Everything else was REMOVED from the UI outright: opener chips, keep-beats
/// chips, and the trim toggle (the note covers the first two better; trim is just always-on now via
/// `EditBrief.trimSlowParts` default `true`). An untouched screen submits the same `EditBrief()`
/// defaults, so the prompt block is byte-identical to before (a template-prefilled `hookSequence` stays
/// inert while `maxScrollStopHook` is true, and nothing in the UI can flip it; see
/// [BriefPromptBuilder](FoodEditor/Services/BriefPromptBuilder.swift)). Zero model/prompt changes.
struct BriefView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(TemplateService.self) private var templates

    @State private var brief = EditBrief()
    @State private var didLoad = false
    @State private var swapOpen = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if templates.active != nil { templateRow.padding(.top, 20) }
                    footageSection.padding(.top, 22)
                    lengthSection.padding(.top, 24)
                    voiceoverPlanToggle.padding(.top, 10)
                    section("While you're talking") { leanSection }
                    section("Anything specific? (optional)") { noteField }
                }
                .padding(.horizontal, 22)
                .padding(.top, 52)
                .padding(.bottom, 18)
            }
            .scrollDismissesKeyboard(.interactively)
            submitBar
        }
        .background(Color.veCream.ignoresSafeArea())
        .onAppear {
            guard !didLoad else { return }
            brief = EditBrief.prefilled(from: templates.active)
            didLoad = true
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackChevronButton { router.back() }
                .padding(.bottom, 18)
            Text("BEFORE WE CUT")
                .font(VeFont.sans(12, weight: .bold)).tracking(0.7)
                .foregroundStyle(Color.veTerracotta)
            Text("Anything special\nfor this one?")
                .font(VeFont.serif(29))
                .foregroundStyle(Color.veCharcoal)
                .padding(.top, 6)
            Text(templates.active == nil
                 ? "We've set good defaults — just check the length."
                 : "Everything's set to your usual style. Change what matters for this one — or just send it.")
                .font(VeFont.sans(13.5))
                .foregroundStyle(Color.veWarmGray)
                .lineSpacing(2)
                .padding(.top, 7)
            Text("\(session.clips.count) clip\(session.clips.count == 1 ? "" : "s") · \(session.totalDurationText)")
                .font(VeFont.sans(12))
                .foregroundStyle(Color.veFaintGray)
                .padding(.top, 4)
        }
    }

    // MARK: template row (compact; hidden entirely when no template — no "empty style" advertising)

    private var templateRow: some View {
        let dark = Color(hex: 0x1C1A18)
        let ochre = Color(hex: 0xE8B65E)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(ochre)
                    .frame(width: 32, height: 32)
                    .background(ochre.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("CUTTING IN YOUR STYLE")
                        .font(VeFont.sans(10, weight: .bold)).tracking(0.6)
                        .foregroundStyle(ochre)
                    Text(templates.active?.name ?? "")
                        .font(VeFont.sans(15, weight: .bold))
                        .foregroundStyle(Color.veCream)
                }
                Spacer(minLength: 6)
                if templates.templates.count > 1 {
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { swapOpen.toggle() }
                    } label: {
                        Text(swapOpen ? "Done" : "Swap")
                            .font(VeFont.sans(13, weight: .bold))
                            .foregroundStyle(dark)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(ochre, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            if swapOpen {
                VStack(spacing: 8) {
                    ForEach(templates.templates) { t in
                        templateOption(t, ochre: ochre)
                    }
                }
                .padding(.top, 12)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func templateOption(_ t: StyleTemplate, ochre: Color) -> some View {
        let active = t.id == templates.activeId
        return Button { selectTemplate(t) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.name).font(VeFont.sans(14, weight: .bold)).foregroundStyle(Color.veCream)
                    Text("\(t.count) video\(t.count == 1 ? "" : "s") · \(t.lenLabel)")
                        .font(VeFont.sans(11.5)).foregroundStyle(Color.veCream.opacity(0.55))
                }
                Spacer(minLength: 6)
                if active {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Color(hex: 0x1C1A18))
                        .frame(width: 22, height: 22).background(ochre, in: Circle())
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(active ? ochre.opacity(0.12) : Color.white.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(active ? ochre.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: footage (KEPT — the last visual confirmation before the paid, slow analysis)

    private var footageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("YOUR FOOTAGE")
                    .font(VeFont.sans(12, weight: .bold)).tracking(0.5).foregroundStyle(Color.veWarmGray)
                Spacer()
                Text("\(session.clips.count) clip\(session.clips.count == 1 ? "" : "s")")
                    .font(VeFont.sans(12.5, weight: .semibold)).foregroundStyle(Color.veFaintGray)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.clips) { clip in
                        ZStack(alignment: .bottomLeading) {
                            if let img = clip.thumbnail {
                                Image(uiImage: img).resizable().scaledToFill()
                            } else {
                                Color.veSurface
                            }
                            LinearGradient(colors: [Color.veCharcoal.opacity(0.6), .clear],
                                           startPoint: .bottom, endPoint: .center)
                            if let d = clip.metadata?.durationText {
                                Text(d).font(VeFont.sans(9, weight: .bold)).foregroundStyle(.white)
                                    .padding(5)
                            }
                        }
                        .frame(width: 62, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: target length (the ONE decision on the visible path)

    private var lengthSection: some View {
        let binding = Binding(get: { Double(brief.lengthSeconds) },
                              set: { brief.lengthSeconds = Int($0) })
        return VStack(alignment: .leading, spacing: 10) {
            Text("HOW LONG?")
                .font(VeFont.sans(12, weight: .bold)).tracking(0.5).foregroundStyle(Color.veWarmGray)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(brief.lengthBandLabel).font(VeFont.serif(22)).foregroundStyle(Color.veTerracotta)
                    Spacer()
                    Text(brief.lengthDisplay).font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal)
                }
                Text(brief.lengthBandMessage)
                    .font(VeFont.sans(12.5)).foregroundStyle(Color.veWarmGray)
                    .lineSpacing(1).frame(minHeight: 34, alignment: .top).padding(.top, 4)
                Slider(value: binding, in: 10...180, step: 5).tint(Color.veTerracotta).padding(.top, 4)
                HStack {
                    lengthTag("Punchy", .punchy)
                    Spacer(); lengthTag("Standard", .standard)
                    Spacer(); lengthTag("Detailed", .detailed)
                    Spacer(); lengthTag("In-depth", .indepth)
                }
                .padding(.top, 4)
                // Contextual, not constant: at the default you're already inside the recommended band —
                // the tip earns its place only once the creator drags long.
                if brief.lengthSeconds > 45 {
                    Text("Most food videos land best around 25–35s.")
                        .font(VeFont.sans(11)).foregroundStyle(Color.veFaintGray)
                        .padding(.top, 10)
                }
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.05), radius: 8, y: 2)
        }
    }

    private func lengthTag(_ text: String, _ band: EditBrief.LengthBand) -> some View {
        let on = brief.lengthBand == band
        return Text(text)
            .font(VeFont.sans(10.5, weight: on ? .bold : .semibold))
            .foregroundStyle(on ? Color.veTerracotta : Color.veFaintGray)
    }

    // MARK: note (promoted — the universal escape valve)

    private var noteField: some View {
        TextField("e.g. keep the part where I show the price",
                  text: $brief.note, axis: .vertical)
            .font(VeFont.sans(14))
            .foregroundStyle(Color.veCharcoal)
            .lineLimit(3...6)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.veCharcoal.opacity(0.12), lineWidth: 1.5))
    }

    // MARK: while you're talking (screen-time lean over talking segments)

    /// The grid + a dynamic explainer (the length card's band-message pattern). The load-bearing fact
    /// it teaches: the creator's LIVE audio never changes — this only sets how much food b-roll plays
    /// OVER the talking (Layer 2 silent overlays; talking clips stay on the spine with their sound).
    private var leanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            leanGrid
            Text(leanMessage)
                .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeOut(duration: 0.15), value: brief.brollLean)
        }
    }

    private var leanMessage: String {
        switch brief.brollLean {
        case .onCamera:   return "Your face carries it — food shots only where they really punch."
        case .balanced:   return "You on camera for the big moments, food shots over the rest."
        case .brollHeavy: return "You keep talking — the screen shows the food while your voice runs under it."
        }
    }

    private var leanGrid: some View {
        grid(BrollLean.allCases.map(\.label), columns: 3,
             selected: index(of: brief.brollLean, in: BrollLean.allCases)) { brief.brollLean = BrollLean.allCases[$0] }
    }

    /// Narration recorded IN Vela after the cut (Polish → Voiceover tool) — pre-set from the template's
    /// learned voiceover habits; steers the cut toward visual flow and pre-arms the Polish nudge.
    private var voiceoverPlanToggle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("I'll add a voiceover after")
                    .font(VeFont.sans(14, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                Text("We'll favor action shots over talking — you record over the finished cut, right in Vela.")
                    .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $brief.plansVoiceover).labelsHidden().tint(Color.veTerracotta)
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: submit bar

    private var submitBar: some View {
        VStack(spacing: 10) {
            Text(confirmationSummary)
                .font(VeFont.serif(13.5, italic: true))
                .foregroundStyle(Color.veNoteText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryActionButton(title: "Looks good — edit it") { submit() }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(
            Color.veCream
                .shadow(color: Color.veCharcoal.opacity(0.06), radius: 8, y: -3)
                .ignoresSafeArea()
        )
    }

    private var confirmationSummary: String {
        var parts = ["Editing a \(brief.lengthDisplay) video"]
        switch brief.brollLean {
        case .onCamera:  parts.append("staying on camera")
        case .balanced:  break
        case .brollHeavy:parts.append("leaning on food shots")
        }
        if brief.plansVoiceover { parts.append("recording a voiceover") }
        return parts.joined(separator: ", ") + " — sound right?"
    }

    // MARK: reusable section + grid

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(VeFont.sans(12, weight: .bold)).tracking(0.5)
                .foregroundStyle(Color.veWarmGray)
            content()
        }
        .padding(.top, 22)
    }

    private func grid(_ labels: [String], columns: Int, selected: Int, onPick: @escaping (Int) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { idx, label in
                BriefSelectCell(label: label, selected: idx == selected) { onPick(idx) }
            }
        }
    }

    // MARK: actions

    private func selectTemplate(_ t: StyleTemplate) {
        templates.setActive(t.id)
        // Re-seed the usual settings, but preserve what the creator already set for THIS video.
        var seeded = EditBrief.prefilled(from: t)
        seeded.keepBeats = brief.keepBeats
        seeded.trimSlowParts = brief.trimSlowParts
        seeded.note = brief.note
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            brief = seeded
            swapOpen = false
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    private func submit() {
        session.brief = brief
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Log.app("📝 Brief — ~\(brief.lengthSeconds)s · open \(brief.hookSequence.map(\.label)) · lean \(brief.brollLean.label) · voiceover \(brief.plansVoiceover) · keep \(brief.keepBeats.map(\.label)) · trim \(brief.trimSlowParts).")
        router.go(.processing)
    }

    private func index<T: Equatable>(of value: T, in all: [T]) -> Int {
        all.firstIndex(of: value) ?? 0
    }
}

// MARK: - Small building blocks (real View structs — no AnyView in this list-heavy screen)

/// One single-select option cell (terracotta border + tint + corner check when active).
private struct BriefSelectCell: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(VeFont.sans(13.5, weight: .semibold))
                .foregroundStyle(selected ? Color.veTerracotta : Color.veCharcoal)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12).padding(.horizontal, 8)
                .background(selected ? Color.veTerracotta.opacity(0.1) : Color.white,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.veTerracotta : Color.veCharcoal.opacity(0.12), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
