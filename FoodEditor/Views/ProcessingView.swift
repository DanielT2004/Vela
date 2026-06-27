import SwiftUI

/// Screen 3 — Processing. Runs the real pipeline behind the mockup's calm terracotta arc:
/// M2 merge+compress → M3 Gemini analysis. For M3 it shows the RAW Gemini JSON on screen (and logs
/// it to the console) so we can verify response quality before building any editing UI. (M4 will
/// parse it into an Edit Plan and fire a completion notification.)
struct ProcessingView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects
    @Environment(AnalysisCoordinator.self) private var analysis
    @Environment(TemplateService.self) private var templates

    /// Drives the gentle pulse on the notice icon + the blinking badge dot.
    @State private var pulse = false

    /// Frames pulled from the merged proxy, used only on a kill-recovery resume where the original
    /// `SourceClip`s (and their thumbnails) are gone — so the loader shows the real footage, not gradients.
    @State private var proxyThumbs: [UIImage] = []

    /// Loader frames: the picks' own thumbnails when present, else the proxy-derived fallback.
    private var loaderThumbnails: [UIImage] {
        let fromClips = session.clips.compactMap { $0.thumbnail }
        return fromClips.isEmpty ? proxyThumbs : fromClips
    }

    /// B-roll coverage seeding cap: the brief's lean wins, else the active template's learned heaviness,
    /// else a sane default. Makes the "Lean on b-roll" choice tangibly change how much overlay is placed.
    private var brollCoverageTarget: Double {
        session.brief?.brollLean.coverageTarget ?? templates.active?.profile.broll.heaviness ?? 0.25
    }

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()
            switch analysis.phase {
            case .failed(let message):
                errorState(message)
            default:
                // .idle / .running / .done all show the calm working state; on `.done` we hand off to the
                // celebratory reveal (below) instead of rendering a summary inline.
                workingState
            }
        }
        // Idempotent — safe to fire on every (re)mount; the coordinator runs the pipeline at most once
        // per submitted clip set and survives this view disappearing. The active style (if any) is injected.
        .task { analysis.start(session: session, projects: projects,
                               styleBlock: StyleConstraintBuilder.block(for: templates.active),
                               briefBlock: BriefPromptBuilder.block(for: session.brief),
                               brollCoverageTarget: brollCoverageTarget) }
        // Completion → the celebratory reveal is handled centrally in `RootView` (so it also fires from
        // the Home "Processing" card), via its `analysis.phase` observer. Here we just run the loader pulse.
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) { pulse = true }
        }
        // Reopened mid-analysis: the original picks are gone, so seed the loader with frames from the
        // proxy. Keyed to `merged?.url` so it runs once the resumed session rebuilds the proxy.
        .task(id: session.merged?.url) { await loadProxyThumbsIfNeeded() }
    }

    /// Pull a handful of evenly-spaced frames from the merged proxy so the drift loader shows the real
    /// footage on a resumed session (no-op when we already have the picks' thumbnails or no proxy yet).
    private func loadProxyThumbsIfNeeded() async {
        guard proxyThumbs.isEmpty,
              session.clips.compactMap({ $0.thumbnail }).isEmpty,
              let url = session.merged?.url else { return }
        let dur = session.merged?.metadata.duration ?? 0
        let n = 9
        var imgs: [UIImage] = []
        for i in 0..<n {
            let t = dur > 1 ? dur * (Double(i) + 0.5) / Double(n) : Double(i) * 0.4
            if let img = await ThumbnailService.thumbnail(for: url, at: t) { imgs.append(img) }
        }
        if !imgs.isEmpty { proxyThumbs = imgs }
    }

    // MARK: working — "Column drift" loader (Claude Design · Vela Loading 01, Option C)

    private var workingState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 6)

            noticeCard
                .animation(.easeInOut(duration: 0.35), value: analysis.canCloseApp)

            ColumnDriftLoader(thumbnails: loaderThumbnails,
                              progress: analysis.progress)
                .frame(height: 300)
                .padding(.horizontal, 24)

            VStack(spacing: 10) {
                stepBadge
                Text(stageTitle)
                    .font(VeFont.serif(25))
                    .foregroundStyle(Color.veCharcoal)
                    .multilineTextAlignment(.center)
                    .animation(.easeInOut, value: stageTitle)
                Text(stageSubtext)
                    .font(VeFont.sans(13))
                    .foregroundStyle(Color.veWarmGray)
                    .multilineTextAlignment(.center)
                    .contentTransition(.numericText())
                    .animation(.easeInOut, value: stageSubtext)
                if let active = templates.active { styleChip(active.name).padding(.top, 2) }
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 6)
        }
        .padding(.vertical, 28)
    }

    /// The "keep the app open" (compressing) vs "you're free to go" (server) notice card.
    private var noticeCard: some View {
        let closeable = analysis.canCloseApp
        let tint: Color = closeable ? .veSage : .veTerracotta
        return HStack(spacing: 11) {
            ZStack {
                if !closeable {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(tint.opacity(0.4), lineWidth: 2)
                        .frame(width: 34, height: 34)
                        .scaleEffect(pulse ? 1.12 : 1.0)
                        .opacity(pulse ? 1 : 0.5)
                }
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(tint)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: closeable ? "checkmark" : "iphone")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.veOnTerracotta))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(closeable ? "You're free to go" : "Keep Vela open")
                    .font(VeFont.sans(13.5, weight: .heavy))
                    .foregroundStyle(closeable ? Color.veSage : Color(hex: 0x8A3A24))
                Text(closeable ? "Close the app — we'll notify you when it's ready."
                               : "Don't close the app while we prep.")
                    .font(VeFont.sans(11.5))
                    .foregroundStyle(closeable ? Color.veNoteText : Color(hex: 0xA0533C))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(closeable ? Color.veSage.opacity(0.10) : Color(hex: 0xFBEFE9))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(tint.opacity(0.32), lineWidth: 1.5))
        )
        .padding(.horizontal, 24)
    }

    /// "STEP 1 OF 2 · ON YOUR DEVICE" → "STEP 2 OF 2 · ON OUR SERVERS" with a blinking dot.
    private var stepBadge: some View {
        let closeable = analysis.canCloseApp
        let tint: Color = closeable ? .veSage : .veTerracotta
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6).opacity(pulse ? 1 : 0.35)
            Text(closeable ? "STEP 2 OF 2 · ON OUR SERVERS" : "STEP 1 OF 2 · ON YOUR DEVICE")
                .font(VeFont.sans(11, weight: .bold)).tracking(0.5)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.10))
            .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1)))
    }

    private func styleChip(_ name: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill").font(.system(size: 10))
            Text("Cutting in your “\(name)” style").font(VeFont.sans(12.5, weight: .semibold))
        }
        .foregroundStyle(Color.veTerracotta)
        .padding(.horizontal, 13).padding(.vertical, 7)
        .background(Color.veTerracotta.opacity(0.1), in: Capsule())
    }

    private var stageTitle: String {
        switch analysis.stage {
        case .preparing: return "Prepping your footage"
        case .uploading: return "Uploading your footage"
        case .analyzing:  return "Analyzing your footage"
        case .finishing:  return "Putting it together"
        }
    }

    private var stageSubtext: String {
        if analysis.canCloseApp { return "Usually about a minute." }
        if let eta = analysis.etaSeconds { return Self.etaText(eta) }
        return "Hang tight…"
    }

    /// Friendly countdown copy for the prep step.
    private static func etaText(_ s: Int) -> String {
        if s < 10 { return "Almost done…" }
        if s < 60 { return "About \(s)s left" }
        let m = Int((Double(s) / 60).rounded())
        return "About \(m) min left"
    }

    // MARK: done (M4 — decoded summary + raw JSON)
    // NOTE: superseded by `AnalysisRevealView` as the post-analysis screen (we route there on `.done`).
    // Kept (currently unreached) as the raw-JSON inspection aid; safe to delete once no longer needed.

    private func doneState(_ plan: EditPlan, _ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Top bar so the user is never stuck here (this is pre-editor, so NO stage nav bar):
            // Cancel (left) steps back to the picker, Home (right, mockup style) exits to the Kitchen.
            HStack {
                Button("Cancel") { router.back() }
                    .font(VeFont.sans(13, weight: .semibold))
                    .foregroundStyle(Color.veWarmGray)
                Spacer()
                HomeButton { router.home() }
            }
            .padding(.top, 54)
            .padding(.horizontal, 22)

            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 24)).foregroundStyle(Color.veSage)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Analysis ready")
                        .font(VeFont.serif(22)).foregroundStyle(Color.veCharcoal)
                    if let m = session.merged {
                        Text("\(session.clips.count) clips → 1 video · \(m.metadata.fileSizeText) · \(m.metadata.resolutionText)")
                            .font(VeFont.sans(12)).foregroundStyle(Color.veWarmGray)
                    }
                }
                Spacer()
            }
            .padding(.top, 4)
            .padding(.horizontal, 22)

            summaryCard(plan).padding(.horizontal, 22)

            DisclosureGroup {
                ScrollView {
                    Text(raw)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.veCharcoal)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 240)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } label: {
                Text("Raw JSON (\(raw.count) chars)")
                    .font(VeFont.sans(13, weight: .bold))
                    .foregroundStyle(Color.veWarmGray)
            }
            .tint(Color.veTerracotta)
            .padding(.horizontal, 22)

            Spacer(minLength: 0)

            PrimaryActionButton(title: "See the breakdown") { router.go(.segments) }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
        }
    }

    private func summaryCard(_ plan: EditPlan) -> some View {
        let kept = plan.segments.filter { $0.keep }.count
        let vo = plan.segments.filter { $0.voiceoverCandidate }.count
        let lowConf = plan.segments.filter { $0.isLowConfidence }.count
        return VStack(alignment: .leading, spacing: 12) {
            if !plan.videoSummary.isEmpty {
                Text("“\(plan.videoSummary)”")
                    .font(VeFont.serif(16, italic: true))
                    .foregroundStyle(Color(hex: 0x4A453E))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                statPill("\(plan.segments.count)", "segments")
                statPill("\(kept)", "keep")
                statPill("\(vo)", "voiceover")
                if lowConf > 0 { statPill("\(lowConf)", "to review") }
            }
            if !plan.recommendedHook.isEmpty {
                metaLine("Hook", plan.recommendedHook)
            }
            metaLine("Suggested length", "\(Int(plan.recommendedDuration))s")
            if let notes = plan.styleMatchNotes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT WE DID WITH YOUR BRIEF")
                        .font(VeFont.sans(10, weight: .bold)).tracking(0.4)
                        .foregroundStyle(Color.veFaintGray)
                    Text(notes)
                        .font(VeFont.serif(14, italic: true))
                        .foregroundStyle(Color.veNoteText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.veNote, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 8, y: 2)
    }

    private func statPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(VeFont.sans(18, weight: .bold)).foregroundStyle(Color.veTerracotta)
            Text(label).font(VeFont.sans(10.5)).foregroundStyle(Color.veWarmGray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.veNote, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func metaLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(VeFont.sans(10, weight: .bold)).tracking(0.4)
                .foregroundStyle(Color.veFaintGray)
            Text(value).font(VeFont.sans(13)).foregroundStyle(Color.veCharcoal)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: error

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34)).foregroundStyle(Color.veTerracotta)
            Text("Something went wrong")
                .font(VeFont.serif(22)).foregroundStyle(Color.veCharcoal)
            Text(message)
                .font(VeFont.sans(13)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            HStack(spacing: 10) {
                Button("← Back") { router.back() }
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veWarmGray)
                Button("Retry") { analysis.retry(session: session, projects: projects,
                                                 styleBlock: StyleConstraintBuilder.block(for: templates.active),
                                                 briefBlock: BriefPromptBuilder.block(for: session.brief),
                                                 brollCoverageTarget: brollCoverageTarget) }
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veTerracotta)
            }
            .padding(.bottom, 30)
        }
    }
}
