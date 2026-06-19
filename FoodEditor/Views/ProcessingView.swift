import SwiftUI

/// Screen 3 — Processing. Runs the real pipeline behind the mockup's calm terracotta arc:
/// M2 merge+compress → M3 Gemini analysis. For M3 it shows the RAW Gemini JSON on screen (and logs
/// it to the console) so we can verify response quality before building any editing UI. (M4 will
/// parse it into an Edit Plan and fire a completion notification.)
struct ProcessingView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects

    @State private var progress: Double = 0
    @State private var label = "Getting started"
    @State private var rawResponse: String?
    @State private var plan: EditPlan?
    @State private var errorText: String?

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()
            if let plan, let rawResponse {
                doneState(plan, rawResponse)
            } else if let errorText {
                errorState(errorText)
            } else {
                workingState
            }
        }
        .task { await run() }
    }

    // MARK: working

    private var workingState: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().stroke(Color(hex: 0xE7DECE), lineWidth: 5).frame(width: 132, height: 132)
                Circle()
                    .trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.veTerracotta, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 132, height: 132)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(VeFont.serif(34))
                    .foregroundStyle(Color.veTerracotta)
            }
            Text(label)
                .font(VeFont.serif(25))
                .foregroundStyle(Color.veCharcoal)
                .multilineTextAlignment(.center)
                .animation(.easeInOut, value: label)
            Text("Analyzing can take a minute on longer videos — hang tight.")
                .font(VeFont.sans(13))
                .foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .padding(40)
    }

    // MARK: done (M4 — decoded summary + raw JSON)

    private func doneState(_ plan: EditPlan, _ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
            .padding(.top, 58)
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
                Button("Retry") { Task { await retry() } }
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veTerracotta)
            }
            .padding(.bottom, 30)
        }
    }

    // MARK: work

    private func run() async {
        guard plan == nil, errorText == nil else { return }
        // Ask for notification permission up front (non-blocking) so we can ping when done.
        Task { await NotificationService.shared.requestAuthorization() }
        do {
            // Phase 1 — merge + compress (0 → 35%)
            let processed = try await VideoPreprocessor.mergeAndCompress(clips: session.clips) { p in
                Task { @MainActor in
                    progress = p * 0.35
                    label = "Stitching your clips"
                }
            }
            await MainActor.run { session.merged = processed }

            // Phase 2 — Gemini analysis (35% → 95%)
            let raw = try await GeminiService.shared.rawEditPlanJSON(forVideoAt: processed.url) { stage, frac in
                Task { @MainActor in
                    progress = 0.35 + frac * 0.6
                    label = stage
                }
            }

            // Phase 3 — parse into the Edit Plan (95% → 100%)
            await MainActor.run { label = "Putting it together"; progress = 0.97 }
            let parsed = try EditPlan.parse(fromRawModelText: raw)
            Log.blob(.gemini, "DECODED EDIT PLAN", parsed.debugSummary)

            await MainActor.run {
                session.store = EditPlanStore(plan: parsed)
                rawResponse = raw
                plan = parsed
                progress = 1.0
                // CP1.2 — register this analyzed session as a saved project.
                projects.startNew(from: parsed)
                projects.save(session: session, reaching: .triage)
            }
            NotificationService.shared.notify(
                title: "Your cut is ready 🍴",
                body: "\(parsed.segments.count) moments found · ~\(Int(parsed.recommendedDuration))s suggested. Tap to refine."
            )

            // CP1.3 — capture a Home-tile poster from the proxy's opening frame, then re-save with it.
            let posterTime = parsed.segments.first(where: { $0.id == parsed.finalEditOrder.first })?.startSeconds ?? 0.5
            if let poster = await ThumbnailService.thumbnail(for: processed.url, at: posterTime) {
                await MainActor.run { projects.save(session: session, poster: poster) }
            }
        } catch {
            Log.gemini("Pipeline error: \(error.localizedDescription)")
            await MainActor.run { errorText = error.localizedDescription }
            NotificationService.shared.notify(
                title: "Analysis hit a snag",
                body: error.localizedDescription
            )
        }
    }

    private func retry() async {
        await MainActor.run {
            errorText = nil
            progress = 0
            label = "Getting started"
        }
        await run()
    }
}
