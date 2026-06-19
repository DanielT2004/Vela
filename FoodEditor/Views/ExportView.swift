import SwiftUI
import AVFoundation
import UIKit

/// M8 — Export (screen S8). Assembles the edited plan into a real full-resolution 9:16 MP4 from the
/// ORIGINAL clips, plays it back, and saves it to the camera roll. Share via the system sheet.
struct ExportView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects

    private enum Phase: Equatable { case working, ready(URL), failed(String) }
    private enum SaveState: Equatable { case idle, saving, saved, failed(String) }

    @State private var phase: Phase = .working
    @State private var progress: Double = 0
    @State private var saveState: SaveState = .idle
    /// True when a resumed project rendered from the proxy because the originals weren't available.
    @State private var proxyFallback = false
    @State private var player = AVPlayer()
    @State private var previewPlaying = true
    /// Non-functional learning signal (the real style-learning system is out of scope // TODO).
    @State private var feedback: Bool?

    private var store: EditPlanStore? { session.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            switch phase {
            case .working:        workingView
            case .ready(let url): readyView(url)
            case .failed(let m):  failedView(m)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
        .task { await runExport() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            player.seek(to: .zero); if previewPlaying { player.play() }
        }
        .onDisappear { player.pause() }
    }

    // MARK: header

    private var header: some View {
        HStack {
            BackChevronButton { player.pause(); router.back() }
            Spacer()
            if case .ready = phase { VibeMeterPill(text: store?.vibeText ?? "") }
            Spacer()
            Color.clear.frame(width: 36, height: 36)
        }
        .padding(.horizontal, 22)
        .padding(.top, 54)
        .padding(.bottom, 8)
    }

    // MARK: working

    private var workingView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.veSurface, lineWidth: 8)
                Circle().trim(from: 0, to: max(0.02, progress))
                    .stroke(Color.veTerracotta, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)
                Text("\(Int(progress * 100))%")
                    .font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veCharcoal)
            }
            .frame(width: 104, height: 104)

            VStack(spacing: 6) {
                Text("Assembling your cut")
                    .font(VeFont.serif(23)).foregroundStyle(Color.veCharcoal)
                Text("Rendering from your original footage at full quality…")
                    .font(VeFont.sans(13.5)).foregroundStyle(Color.veWarmGray)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
        }
    }

    // MARK: ready

    private func readyView(_ url: URL) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.veSage).frame(width: 54, height: 54)
                    Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                }
                Text("Your edit's ready")
                    .font(VeFont.serif(25)).foregroundStyle(Color.veCharcoal)
            }

            // 9:16 preview
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.veCharcoal)
                PlayerLayerView(player: player, gravity: .resizeAspect)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                Button { togglePlay() } label: { Color.clear }.buttonStyle(.plain)
                if !previewPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54).background(.black.opacity(0.35), in: Circle())
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 196, height: 348)
            .shadow(color: Color.veCharcoal.opacity(0.2), radius: 16, y: 10)

            saveStatus
            if proxyFallback { fallbackNote }

            HStack(spacing: 12) {
                ShareLink(item: url) {
                    label("Share", system: "square.and.arrow.up", fg: Color.veCharcoal, bg: Color.veSurface)
                }
                Button { router.home() } label: {
                    label("New video", system: "plus", fg: Color.veOnTerracotta, bg: Color.veTerracotta)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)

            feedbackRow
        }
        .padding(.horizontal, 22)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    /// "Did this feel like you?" — a soft learning signal (non-functional; real learning is // TODO).
    private var feedbackRow: some View {
        VStack(spacing: 8) {
            if let feedback {
                Text(feedback ? "Love it — Vela's learning your taste." : "Noted — we'll tune the next one.")
                    .font(VeFont.sans(12.5, weight: .semibold))
                    .foregroundStyle(Color.veSage)
                    .transition(.opacity)
            } else {
                Text("Did this feel like you?")
                    .font(VeFont.sans(12.5, weight: .semibold))
                    .foregroundStyle(Color.veWarmGray)
                HStack(spacing: 14) {
                    thumbButton(up: true)
                    thumbButton(up: false)
                }
            }
        }
        .padding(.top, 4)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: feedback)
    }

    private func thumbButton(up: Bool) -> some View {
        Button {
            withAnimation { feedback = up }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            Log.app("👍 Export feedback: \(up ? "loved it" : "not quite").")
        } label: {
            Image(systemName: up ? "hand.thumbsup" : "hand.thumbsdown")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(up ? Color.veSage : Color.veWarmGray)
                .frame(width: 46, height: 40)
                .background(Color.veSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var saveStatus: some View {
        Group {
            switch saveState {
            case .idle, .saving:
                pill(text: "Saving to camera roll…", system: "arrow.down.circle", fg: Color.veWarmGray, bg: Color.veSurface)
            case .saved:
                pill(text: "Saved to your camera roll", system: "checkmark.circle.fill", fg: Color.veSage, bg: Color.veSage.opacity(0.12))
            case .failed:
                Button { Task { if case .ready(let url) = phase { await save(url) } } } label: {
                    pill(text: "Couldn't save — tap to retry", system: "exclamationmark.arrow.circlepath",
                         fg: Color.veTerracotta, bg: Color.veTerracotta.opacity(0.12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Shown on a resumed export when the full-res originals weren't available.
    private var fallbackNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .bold))
            Text("Rendered at preview quality — original footage wasn't available.")
                .font(VeFont.sans(11.5, weight: .medium))
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(Color.veNoteText)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.veNote, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .frame(maxWidth: 280)
    }

    private func pill(text: String, system: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: system).font(.system(size: 12, weight: .bold))
            Text(text).font(VeFont.sans(12.5, weight: .semibold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 13).padding(.vertical, 8)
        .background(bg, in: Capsule())
    }

    private func label(_ text: String, system: String, fg: Color, bg: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: system).font(.system(size: 14, weight: .bold))
            Text(text).font(VeFont.sans(15, weight: .bold))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: failed

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.veTerracotta.opacity(0.15)).frame(width: 60, height: 60)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Color.veTerracotta)
            }
            Text("Export hit a snag").font(VeFont.serif(23)).foregroundStyle(Color.veCharcoal)
            Text(message)
                .font(VeFont.sans(13.5)).foregroundStyle(Color.veWarmGray)
                .multilineTextAlignment(.center).frame(maxWidth: 290)
            Button {
                phase = .working; progress = 0; saveState = .idle
                Task { await runExport() }
            } label: {
                Text("Try again").font(VeFont.sans(15, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
                    .padding(.horizontal, 24).padding(.vertical, 13)
                    .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
    }

    // MARK: actions

    private func togglePlay() {
        previewPlaying.toggle()
        previewPlaying ? player.play() : player.pause()
    }

    private func runExport() async {
        guard case .working = phase else { return }
        guard let store, session.merged != nil else {
            phase = .failed("The analyzed video is missing — start a new edit from the Kitchen.")
            return
        }
        // Resolve sources: fresh temp originals, resumed full-res (PHAsset), or proxy fallback.
        let resolved = await ExportSourceResolver.resolve(session: session)
        guard !resolved.sources.isEmpty else {
            await MainActor.run { phase = .failed("The source video is missing — start a new edit from the Kitchen.") }
            return
        }
        do {
            let url = try await EditPlanAssembler.assemble(store: store, sources: resolved.sources) { p in
                Task { @MainActor in progress = p }
            }
            await MainActor.run {
                AudioSession.configureForPlayback()
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                player.seek(to: .zero)
                previewPlaying = true
                player.play()
                proxyFallback = resolved.usedProxyFallback
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { phase = .ready(url) }
                // CP1.2 — a cut rendered: mark the project exported.
                projects.save(session: session, reaching: .exported)
            }
            await save(url)
        } catch {
            Log.assembly("Assembly failed: \(error.localizedDescription)")
            await MainActor.run { phase = .failed(error.localizedDescription) }
            NotificationService.shared.notify(title: "Export hit a snag", body: error.localizedDescription)
        }
    }

    private func save(_ url: URL) async {
        await MainActor.run { saveState = .saving }
        do {
            try await PhotoLibrary.saveVideo(at: url)
            await MainActor.run { saveState = .saved }
            NotificationService.shared.notify(title: "Your edit is saved 🎉",
                                              body: "Your \(store?.vibeText ?? "") cut is in your camera roll.")
        } catch {
            await MainActor.run { saveState = .failed(error.localizedDescription) }
        }
    }
}
