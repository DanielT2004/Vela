import SwiftUI
import UIKit

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

    /// "Stop this edit?" confirmation — a running analysis is paid + slow, so never cancel on a stray tap.
    @State private var confirmCancel = false

    /// Frames pulled from the merged proxy, used only on a kill-recovery resume where the original
    /// `SourceClip`s (and their thumbnails) are gone — so the loader shows the real footage, not gradients.
    @State private var proxyThumbs: [UIImage] = []

    /// Loader frames: the picks' own thumbnails when present, else the proxy-derived fallback.
    private var loaderThumbnails: [UIImage] {
        let fromClips = session.clips.compactMap { $0.thumbnail }
        return fromClips.isEmpty ? proxyThumbs : fromClips
    }

    /// B-roll coverage seeding cap: the brief's lean wins, else the active template's learned heaviness,
    /// else a sane default. Relative leans (More me / More food) resolve AGAINST the learned heaviness;
    /// "My usual" returns nil and falls through to it. Makes the b-roll choice tangibly change the cut.
    private var brollCoverageTarget: Double {
        let usual = templates.active?.profile.broll.heaviness
        return session.brief?.brollLean.resolvedTarget(styleHeaviness: usual) ?? usual ?? 0.25
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
        // The escape hatch: a quiet Cancel so a regretted submission never traps anyone here (the error
        // state has its own Back/Retry bar, so this shows only while running).
        .overlay(alignment: .topLeading) {
            if analysis.phase == .running {
                Button("Cancel") { confirmCancel = true }
                    .font(VeFont.sans(13, weight: .semibold))
                    .foregroundStyle(Color.veWarmGray)
                    .padding(.leading, 22)
                    .padding(.top, 54)
            }
        }
        .confirmationDialog("Stop this edit?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop the edit", role: .destructive) { cancelAnalysis() }
            Button("Keep working", role: .cancel) {}
        } message: {
            Text("Your clips and answers stay put — you can send it again anytime.")
        }
        // Idempotent — safe to fire on every (re)mount; the coordinator runs the pipeline at most once
        // per submitted clip set and survives this view disappearing. The active style (if any) is injected.
        .task { analysis.start(session: session, projects: projects,
                               styleBlock: StyleConstraintBuilder.block(for: templates.active),
                               briefBlock: BriefPromptBuilder.block(for: session.brief, template: templates.active),
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

    /// Stop the run: warning haptic (destructive), reset the coordinator, and step back — to the Brief
    /// when the creator came from there (clips + brief intact), or Home when they came from its card.
    private func cancelAnalysis() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        analysis.cancel()
        router.back()
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
                Text(closeable ? (NotificationService.shared.notificationsEnabled
                                    ? "Close the app — we'll notify you when it's ready."
                                    : "Notifications are off — check back in a minute or two.")
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
        case .analyzing:  return "Watching your footage"
        case .finishing:  return "Making the first cut"
        }
    }

    private var stageSubtext: String {
        // Upload is opaque, so this is a heuristic: no movement for ~15s during the uploading stage.
        if analysis.stage == .uploading, analysis.isSlow { return "Still uploading — your connection looks slow." }
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
                                                 briefBlock: BriefPromptBuilder.block(for: session.brief, template: templates.active),
                                                 brollCoverageTarget: brollCoverageTarget) }
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veTerracotta)
            }
            .padding(.bottom, 30)
        }
    }
}
