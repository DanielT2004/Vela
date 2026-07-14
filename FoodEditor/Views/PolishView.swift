import SwiftUI
import AVKit
import AVFoundation
import UIKit

/// M3 — Polish (screen S7), rebuilt to the Claude Design "Polish Editor" mockup: a 4-track timeline
/// (Text / Main / B-roll / Audio) under a **fixed centered playhead** that the timeline scrolls beneath,
/// with a transport row (undo/redo · timecode · zoom), frame-step playback, and a Split/Trim/Speed/
/// Volume/Delete toolbar.
///
/// Coordinate model: `scrollX` is the pixel distance from t=0 to the playhead; `time = scrollX / pps`.
/// A clip at base time `t` sits at lane-x `laneW/2 - scrollX + t·pps`, so time 0 is under the centered
/// playhead when `scrollX == 0`. MAIN + B-ROLL are functional; TEXT + AUDIO are rendered but empty.
struct PolishView: View {
    @Environment(VideoSession.self) private var session
    @Environment(ClipImportCoordinator.self) private var clipImport
    @Environment(VoiceIsolationCoordinator.self) private var voiceIso
    @Environment(ProjectService.self) private var projects
    @Environment(TemplateService.self) private var templates
    @Environment(\.scenePhase) private var scenePhase

    @State private var showVideoPicker = false       // camera-roll picker for "Add videos"
    @State private var player = AVPlayer()
    @State private var previewPlaying = false
    @State private var fullscreen = false
    @State private var thumbs: [Int: UIImage] = [:]

    @State private var selection: Selection?
    @State private var scrollX: CGFloat = 0          // pixels from t=0 to the centered playhead
    @State private var scrubbing = false
    @State private var scrubStartX: CGFloat = 0
    @State private var laneWidth: CGFloat = 320
    @State private var timeObserver: Any?
    @State private var rebuildTick = 0
    @State private var voicePreview: PolishComposition.VoicePreview?   // handles for the in-place Original↔Cleaned swap
    @State private var sourcePicker: SourcePicker?
    @State private var trimming = false
    @State private var trimDrag: TrimDrag?
    @State private var lift: LiftDrag?
    @State private var autoScroller = EdgeAutoScroller(axis: .horizontal)
    @State private var autoPanX: CGFloat = 0          // px the timeline auto-scrolled during the current lift
    @State private var inspector: InspectorMode?
    @State private var splitFlash: SplitFlash?       // brief toast + scissor badge after a split
    @State private var splitFlashTask: Task<Void, Never>?
    @State private var voiceToast: (text: String, ok: Bool)?   // brief banner when isolation finishes/fails
    @State private var voiceToastTask: Task<Void, Never>?
    @State private var narration = NarrationRecorder()        // voiceover take capture (page-scoped)
    @State private var takeStart: Double?                      // playhead when the current take began
    @State private var dragGain: Double?                       // duck-slider mid-drag value (commit on release)
    @State private var narrationNudge: String?                 // one-shot "record a voiceover?" banner
    @State private var narrationNudgeTask: Task<Void, Never>?

    @State private var pps: CGFloat = 14             // points per second (pinch-zoomable)
    @State private var zoomBasePps: CGFloat = 14
    @State private var zoomAnchorTime: Double = 0
    @State private var zooming = false

    @State private var editingText: UUID?            // a text overlay being edited in the panel
    @State private var textEditStart: TextEditStart? // transient start state for a one-finger canvas gesture
    @State private var textPinchStart: Double?       // fontSize at the start of a pinch-resize
    @State private var textRotateStart: Double?      // rotation at the start of a two-finger twist
    @State private var textRotateSnapped = false     // currently held in the horizontal snap detent
    @State private var cropDrag: CropDrag?           // in-progress per-clip reframe (pinch/pan)
    @State private var cropActive = false            // a crop gesture is underway (gates begin/commit)
    @State private var textTab: TextTab = .keyboard
    @State private var textSessionPushed = false     // pushUndo once per edit session, lazily
    @FocusState private var textFieldFocused: Bool

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    enum Selection: Equatable { case base(UUID), overlay(UUID), text(UUID), narration(UUID) }
    private enum TextTab: String, CaseIterable, Identifiable { case keyboard = "Keyboard", font = "Font", style = "Style"; var id: String { rawValue } }

    /// Captured at the start of a canvas text move / resize / rotate so the gesture works off deltas.
    private struct TextEditStart { let cx: Double; let cy: Double; let size: Double; let dist: Double; let angleOffset: Double }
    /// In-progress crop (reframe) of a Main clip. Transient scale/pan drive a live `scaleEffect`/`offset`
    /// on the player; on release they're folded into the clip's stored crop and the preview rebuilds.
    private struct CropDrag { let cid: UUID; let startScale: Double; let startOffX: Double; let startOffY: Double
                              var transientScale: Double = 1; var transientPanX: CGFloat = 0; var transientPanY: CGFloat = 0 }
    private let previewSpace = "preview"
    private let previewHeight: CGFloat = 264
    private enum InspectorMode { case speed, volume, voice, record }
    private enum SourcePicker: Identifiable {
        case add, swap(UUID)
        var id: String { switch self { case .add: return "add"; case .swap(let u): return "swap-\(u)" } }
    }

    /// Two-edge trim. `factor` converts a pixel drag → source seconds (clip speed; 1 for overlays). The
    /// drag updates `dx` only; the tile renders a *display* size from it and the store is committed on
    /// release (avoids the resize-feedback vibration).
    private struct TrimDrag {
        let sel: Selection
        let leftEdge: Bool
        let baseLeft: Double
        let baseRight: Double
        let factor: Double
        var dx: CGFloat = 0
    }

    /// Hold-to-lift move (B-roll reposition) / reorder (Main). `baseStart` = the clip's start at lift time.
    private struct LiftDrag {
        let sel: Selection
        let baseStart: Double
        var t: CGSize = .zero
    }

    /// A just-happened split — drives the scissor-on-playhead badge + the "Split at … · N clips" toast.
    private struct SplitFlash: Equatable { let time: Double; let clips: Int }

    private let timelineSpace = "ptl"
    private let oneFrame = 1.0 / 30.0
    private let gutter: CGFloat = 24
    private let trackGap: CGFloat = 4
    private let rulerH: CGFloat = 16
    private let textH: CGFloat = 22
    private let mainH: CGFloat = 40
    private let brollH: CGFloat = 30
    private let narrationH: CGFloat = 24
    private let audioH: CGFloat = 20
    /// Downward drag (dy) past which a lifted Main clip becomes a B-roll drop instead of a reorder.
    /// 30pt clears the Main lane (mainH/2 + trackGap) and enters the B-roll row.
    private let brollDropThreshold: CGFloat = 30
    /// Upward drag (dy) past which a lifted B-roll chip promotes onto the Main spine instead of moving.
    /// 34pt ≈ brollH/2 + trackGap + mainH/2 — the gap from the B-roll row up into the Main row.
    private let mainPromoteThreshold: CGFloat = 34

    private var total: Double { store?.baseDuration ?? 0 }
    private var playheadTime: Double { pps > 0 ? Double(scrollX) / Double(pps) : 0 }
    private var lifting: Bool { lift != nil }

    var body: some View {
        VStack(spacing: 0) {
            preview
            transportRow
            playbackRow
            timeline
            inspectorPanel
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
        .overlay { importProgressOverlay }
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                voiceToastBanner
                narrationNudgeBanner
            }
        }
        .onChange(of: voiceIso.phase) { _, phase in
            switch phase {
            case .done:           showVoiceToast(text: "Clean voice ready", ok: true)
            case .failed(let m):  showVoiceToast(text: m, ok: false)
            default:              break
            }
        }
        .task { await loadThumbnails() }
        .task(id: previewSignature) { await rebuildPreview() }
        .onAppear {
            addObserver()
            // One-shot: a resumed project whose take files vanished (lane persists names only).
            if let store, store.prunedNarrationOnResume > 0 {
                let n = store.prunedNarrationOnResume
                store.prunedNarrationOnResume = 0
                showVoiceToast(text: n == 1 ? "A voiceover file was missing and was removed."
                                            : "\(n) voiceover files were missing and were removed.", ok: false)
            }
            maybeShowNarrationNudge()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { narration.stop() }       // backgrounding stops-and-keeps the take
            else { narration.refreshMicPermission() }      // back from Settings → un-stick the mic hint
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            if narration.isBusy { narration.stop(); return }   // the video's end ends the take — don't loop
            player.seek(to: .zero); scrollX = 0
            if previewPlaying && !fullscreen { player.play() }
        }
        .onDisappear(perform: teardown)
        .sheet(item: $sourcePicker) { picker in sourceSheet(picker) }
        .sheet(isPresented: $showVideoPicker) {
            VideoPicker(preselectedIdentifiers: session.selectedAssetIdentifiers) { picked, failedCount in
                showVideoPicker = false
                if failedCount > 0 {
                    showVoiceToast(text: "Couldn't load \(failedCount) video\(failedCount == 1 ? "" : "s") — check your connection.", ok: false)
                }
                guard !picked.isEmpty else { return }
                store?.pushUndo()                                   // one undo step for the whole import
                Task {
                    await clipImport.importClips(picked, into: session)
                    rebuildTick += 1                                // rebuild preview against the new proxy
                    await loadThumbnails()                          // fill thumbnails for the new clips
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: Binding(get: { editingText != nil }, set: { if !$0 { closeTextEditor() } })) {
            textEditorSheet
                .presentationDetents([.height(308), .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .height(308)))
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $fullscreen) {
            FullScreenPlayer(player: player) { fullscreen = false }
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.vePreviewMat)

            // The 9:16 video stage, centered in the mat. resizeAspectFill center-crops the proxy to 9:16
            // (matching export); per-clip crop is the player layer's `contentTransform`.
            ZStack {
                PlayerLayerView(player: player, gravity: .resizeAspectFill, contentTransform: currentCropTransform)
                Button(action: togglePlay) { Color.clear }.buttonStyle(.plain)

                VStack {
                    HStack {
                        Spacer()
                        Text("9:16").font(VeFont.mono(9.5)).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    Spacer()
                    HStack {
                        Text(previewCaption).font(VeFont.serif(13, italic: true)).foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                        Spacer()
                        Button { player.pause(); fullscreen = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                                .frame(width: 30, height: 30).background(.black.opacity(0.3), in: Circle())
                        }.buttonStyle(.plain).disabled(narration.isBusy)
                    }
                }
                .padding(12)

                if !previewPlaying && !isTextSelected {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 54, height: 54).background(.black.opacity(0.4), in: Circle())
                        .allowsHitTesting(false)
                }

                textCanvas   // captions + the selected caption's move/resize/rotate gizmo

                if let d = cropDrag { cropHUD(d) }   // "1.4×" reframe readout during a crop gesture

                recordHUD   // 3-2-1 countdown digit + REC pill while a voiceover take is captured
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .coordinateSpace(name: previewSpace)
            .simultaneousGesture(cropMagnify)
            .simultaneousGesture(cropPan)
        }
        .frame(height: previewHeight)
        .padding(.horizontal, 16).padding(.top, 16)
        .shadow(color: Color.veCharcoal.opacity(0.12), radius: 12, y: 6)
    }

    /// The per-clip crop applied to the preview player layer: the clip under the playhead's stored crop,
    /// or the live gesture transient. Mirrors the export's `ReframeTransform` (scale about center + a
    /// normalized pan), but as a CALayer transform on top of `.resizeAspectFill`.
    private var currentCropTransform: CGAffineTransform {
        let matH = Double(previewHeight)
        let matW = matH * 9.0 / 16.0
        func tf(_ s: Double, _ ox: Double, _ oy: Double) -> CGAffineTransform {
            CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s))
                .concatenating(CGAffineTransform(translationX: CGFloat(ox * matW), y: CGFloat(oy * matH)))
        }
        if let d = cropDrag {
            let s = min(4, max(1, d.startScale * d.transientScale))
            let ox = d.startOffX + Double(d.transientPanX) / matW
            let oy = d.startOffY + Double(d.transientPanY) / matH
            return tf(s, ox, oy)
        }
        if let clip = cropClipUnderPlayhead() { return tf(clip.cropScale, clip.cropOffsetX, clip.cropOffsetY) }
        return .identity
    }

    private func cropClipUnderPlayhead() -> Clip? {
        guard let store else { return nil }
        var t = 0.0
        for c in store.order { if playheadTime < t + c.timelineDuration { return c }; t += c.timelineDuration }
        return store.order.last
    }

    private func cropHUD(_ d: CropDrag) -> some View {
        let s = min(4, max(1, d.startScale * d.transientScale))
        return VStack {
            Text(String(format: "%.1f×", s))
                .font(VeFont.mono(12, weight: .semibold)).foregroundStyle(Color.veOnTerracotta)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.veTerracotta.opacity(0.92), in: Capsule())
                .padding(.top, 12)
            Spacer()
        }.allowsHitTesting(false)
    }

    /// Voiceover capture feedback over the preview: a big serif countdown digit (springs in per tick),
    /// then a REC pill with the elapsed timecode while the mic is live.
    private var recordHUD: some View {
        ZStack {
            if case .countdown(let n) = narration.phase {
                Text("\(n)")
                    .font(VeFont.serif(64))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                    .id(n)   // new identity per digit → the transition replays each tick
                    .transition(.scale(scale: 1.5).combined(with: .opacity))
            } else if narration.phase == .recording {
                VStack {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(Color(hex: 0xC94F3D)).frame(width: 7, height: 7)
                            Text("REC \(timecode(narration.elapsed))")
                                .font(VeFont.mono(10, weight: .semibold)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.45), in: Capsule())
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: narration.phase)
        .allowsHitTesting(false)
    }

    // MARK: - Per-clip crop gestures (reframe the selected Main clip in the 9:16 window)

    private var cropMagnify: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard case .base(let cid)? = selection else { return }
                if !cropActive { cropActive = true; beginCrop(cid) }
                cropDrag?.transientScale = Double(scale)
            }
            .onEnded { _ in commitCrop() }
    }

    private var cropPan: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                guard case .base(let cid)? = selection,
                      let clip = store?.order.first(where: { $0.id == cid }), clip.cropScale > 1.001
                else { return }   // can only pan a clip that's zoomed in
                if !cropActive { cropActive = true; beginCrop(cid) }
                cropDrag?.transientPanX = v.translation.width
                cropDrag?.transientPanY = v.translation.height
            }
            .onEnded { _ in if cropActive { commitCrop() } }
    }

    private func beginCrop(_ cid: UUID) {
        guard let clip = store?.order.first(where: { $0.id == cid }) else { return }
        store?.pushUndo()
        previewPlaying = false; player.pause()
        // Show the clip being reframed if the playhead is elsewhere, so the live feedback is its frame.
        let start = baseStart(clip)
        if playheadTime < start || playheadTime >= start + clip.timelineDuration {
            scrollX = clampScroll(CGFloat(start + 0.1) * pps); seekPlayerOnly(to: start + 0.1)
        }
        cropDrag = CropDrag(cid: cid, startScale: clip.cropScale, startOffX: clip.cropOffsetX, startOffY: clip.cropOffsetY)
    }

    private func commitCrop() {
        guard cropActive, let d = cropDrag, let store else { cropActive = false; return }
        cropActive = false
        let cw = previewHeight * 9.0 / 16.0    // 9:16 content rect inside the mat
        let newScale = d.startScale * d.transientScale
        let offX = d.startOffX + Double(d.transientPanX / cw)
        let offY = d.startOffY + Double(d.transientPanY / previewHeight)
        store.setCrop(d.cid, scale: newScale, offsetX: offX, offsetY: offY)
        cropDrag = nil           // the player layer's contentTransform reads the stored crop directly
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var previewCaption: String {
        guard let store else { return "" }
        // The clip under the playhead.
        var t = 0.0
        for c in store.order {
            if playheadTime < t + c.timelineDuration {
                let seg = store.segment(c.sourceSegmentId)
                return seg?.description.isEmpty == false ? seg!.description : (seg?.sceneType.label ?? "")
            }
            t += c.timelineDuration
        }
        return ""
    }

    // MARK: - Transport row (undo/redo · timecode · zoom)

    private var transportRow: some View {
        HStack {
            HStack(spacing: 8) {
                transportButton("arrow.uturn.backward", enabled: store?.canUndo ?? false) { doUndo() }
                transportButton("arrow.uturn.forward", enabled: store?.canRedo ?? false) { doRedo() }
            }
            Spacer()
            (Text(timecode(playheadTime)).foregroundStyle(Color.veCharcoal).fontWeight(.semibold)
             + Text(" / \(timecode(total))").foregroundStyle(Color.veFaintGray))
                .font(VeFont.mono(13))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(zoomed ? Color.veTerracotta : Color.veWarmGray)
                Text(zoomLabel).font(VeFont.mono(11, weight: zoomed ? .semibold : .regular))
                    .foregroundStyle(zoomed ? Color.veTerracotta : Color.veNoteText)
            }
            .frame(height: 26).padding(.horizontal, 9)
            .background(zoomed ? Color.veTerracotta.opacity(0.14) : Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(zoomed ? Color.veTerracotta.opacity(0.3) : Color.veCharcoal.opacity(0.1), lineWidth: 1))
        }
        .padding(.horizontal, 16).padding(.top, 14)
    }

    private func transportButton(_ system: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? Color.veNoteText : Color.veFaintGray)
                .frame(width: 36, height: 36)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.veCharcoal.opacity(0.1), lineWidth: 1))
                .shadow(color: Color.veCharcoal.opacity(0.07), radius: 3, y: 1)
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    private var zoomLabel: String {
        let x = Double(pps / 14)
        return String(format: "%.1f×", x)
    }

    /// Zoomed past the base scale — tints the zoom pill terracotta (mockup Frame 4).
    private var zoomed: Bool { pps > 14.5 }

    // MARK: - Playback row (−1f · play/pause · +1f)

    private var playbackRow: some View {
        HStack(spacing: 26) {
            frameStep("backward.frame", label: "-1f") { step(by: -1) }
            Button(action: togglePlay) {
                Image(systemName: previewPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
                    .frame(width: 50, height: 50)
                    .background(Color.veTerracotta, in: Circle())
                    .shadow(color: Color.veTerracotta.opacity(0.35), radius: 10, y: 6)
            }.buttonStyle(.plain)
            frameStep("forward.frame", label: "+1f") { step(by: 1) }
        }
        .padding(.top, 12)
    }

    private func frameStep(_ system: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system).font(.system(size: 19, weight: .medium)).foregroundStyle(Color.veNoteText)
                Text(label).font(VeFont.mono(8)).foregroundStyle(Color.veFaintGray)
            }
        }.buttonStyle(.plain)
    }

    // MARK: - Timeline (4-track, fixed centered playhead)

    private var timeline: some View {
        GeometryReader { geo in
            let laneW = max(40, geo.size.width - gutter)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: trackGap) {
                    ruler(laneW)
                    laneRow(kind: .text, height: textH) { textLane(laneW) }
                    // Main row: CapCut-style track-head mute lives in the gutter instead of a static icon.
                    HStack(spacing: 0) {
                        muteAllButton.frame(width: gutter, height: mainH)
                        mainLane(laneW)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: mainH)
                            .clipped()
                    }
                    .frame(height: mainH)
                    .background(mainPromoteHighlight)
                    laneRow(kind: .broll, height: brollH) { brollLane(laneW) }
                        .background(brollDropHighlight)
                    laneRow(kind: .narration, height: narrationH) { narrationLaneView(laneW) }   // VOICEOVER — recorded takes
                    laneRow(kind: .audio, height: audioH) { audioLaneContent(laneW) }   // AUDIO — cleaned-range bars
                        .opacity(dimTextAudio)
                }
                .padding(.top, 4)

                // fixed centered playhead over the lane area (line centered in an 11pt-wide frame)
                playhead(splitFlash != nil ? Color.veTerracotta : Color.veCharcoal)
                    .offset(x: gutter + laneW / 2 - 5.5)

                // selected-clip duration bubble, pinned over the playhead
                if selectedDuration != nil { durationBubble.position(x: gutter + laneW / 2, y: rulerH + 14) }

                // split feedback: scissor badge at the top of the playhead + a brief toast at the bottom
                if let flash = splitFlash {
                    scissorBadge.position(x: gutter + laneW / 2, y: rulerH - 2)
                        .transition(.scale.combined(with: .opacity))
                    splitToast(flash).position(x: gutter + laneW / 2, y: geo.size.height - 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: timelineSpace)
            .gesture(scrubGesture)
            .simultaneousGesture(zoomGesture)
            .onTapGesture {
                // Tapping empty timeline clears the selection AND any open inspector panel (the Record
                // panel included — it used to strand itself when nothing was selected). Never mid-take.
                guard !narration.isBusy else { return }
                if selection != nil || inspector != nil { selection = nil; inspector = nil }
            }
            .onAppear { laneWidth = laneW }
            .onChange(of: laneW) { _, n in laneWidth = n }
        }
        .frame(maxHeight: .infinity)
        .background(Color.veTrackLane)
        .overlay(alignment: .top) { Rectangle().fill(Color.veCharcoal.opacity(0.08)).frame(height: 1) }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) { addVideosButton; addBrollButton }
                .padding(.trailing, 10).padding(.top, 8)
        }
    }

    /// Pick more camera-roll clips and append them raw to the end of the spine (no re-analysis).
    private var addVideosButton: some View {
        Button {
            previewPlaying = false; player.pause()
            showVideoPicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("Videos").font(VeFont.sans(10, weight: .bold))
            }
            .foregroundStyle(Color.veCharcoal)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.veCream, in: Capsule())
            .overlay(Capsule().stroke(Color.veCharcoal.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(clipImport.isBusy || narration.isBusy)
    }

    private var addBrollButton: some View {
        Button { guard !narration.isBusy else { return }; sourcePicker = .add } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                Text("B-roll").font(VeFont.sans(10, weight: .bold))
            }
            .foregroundStyle(Color.veOnTerracotta)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.veTerracotta, in: Capsule())
            .shadow(color: Color.veTerracotta.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
    }

    /// Dim + spinner while clips are being re-merged into the proxy (stays on the Polish page — never
    /// routes to ProcessingView, which would re-run Gemini).
    @ViewBuilder private var importProgressOverlay: some View {
        if clipImport.isBusy {
            ZStack {
                Color.veCharcoal.opacity(0.35).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView(value: clipImport.progress)
                        .progressViewStyle(.linear).frame(width: 180).tint(Color.veTerracotta)
                    Text("Adding your clips…")
                        .font(VeFont.sans(13, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .transition(.opacity)
        }
    }

    /// One track row: a fixed 24pt gutter icon + a clipped lane the content scrolls within.
    private func laneRow<Content: View>(kind: TrackIcon.Kind, height: CGFloat,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 0) {
            TrackIcon(kind: kind).frame(width: gutter, height: height)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: height)
                .clipped()
        }
        .frame(height: height)
    }

    private func ruler(_ laneW: CGFloat) -> some View {
        let step = rulerStep
        let marks = Array(stride(from: 0.0, through: max(total, step), by: step))
        return ZStack(alignment: .topLeading) {
            // Faint frame ticks under the labels once zoomed near frame level (matches the mockup's
            // zoomed "frame ruler"). Hidden at coarse zoom where they'd just be noise.
            if pps >= 60 {
                Canvas { ctx, size in
                    let spacing = pps / 30                     // one tick per frame
                    guard spacing >= 3 else { return }
                    var x = (laneW / 2 - scrollX).truncatingRemainder(dividingBy: spacing)
                    if x < 0 { x += spacing }
                    while x < size.width {
                        ctx.fill(Path(CGRect(x: gutter + x, y: rulerH - 4, width: 1, height: 4)),
                                 with: .color(Color.veCharcoal.opacity(0.15)))
                        x += spacing
                    }
                }
                .allowsHitTesting(false)
            }
            ForEach(marks, id: \.self) { τ in
                Text(step >= 1 ? clock(τ) : timecode(τ))
                    .font(VeFont.mono(8)).foregroundStyle(Color.veFaintGray).fixedSize()
                    .offset(x: gutter + xFor(τ, laneW), y: 5)
            }
        }
        // Must fill the lane width: the labels are positioned with `.offset`, which doesn't grow the
        // ZStack, so without an explicit width the frame collapses to one label and `.clipped()` would
        // erase every mark. (Every other lane already uses `maxWidth: .infinity` for this reason.)
        .frame(maxWidth: .infinity, minHeight: rulerH, maxHeight: rulerH, alignment: .topLeading)
        .clipped()
    }

    /// Label spacing that keeps ruler ticks ~70pt apart, getting finer as you zoom in.
    private var rulerStep: Double {
        let target = 70.0 / Double(pps)
        return [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60].first { $0 >= target } ?? 60
    }

    private func mainLane(_ laneW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(store?.order ?? []) { clip in
                mainClipTile(clip)
                    .scaleEffect(isLifted(.base(clip.id)) ? 1.06 : 1)
                    .offset(x: xFor(displayStart(forBase: clip), laneW), y: liftY(.base(clip.id)))
                    .zIndex(isLifted(.base(clip.id)) ? 10 : 1)
                    .animation((isLifted(.base(clip.id)) || isTrimming(.base(clip.id))) ? nil
                               : .spring(response: 0.28, dampingFraction: 0.85),
                               value: displayStart(forBase: clip))
            }
            if let barT = mainInsertionBarTime {
                Rectangle().fill(Color.veTerracotta).frame(width: 2.5, height: mainH + 6)
                    .offset(x: xFor(barT, laneW) - 1.25, y: -3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func brollLane(_ laneW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(store?.brollLane ?? []) { o in
                brollChip(o)
                    .scaleEffect(isLifted(.overlay(o.id)) ? 1.08 : 1)
                    .offset(x: xFor(displayStart(forOverlay: o), laneW), y: liftY(.overlay(o.id)))
                    .zIndex(isLifted(.overlay(o.id)) ? 10 : 1)
            }
            // No footage to layer (e.g. a single talking-head clip) → tell the user the empty lane isn't
            // broken and how to fill it. Pinned near the scroll origin so it's visible without scrolling.
            if store?.hasNoBrollAvailable == true {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.stack.badge.plus").font(.system(size: 11))
                    Text("No b-roll yet — tap “+ B-roll” to layer clips over your talking.")
                        .font(VeFont.sans(10.5, weight: .medium)).lineLimit(2)
                }
                .foregroundStyle(Color.veFaintGray)
                .frame(width: 210, alignment: .leading)
                .padding(.leading, 8).padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Dashed terracotta wash behind the Main lane while a B-roll chip is dragged up onto it — the
    /// "drop here to make a main clip" affordance (the mirror of `brollDropHighlight`).
    @ViewBuilder private var mainPromoteHighlight: some View {
        if draggingBrollToMain {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.veTerracotta.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.veTerracotta.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .padding(.leading, gutter)
                .transition(.opacity)
        }
    }

    /// Dashed terracotta wash behind the B-roll lane while a Main clip is dragged down onto it — the
    /// "drop here to make B-roll" affordance. Padded past the 24pt gutter so it aligns under the lane.
    @ViewBuilder private var brollDropHighlight: some View {
        if draggingBaseToBroll {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.veTerracotta.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.veTerracotta.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
                .padding(.leading, gutter)
                .transition(.opacity)
        }
    }

    private func mainClipTile(_ clip: Clip) -> some View {
        let w = max(3, CGFloat(displayDur(forBase: clip)) * pps)
        let seg = store?.segment(clip.sourceSegmentId)
        let selected = selection == .base(clip.id)
        return ZStack(alignment: .bottomLeading) {
            if let img = thumbs[clip.sourceSegmentId] { Image(uiImage: img).resizable().scaledToFill() }
            else { (seg?.sceneType.foodTone ?? .talk).gradient }
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .bottom, endPoint: .center)
            Text(tileLabel(seg)).font(VeFont.sans(7.5).italic())
                .foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                .padding(.horizontal, 5).padding(.bottom, 3)
        }
        .frame(width: w, height: mainH)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(selected ? Color.veTerracotta : Color.veCharcoal.opacity(0.1), lineWidth: selected ? 2 : 1)
        )
        .overlay { if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.veTerracotta.opacity(0.18), lineWidth: 3).padding(-2.5) } }
        .overlay(alignment: .leading) { if selected { trimHandle(sel: .base(clip.id), leftEdge: true, factor: clip.clampedSpeed, left: clip.inPoint, right: clip.outPoint, height: mainH) } }
        .overlay(alignment: .trailing) { if selected { trimHandle(sel: .base(clip.id), leftEdge: false, factor: clip.clampedSpeed, left: clip.inPoint, right: clip.outPoint, height: mainH) } }
        .overlay(alignment: .topTrailing) { if !selected && clipIsTrimmed(clip) { trimmedBadge } }
        .contentShape(Rectangle())
        .onTapGesture { select(.base(clip.id)) }
        .opacity(dim(forBase: clip.id))
        .shadow(color: Color.veCharcoal.opacity(isLifted(.base(clip.id)) ? 0.3 : 0), radius: isLifted(.base(clip.id)) ? 10 : 0, y: 5)
        .simultaneousGesture(liftGesture(.base(clip.id), baseStart: baseStart(clip)))
    }

    /// ✂️ breadcrumb: this spine clip plays LESS than its full source segment (an AI trim or a Sort
    /// choice) — there's hidden footage recoverable by selecting the tile and dragging its trim
    /// handles outward. Hidden while selected so it never sits on top of the handles.
    private func clipIsTrimmed(_ clip: Clip) -> Bool {
        guard let s = store?.segment(clip.sourceSegmentId) else { return false }
        return clip.inPoint > s.startSeconds + 0.05 || clip.outPoint < s.endSeconds - 0.05
    }

    private var trimmedBadge: some View {
        Image(systemName: "scissors")
            .font(.system(size: 6.5, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 13, height: 13)
            .background(Color.veCharcoal.opacity(0.55), in: Circle())
            .padding(2)
            .allowsHitTesting(false)
    }

    private func brollChip(_ o: OverlayClip) -> some View {
        let w = max(3, CGFloat(displayDur(forOverlay: o)) * pps)
        let seg = store?.segment(o.sourceSegmentId)
        let selected = selection == .overlay(o.id)
        return ZStack(alignment: .bottomLeading) {
            if let img = thumbs[o.sourceSegmentId] { Image(uiImage: img).resizable().scaledToFill() }
            else { (seg?.sceneType.foodTone ?? .cheese).gradient }
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 4) {
                if o.volume <= 0.001 { Image(systemName: "speaker.slash.fill").font(.system(size: 7, weight: .bold)) }
                Text(tileLabel(seg)).font(VeFont.sans(7).italic()).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 5).padding(.bottom, 2)
        }
        .frame(width: w, height: brollH)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(selected ? Color.veTerracotta : Color.veCharcoal.opacity(0.1), lineWidth: selected ? 2 : 1)
        )
        .overlay { if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.veTerracotta.opacity(0.18), lineWidth: 3).padding(-2.5) } }
        .overlay(alignment: .leading) { if selected { trimHandle(sel: .overlay(o.id), leftEdge: true, factor: 1, left: o.startOnBase, right: o.endOnBase, height: brollH) } }
        .overlay(alignment: .trailing) { if selected { trimHandle(sel: .overlay(o.id), leftEdge: false, factor: 1, left: o.startOnBase, right: o.endOnBase, height: brollH) } }
        .contentShape(Rectangle())
        .onTapGesture { select(.overlay(o.id)) }
        .opacity(dim(forOverlay: o.id))
        .shadow(color: Color.veCharcoal.opacity(isLifted(.overlay(o.id)) ? 0.3 : 0), radius: isLifted(.overlay(o.id)) ? 10 : 0, y: 5)
        .simultaneousGesture(liftGesture(.overlay(o.id), baseStart: o.startOnBase))
    }

    private func tileLabel(_ seg: Segment?) -> String {
        guard let seg else { return "clip" }
        return seg.description.isEmpty ? seg.sceneType.label : seg.description
    }

    // MARK: - Voiceover track (recorded narration takes)

    /// The VOICEOVER lane: sage waveform chips, one per take, plus a live terracotta ghost chip that
    /// grows under the playhead while a take is being recorded. Chips select on tap, hold-lift to move
    /// (horizontal only — takes never promote to other lanes), and edge-trim when selected.
    private func narrationLaneView(_ laneW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(store?.narrationLane ?? []) { clip in
                narrationChip(clip)
                    .scaleEffect(isLifted(.narration(clip.id)) ? 1.08 : 1)
                    .offset(x: xFor(displayStart(forNarration: clip), laneW))
                    .zIndex(isLifted(.narration(clip.id)) ? 10 : 1)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if narration.phase == .recording, let start = takeStart {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.veTerracotta.opacity(0.22))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.veTerracotta.opacity(0.55), lineWidth: 1))
                    .frame(width: max(3, CGFloat(narration.elapsed) * pps), height: narrationH)
                    .offset(x: xFor(start, laneW))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: store?.narrationLane)
    }

    private func narrationChip(_ clip: NarrationClip) -> some View {
        let w = max(3, CGFloat(displayDur(forNarration: clip)) * pps)
        let selected = selection == .narration(clip.id)
        let muted = clip.volume <= 0.001
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.veSage.opacity(0.18))
            WaveformBar(color: Color.veSage.opacity(muted ? 0.22 : 0.62), seed: abs(clip.id.hashValue % 97) + 1)
                .padding(.horizontal, 3).padding(.vertical, 3)
            HStack(spacing: 3) {
                if muted { Image(systemName: "speaker.slash.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(Color.veSage) }
                Text(String(format: "%.1fs", displayDur(forNarration: clip)))
                    .font(VeFont.mono(7, weight: .semibold)).foregroundStyle(Color(hex: 0x50604A))
            }
            .padding(.leading, 4).padding(.bottom, 2)
        }
        .frame(width: w, height: narrationH)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(selected ? Color.veTerracotta : Color.veSage.opacity(0.45), lineWidth: selected ? 2 : 1)
        )
        .overlay { if selected { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.veTerracotta.opacity(0.18), lineWidth: 3).padding(-2.5) } }
        .overlay {
            // "Will snap" cue: a lifted chip hovering over another take lands flush beside it on drop.
            if isLifted(.narration(clip.id)) && liftedNarrationOverlaps {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.veTerracotta, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
        }
        .overlay(alignment: .leading) { if selected { trimHandle(sel: .narration(clip.id), leftEdge: true, factor: 1, left: clip.startOnBase, right: clip.endOnBase, height: narrationH) } }
        .overlay(alignment: .trailing) { if selected { trimHandle(sel: .narration(clip.id), leftEdge: false, factor: 1, left: clip.startOnBase, right: clip.endOnBase, height: narrationH) } }
        .contentShape(Rectangle())
        .onTapGesture { select(.narration(clip.id)) }
        .opacity(dim(forNarration: clip.id))
        .shadow(color: Color.veCharcoal.opacity(isLifted(.narration(clip.id)) ? 0.3 : 0),
                radius: isLifted(.narration(clip.id)) ? 10 : 0, y: 5)
        .simultaneousGesture(liftGesture(.narration(clip.id), baseStart: clip.startOnBase))
    }

    /// True while a lifted narration chip's proposed position overlaps another take (drives the dashed
    /// stroke; the store snap resolves it on drop).
    private var liftedNarrationOverlaps: Bool {
        guard let l = lift, case .narration(let nid) = l.sel, let store,
              let c = store.narrationLane.first(where: { $0.id == nid }) else { return false }
        let s = displayStart(forNarration: c)
        return store.narrationLane.contains { $0.id != nid && s < $0.endOnBase && $0.startOnBase < s + c.duration }
    }

    // MARK: - Text track (chips) + canvas gizmo

    private func textLane(_ laneW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(store?.textOverlays ?? []) { o in
                textChip(o)
                    .scaleEffect(isLifted(.text(o.id)) ? 1.08 : 1)
                    .offset(x: xFor(displayStart(forText: o), laneW), y: liftY(.text(o.id)))
                    .zIndex(isLifted(.text(o.id)) ? 10 : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A small ochre/terracotta chip in the TEXT lane (mockup Frame 1) — tap selects, hold lifts.
    private func textChip(_ o: TextOverlay) -> some View {
        let w = max(10, CGFloat(displayDur(forText: o)) * pps)
        let selected = selection == .text(o.id)
        return HStack(spacing: 4) {
            TrackIcon(kind: .text, color: Color(hex: 0x9A5A40), side: 8)
            Text(o.string.isEmpty ? "Text" : o.string)
                .font(VeFont.sans(8, weight: .semibold)).foregroundStyle(Color(hex: 0x9A5A40)).lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(width: w, height: textH, alignment: .leading)
        .background(Color.veTerracotta.opacity(0.16), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(selected ? Color.veTerracotta : Color.veTerracotta.opacity(0.34), lineWidth: selected ? 1.6 : 1)
        )
        .overlay(alignment: .leading) { if selected { trimHandle(sel: .text(o.id), leftEdge: true, factor: 1, left: o.startTime, right: o.endTime, height: textH) } }
        .overlay(alignment: .trailing) { if selected { trimHandle(sel: .text(o.id), leftEdge: false, factor: 1, left: o.startTime, right: o.endTime, height: textH) } }
        .contentShape(Rectangle())
        .onTapGesture { select(.text(o.id)) }
        .opacity(dim(forText: o.id))
        .simultaneousGesture(liftGesture(.text(o.id), baseStart: o.startTime))
    }

    /// All captions drawn over the player; the selected one gets a draggable move/resize/rotate gizmo.
    @ViewBuilder private var textCanvas: some View {
        if let store {
            GeometryReader { pg in
                let sz = pg.size
                ForEach(store.textOverlays) { o in
                    if selection == .text(o.id) {
                        textGizmo(o, in: sz)
                    } else if o.isVisible(at: playheadTime) {
                        overlayTextView(o, pointSize: CGFloat(o.fontSize) * sz.height)
                            .rotationEffect(.radians(o.rotation))
                            .position(textPoint(o, in: sz))
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// The styled caption itself (shared shape between the preview label and the gizmo).
    private func overlayTextView(_ o: TextOverlay, pointSize: CGFloat) -> some View {
        Text(o.string.isEmpty ? "Tap to edit" : o.string)
            .font(o.font.swiftUIFont(size: pointSize, weight: o.weight))
            .foregroundStyle(o.color.swiftUI)
            .multilineTextAlignment(o.alignment.swiftUI)
            .fixedSize()
            .shadow(color: .black.opacity(o.outline ? 0.75 : 0.3), radius: o.outline ? 2 : 3, x: 0, y: o.outline ? 0 : 1)
            .padding(.horizontal, o.background ? pointSize * 0.42 : 0)
            .padding(.vertical, o.background ? pointSize * 0.2 : 0)
            .background {
                if o.background {
                    RoundedRectangle(cornerRadius: pointSize * 0.3, style: .continuous).fill(Color.black.opacity(0.42))
                }
            }
    }

    private func textGizmo(_ o: TextOverlay, in sz: CGSize) -> some View {
        let center = textPoint(o, in: sz)
        return overlayTextView(o, pointSize: CGFloat(o.fontSize) * sz.height)
            .padding(7)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.veTerracotta, lineWidth: 1.5))
            // ✕ delete (tap) and the corner handles. Handles use .highPriorityGesture so a drag that
            // STARTS on a handle does resize/rotate instead of the body move.
            .overlay(alignment: .topLeading) { gizmoHandle("xmark", offset: -11).onTapGesture { deleteSelected() } }
            .overlay(alignment: .bottomTrailing) {
                gizmoHandle("arrow.clockwise", offset: 11).highPriorityGesture(rotateDrag(o, center: center))
            }
            .overlay(alignment: .topTrailing) { gizmoDot(dx: 7, dy: -7).highPriorityGesture(resizeDrag(o, center: center)) }
            .overlay(alignment: .bottomLeading) { gizmoDot(dx: -7, dy: 7).highPriorityGesture(resizeDrag(o, center: center)) }
            .rotationEffect(.radians(o.rotation))
            .position(center)
            // One-finger drag = move; pinch = resize; two-finger twist = rotate (all coexist).
            .gesture(moveDrag(o, in: sz))
            .simultaneousGesture(pinchResize(o))
            .simultaneousGesture(twoFingerRotate(o))
            .onTapGesture { editingText = o.id; textTab = .keyboard; textSessionPushed = false }
    }

    private func gizmoHandle(_ icon: String, offset: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.veTerracotta)
            .frame(width: 22, height: 22).background(Color.white, in: Circle())
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .padding(6).contentShape(Rectangle())       // 34pt touch target
            .offset(x: offset, y: offset)
    }

    private func gizmoDot(dx: CGFloat, dy: CGFloat) -> some View {
        Circle().fill(Color.white).overlay(Circle().stroke(Color.veTerracotta, lineWidth: 1.5))
            .frame(width: 14, height: 14)
            .padding(9).contentShape(Rectangle())        // 32pt touch target around the small dot
            .offset(x: dx, y: dy)
    }

    private func textPoint(_ o: TextOverlay, in sz: CGSize) -> CGPoint {
        let cw = contentWidth(sz)
        return CGPoint(x: (sz.width - cw) / 2 + CGFloat(o.centerX) * cw, y: CGFloat(o.centerY) * sz.height)
    }
    /// The 9:16 video content rect's width inside the (possibly wider) preview mat.
    private func contentWidth(_ sz: CGSize) -> CGFloat { min(sz.width, sz.height * 9.0 / 16.0) }

    private func beginTextEdit(_ o: TextOverlay, center: CGPoint, loc: CGPoint) {
        guard textEditStart == nil else { return }
        store?.pushUndo()
        let dist = Double(hypot(loc.x - center.x, loc.y - center.y))
        let angle = Double(atan2(loc.y - center.y, loc.x - center.x))
        textEditStart = TextEditStart(cx: o.centerX, cy: o.centerY, size: o.fontSize,
                                      dist: max(1, dist), angleOffset: angle - o.rotation)
    }

    private func moveDrag(_ o: TextOverlay, in sz: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(previewSpace))
            .onChanged { v in
                beginTextEdit(o, center: textPoint(o, in: sz), loc: v.location)
                guard let s = textEditStart else { return }
                let cw = contentWidth(sz)
                let nx = s.cx + Double(v.translation.width) / Double(cw)
                let ny = s.cy + Double(v.translation.height) / Double(sz.height)
                store?.updateTextOverlay(o.id) { $0.centerX = min(1, max(0, nx)); $0.centerY = min(1, max(0, ny)) }
            }
            .onEnded { _ in textEditStart = nil }
    }

    private func resizeDrag(_ o: TextOverlay, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(previewSpace))
            .onChanged { v in
                beginTextEdit(o, center: center, loc: v.location)
                guard let s = textEditStart else { return }
                let dist = Double(hypot(v.location.x - center.x, v.location.y - center.y))
                store?.updateTextOverlay(o.id) { $0.fontSize = min(0.3, max(0.02, s.size * dist / s.dist)) }
            }
            .onEnded { _ in textEditStart = nil }
    }

    private func rotateDrag(_ o: TextOverlay, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(previewSpace))
            .onChanged { v in
                beginTextEdit(o, center: center, loc: v.location)
                guard let s = textEditStart else { return }
                let angle = Double(atan2(v.location.y - center.y, v.location.x - center.x))
                let target = snappedRotation(angle - s.angleOffset)
                store?.updateTextOverlay(o.id) { $0.rotation = target }
            }
            .onEnded { _ in textEditStart = nil; textRotateSnapped = false }
    }

    /// Snap rotation to the nearest **horizontal** (multiple of π) within a small detent, holding there
    /// with a haptic tick when it catches — so it's easy to twist a caption back to level.
    private func snappedRotation(_ raw: Double) -> Double {
        let detent = 0.12   // ~7°
        let nearest = (raw / .pi).rounded() * .pi
        if abs(raw - nearest) < detent {
            if !textRotateSnapped { textRotateSnapped = true; UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
            return nearest
        }
        textRotateSnapped = false
        return raw
    }

    /// Pinch the caption directly to grow/shrink it.
    private func pinchResize(_ o: TextOverlay) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if textPinchStart == nil { beginTwoFinger(); textPinchStart = o.fontSize }
                let base = textPinchStart ?? o.fontSize
                store?.updateTextOverlay(o.id) { $0.fontSize = min(0.3, max(0.02, base * Double(scale))) }
            }
            .onEnded { _ in textPinchStart = nil }
    }

    /// Two-finger twist to rotate the caption (with horizontal snap).
    private func twoFingerRotate(_ o: TextOverlay) -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                if textRotateStart == nil { beginTwoFinger(); textRotateStart = o.rotation }
                let base = textRotateStart ?? o.rotation
                let target = snappedRotation(base + angle.radians)
                store?.updateTextOverlay(o.id) { $0.rotation = target }
            }
            .onEnded { _ in textRotateStart = nil; textRotateSnapped = false }
    }

    /// Push undo once for a combined pinch+rotate (only if neither is already active).
    private func beginTwoFinger() {
        if textPinchStart == nil && textRotateStart == nil { store?.pushUndo() }
    }

    private func playhead(_ color: Color) -> some View {
        let flashing = splitFlash != nil
        return VStack(spacing: 0) {
            Triangle().fill(color).frame(width: 11, height: 7)
            Rectangle().fill(color).frame(width: 2)
        }
        .frame(width: 11)
        .padding(.top, rulerH)
        .shadow(color: color.opacity(flashing ? 0.55 : 0.3), radius: flashing ? 7 : 4)
        .allowsHitTesting(false)
    }

    private var scissorBadge: some View {
        Image(systemName: "scissors")
            .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
            .frame(width: 22, height: 22)
            .background(Color.veTerracotta, in: Circle())
            .shadow(color: Color.veTerracotta.opacity(0.45), radius: 6, y: 2)
    }

    /// "Split at MM:SS:FF · N clips" — a white pill pinned at the timeline bottom-center for ~1.5s.
    private func splitToast(_ flash: SplitFlash) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Color.veTerracotta)
            (Text("Split at ").font(VeFont.sans(11, weight: .medium)).foregroundStyle(Color.veCharcoal)
             + Text(timecode(flash.time)).font(VeFont.mono(11)).foregroundStyle(Color.veTerracotta)
             + Text(" · \(flash.clips) clips").font(VeFont.sans(11, weight: .medium)).foregroundStyle(Color.veCharcoal))
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.veTerracotta.opacity(0.3), lineWidth: 1))
        .shadow(color: Color.veCharcoal.opacity(0.18), radius: 12, y: 6)
        .fixedSize()
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarItem(.split, "Split", active: (store?.baseDuration ?? 0) > 0) { splitAtPlayhead() }
            toolbarItem(.trim, "Trim", active: selection != nil) { trimAction() }
            toolbarItem(.speed, "Speed", active: inspector == .speed) { openInspector(.speed) }
            toolbarItem(.text, "Text", active: isTextSelected) { addText() }
            toolbarItem(.volume, "Volume", active: inspector == .volume) { openInspector(.volume) }
            toolbarItem(.record, "Voiceover", active: inspector == .record) { openRecordPanel() }
            toolbarItem(.cleanVoice, "Clean", active: inspector == .voice) {
                guard store != nil, !narration.isBusy else { return }
                inspector = (inspector == .voice) ? nil : .voice
            }
            toolbarItem(.delete, "Delete", active: selection != nil) { deleteSelected() }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 28)
        .frame(maxWidth: .infinity)
        .background(Color.veCream)
        .overlay(alignment: .top) { Rectangle().fill(Color.veCharcoal.opacity(0.1)).frame(height: 1) }
    }

    private func toolbarItem(_ kind: ToolIcon.Kind, _ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ToolIcon(kind: kind, color: active ? Color.veTerracotta : Color.veNoteText)
                Text(label)
                    .font(VeFont.sans(9.5, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.veTerracotta : Color(hex: 0x9A98A0))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Geometry helpers

    /// Lane-x for a base time `t` (relative to the lane's left edge, after the gutter).
    private func xFor(_ t: Double, _ laneW: CGFloat) -> CGFloat { laneW / 2 - scrollX + CGFloat(t) * pps }
    private func baseStart(_ clip: Clip) -> Double { store?.baseStart(of: clip.id) ?? 0 }
    private func clampScroll(_ x: CGFloat) -> CGFloat { max(0, min(x, CGFloat(total) * pps)) }

    /// Is this spine clip's source range fully covered by a cleaned-voice span? (Visual indicator only —
    /// not gated on the toggle so the bars reflect what's been isolated.)
    private func isClipCleaned(_ clip: Clip) -> Bool {
        store?.isolatedAudio.contains { $0.startProxy <= clip.inPoint + 0.01 && $0.endProxy >= clip.outPoint - 0.01 } ?? false
    }

    /// The Audio track's body (mockup Frame 1): a faux voice waveform under every spine clip — terracotta
    /// by default, **green** where that clip's voice has been cleaned (Cleaned toggle on), and faded for
    /// muted clips. The bar heights are decorative (deterministic per clip, not sampled) but the segments
    /// track the real cut, so muted/cleaned state and clip boundaries read at a glance.
    @ViewBuilder
    private func audioLaneContent(_ laneW: CGFloat) -> some View {
        if let store, !store.order.isEmpty {
            ZStack(alignment: .topLeading) {
                ForEach(Array(store.order.enumerated()), id: \.element.id) { idx, clip in
                    let cleaned = store.useIsolatedAudio && isClipCleaned(clip)
                    let muted = clip.clampedVolume <= 0.001 || store.originalAudioMuted   // track-mute fades the whole lane
                    let tint = cleaned ? Color.veSage : Color.veTerracotta
                    let w = max(2, CGFloat(clip.timelineDuration) * pps - 2)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.12))
                        WaveformBar(color: tint.opacity(muted ? 0.18 : 0.5), seed: idx + 1)
                            .padding(.horizontal, 3)
                    }
                    .frame(width: w, height: audioH - 4)
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(tint.opacity(0.24), lineWidth: 1))
                    .offset(x: xFor(store.baseStart(of: clip.id), laneW) + 1, y: 2)
                }
            }
            .frame(width: laneW, height: audioH, alignment: .topLeading)
        } else {
            Color.clear
        }
    }

    // MARK: - Scrub / transport actions

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if zooming || lifting || narration.isBusy { return }
                if !scrubbing { scrubbing = true; scrubStartX = scrollX; previewPlaying = false; player.pause() }
                scrollX = clampScroll(scrubStartX - v.translation.width)
                seekPlayerOnly(to: playheadTime)
            }
            .onEnded { _ in scrubbing = false }
    }

    /// Pinch to zoom the timeline toward frame level. The time under the playhead stays pinned.
    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if narration.isBusy { return }
                if !zooming { zooming = true; zoomBasePps = pps; zoomAnchorTime = playheadTime }
                pps = clampPps(zoomBasePps * scale)
                scrollX = clampScroll(CGFloat(zoomAnchorTime) * pps)
            }
            .onEnded { _ in zooming = false }
    }

    /// 8 pt/s (a ~minute fits) up to 1320 pt/s (one 30fps frame ≈ 44 pt — comfortably tappable).
    private func clampPps(_ v: CGFloat) -> CGFloat { max(8, min(v, 1320)) }

    private func togglePlay() {
        guard !narration.isBusy else { return }
        previewPlaying.toggle()
        if previewPlaying {
            if playheadTime >= total - 0.05 { scrollX = 0; player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    private func step(by frames: Int) {
        guard !narration.isBusy else { return }
        previewPlaying = false; player.pause()
        let snapped = (playheadTime * 30).rounded() / 30
        let t = max(0, min(snapped + Double(frames) * oneFrame, total))
        scrollX = clampScroll(CGFloat(t) * pps)
        seekPlayerOnly(to: t)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func select(_ sel: Selection) {
        guard !narration.isBusy else { return }   // selection swaps the inspector away mid-take
        selection = (selection == sel) ? nil : sel
        if selection == nil { inspector = nil; editingText = nil }
        else if case .text(let tid) = selection { editingText = tid; textTab = .keyboard; textSessionPushed = false }
        else { editingText = nil }
        // Picking a clip while the Voiceover panel is up → show THAT clip's volume, not the master
        // (the master row showing 20% next to a clip was read as the clip's own level).
        if selection != nil, inspector == .record { inspector = .volume }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private var isTextSelected: Bool { if case .text = selection { return true }; return false }

    /// Add a caption at the playhead, select it, and open the text editor.
    private func addText() {
        guard let store, total > 0, !narration.isBusy else { return }
        store.pushUndo()
        previewPlaying = false; player.pause()
        let id = store.addTextOverlay(at: playheadTime)
        // Pre-seed the creator's WRITTEN signature on their first overlay: the learned text format
        // (e.g. "CRAVING SCORE: __") lands ready to edit instead of "Tap to edit" — the reproduction
        // rail for text-overlay signature lines (FirstCutView's style note points here).
        if store.textOverlays.count == 1,
           let sig = templates.active?.profile.verbalStyle.recurringLines.first(where: {
               $0.medium == "text-overlay" && $0.confirmation != "out" && !$0.quote.isEmpty
           }) {
            let text = (sig.pattern?.isEmpty == false) ? sig.pattern! : sig.quote
            store.updateTextOverlay(id) { $0.string = text }
        }
        selection = .text(id); inspector = nil
        textTab = .keyboard; textSessionPushed = true   // the add already pushed undo
        editingText = id
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: - Trim / delete (CP3.3)

    /// A terracotta edge handle on a selected clip; dragging it trims that edge live (committed to the
    /// store; the preview rebuilds on release).
    private func trimHandle(sel: Selection, leftEdge: Bool, factor: Double,
                            left: Double, right: Double, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.veTerracotta)
            .frame(width: 13, height: height + 4)
            .overlay(Capsule().fill(Color.veOnTerracotta.opacity(0.75)).frame(width: 2, height: height * 0.42))
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(timelineSpace))
                    .onChanged { v in
                        if trimDrag == nil {
                            store?.pushUndo()
                            trimDrag = TrimDrag(sel: sel, leftEdge: leftEdge, baseLeft: left, baseRight: right, factor: factor)
                            trimming = true; previewPlaying = false; player.pause()
                        }
                        trimDrag?.dx = v.translation.width
                    }
                    .onEnded { _ in commitTrim() }
            )
    }

    private func commitTrim() {
        guard let d = trimDrag, let store else { trimDrag = nil; trimming = false; return }
        let disp = trimDisplay(d)
        switch d.sel {
        case .base(let cid):
            if d.leftEdge { store.setIn(cid, toSource: disp.lo) } else { store.setOut(cid, toSource: disp.hi) }
        case .overlay(let oid):
            if d.leftEdge { store.setOverlayLeftEdge(oid, toStart: disp.lo) }
            else { store.setOverlayRightEdge(oid, toEnd: disp.hi) }
        case .text(let tid):
            store.setTextBounds(tid, start: disp.lo, end: disp.hi)
        case .narration(let nid):
            store.setNarrationBounds(nid, start: disp.lo, end: disp.hi)
        }
        trimDrag = nil; trimming = false
        if case .text = d.sel {} else { rebuildTick += 1 }   // text isn't in the render model — no rebuild
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Clamped display (lo, hi) for the active trim — in/out for base clips, start/end for overlays.
    private func trimDisplay(_ d: TrimDrag) -> (lo: Double, hi: Double) {
        guard let store else { return (d.baseLeft, d.baseRight) }
        let delta = Double(d.dx / pps) * d.factor
        switch d.sel {
        case .base(let cid):
            guard let clip = store.order.first(where: { $0.id == cid }), let s = store.segment(clip.sourceSegmentId)
            else { return (d.baseLeft, d.baseRight) }
            if d.leftEdge { return (min(max(d.baseLeft + delta, s.startSeconds), d.baseRight - oneFrame), d.baseRight) }
            return (d.baseLeft, max(min(d.baseRight + delta, s.endSeconds), d.baseLeft + oneFrame))
        case .overlay(let oid):
            guard let o = store.brollLane.first(where: { $0.id == oid }), let seg = store.segment(o.sourceSegmentId)
            else { return (d.baseLeft, d.baseRight) }
            let inNow = store.overlaySourceStart(o)
            let segStart = seg.startSeconds
            let segEnd = segStart + store.sourceLength(o.sourceSegmentId)
            // Left edge: advance the in-point (crop head). Can extend left only as far as unused source head.
            if d.leftEdge {
                let minStart = max(0, d.baseLeft - (inNow - segStart))
                return (min(max(d.baseLeft + delta, minStart), d.baseRight - 0.3), d.baseRight)
            }
            // Right edge: fixed in-point, grow only to the available source tail.
            let maxEnd = min(total, d.baseLeft + (segEnd - inNow))
            return (d.baseLeft, max(min(d.baseRight + delta, maxEnd), d.baseLeft + 0.3))
        case .text:
            // captions can span any sub-range of the timeline (no source-length limit)
            if d.leftEdge { return (min(max(d.baseLeft + delta, 0), d.baseRight - 0.3), d.baseRight) }
            return (d.baseLeft, max(min(d.baseRight + delta, total), d.baseLeft + 0.3))
        case .narration(let nid):
            guard let c = store.narrationLane.first(where: { $0.id == nid }) else { return (d.baseLeft, d.baseRight) }
            let others = store.narrationLane.filter { $0.id != nid }
            let prevEnd = others.filter { $0.startOnBase < c.startOnBase }.map(\.endOnBase).max() ?? 0
            let nextStart = others.filter { $0.startOnBase > c.startOnBase }.map(\.startOnBase).min() ?? total
            if d.leftEdge {
                // Left edge trims the file head (picture-sync) — it can re-extend left only as far as
                // unused head exists, and never into the previous take.
                let minStart = max(0, max(prevEnd, d.baseLeft - c.inPoint))
                return (min(max(d.baseLeft + delta, minStart), d.baseRight - 0.3), d.baseRight)
            }
            // Right edge grows only to the file's remaining tail, the next take, or the video's end.
            let maxEnd = min(min(nextStart, total), d.baseLeft + (c.fileDuration - c.inPoint))
            return (d.baseLeft, max(min(d.baseRight + delta, maxEnd), d.baseLeft + 0.3))
        }
    }

    // MARK: - Lift move (B-roll) / reorder (Main) + display geometry

    private func isLifted(_ sel: Selection) -> Bool { lift?.sel == sel }
    private func isTrimming(_ sel: Selection) -> Bool { trimDrag?.sel == sel }
    /// A Main clip lifted on the spine may move up (reorder hint) OR down (drop to B-roll); overlay/text
    /// stay clamped to non-positive (up only); narration is horizontal-only (takes never change lanes).
    private func liftY(_ sel: Selection) -> CGFloat {
        guard lift?.sel == sel else { return 0 }
        if case .narration = sel { return 0 }
        if case .base = sel { return lift!.t.height }
        return min(0, lift!.t.height)
    }

    /// True while a Main clip is being dragged far enough DOWN to drop it onto the B-roll lane. Guarded
    /// so the last remaining spine clip can't be pulled off (that would leave an empty timeline).
    private var draggingBaseToBroll: Bool {
        guard let l = lift, case .base = l.sel else { return false }
        return l.t.height > brollDropThreshold && (store?.order.count ?? 0) > 1
    }

    /// True while a B-roll overlay chip is dragged far enough UP to drop it onto the Main spine (the
    /// mirror of `draggingBaseToBroll`). On commit it's promoted to a real spine clip via `unmarkBroll`.
    private var draggingBrollToMain: Bool {
        guard let l = lift, case .overlay = l.sel else { return false }
        return l.t.height < -mainPromoteThreshold
    }

    /// Spine index where a promoting B-roll chip will land — from the chip's center mapped to base time.
    private func promoteInsertionIndex() -> Int? {
        guard draggingBrollToMain, let l = lift, case .overlay(let oid) = l.sel,
              let store, let o = store.brollLane.first(where: { $0.id == oid }) else { return nil }
        let dropCenter = displayStart(forOverlay: o) + o.duration / 2
        var idx = 0
        for c in store.order where baseStart(c) + c.timelineDuration / 2 < dropCenter { idx += 1 }
        return idx
    }

    /// The gap (insertion index + chip width in seconds) the Main lane opens up while promoting, so the
    /// right-side clips slide right to make room. Reused by `displayStart(forBase:)` and the insertion bar.
    private var mainPromoteGap: (index: Int, dur: Double)? {
        guard let idx = promoteInsertionIndex(), let l = lift, case .overlay(let oid) = l.sel,
              let o = store?.brollLane.first(where: { $0.id == oid }) else { return nil }
        return (idx, o.duration)
    }

    /// Display start (base time) for a Main clip — dragged clip follows the finger, others reflow.
    /// While the **left** handle is trimmed, the left edge follows the finger (right edge stays put); it
    /// settles back into the contiguous spine on release.
    private func displayStart(forBase clip: Clip) -> Double {
        if let l = lift, case .base(let did) = l.sel {
            if clip.id == did { return baseStart(clip) + Double((l.t.width + autoPanX) / pps) }
            return previewBaseStart(clip)
        }
        if let d = trimDrag, d.sel == .base(clip.id), d.leftEdge {
            return baseStart(clip) + (trimDisplay(d).lo - clip.inPoint) / clip.clampedSpeed
        }
        // Promoting a B-roll chip onto the spine: clips at/after the insertion slide right to open a gap.
        if let gap = mainPromoteGap, let idx = store?.order.firstIndex(where: { $0.id == clip.id }), idx >= gap.index {
            return baseStart(clip) + gap.dur
        }
        return baseStart(clip)
    }
    private func displayDur(forBase clip: Clip) -> Double {
        if let d = trimDrag, d.sel == .base(clip.id) { let t = trimDisplay(d); return (t.hi - t.lo) / clip.clampedSpeed }
        return clip.timelineDuration
    }
    private func displayStart(forOverlay o: OverlayClip) -> Double {
        if let d = trimDrag, d.sel == .overlay(o.id) { return trimDisplay(d).lo }
        if let l = lift, l.sel == .overlay(o.id) {
            return max(0, min(o.startOnBase + Double((l.t.width + autoPanX) / pps), max(0, total - o.duration)))
        }
        return o.startOnBase
    }
    private func displayDur(forOverlay o: OverlayClip) -> Double {
        if let d = trimDrag, d.sel == .overlay(o.id) { let t = trimDisplay(d); return t.hi - t.lo }
        return o.duration
    }
    private func displayStart(forNarration c: NarrationClip) -> Double {
        if let d = trimDrag, d.sel == .narration(c.id) { return trimDisplay(d).lo }
        if let l = lift, l.sel == .narration(c.id) {
            return max(0, min(c.startOnBase + Double((l.t.width + autoPanX) / pps), max(0, total - c.duration)))
        }
        return c.startOnBase
    }
    private func displayDur(forNarration c: NarrationClip) -> Double {
        if let d = trimDrag, d.sel == .narration(c.id) { let t = trimDisplay(d); return t.hi - t.lo }
        return c.duration
    }
    private func displayStart(forText o: TextOverlay) -> Double {
        if let d = trimDrag, d.sel == .text(o.id) { return trimDisplay(d).lo }
        if let l = lift, l.sel == .text(o.id) {
            return max(0, min(o.startTime + Double((l.t.width + autoPanX) / pps), max(0, total - o.duration)))
        }
        return o.startTime
    }
    private func displayDur(forText o: TextOverlay) -> Double {
        if let d = trimDrag, d.sel == .text(o.id) { let t = trimDisplay(d); return t.hi - t.lo }
        return o.duration
    }

    /// Main reorder: insertion index among the other clips for the dragged clip's current center.
    private func mainInsertionIndex() -> Int? {
        if draggingBaseToBroll { return nil }   // dragging down to B-roll, not reordering the spine
        guard let l = lift, case .base(let cid) = l.sel, let store,
              let dc = store.order.first(where: { $0.id == cid }) else { return nil }
        let center = baseStart(dc) + Double((l.t.width + autoPanX) / pps) + dc.timelineDuration / 2
        var idx = 0
        for c in store.order where c.id != cid {
            if baseStart(c) + c.timelineDuration / 2 < center { idx += 1 }
        }
        return idx
    }

    /// Order as it will be after the drop — used to reflow the non-dragged clips live.
    private var mainPreviewOrder: [Clip] {
        guard let store else { return [] }
        guard let l = lift, case .base(let cid) = l.sel, let idx = mainInsertionIndex() else { return store.order }
        var arr = store.order
        guard let cur = arr.firstIndex(where: { $0.id == cid }) else { return arr }
        let c = arr.remove(at: cur)
        arr.insert(c, at: max(0, min(idx, arr.count)))
        return arr
    }
    private func previewBaseStart(_ clip: Clip) -> Double {
        var t = 0.0
        for c in mainPreviewOrder { if c.id == clip.id { return t }; t += c.timelineDuration }
        return t
    }
    /// Base time for the reorder insertion bar, or nil when not reordering a Main clip.
    private var mainInsertionBarTime: Double? {
        if let gap = mainPromoteGap, let store {       // promoting a B-roll chip onto the spine
            return store.order.prefix(gap.index).reduce(0.0) { $0 + $1.timelineDuration }
        }
        guard let l = lift, case .base(let cid) = l.sel, let idx = mainInsertionIndex(), let store else { return nil }
        return store.order.filter { $0.id != cid }.prefix(idx).reduce(0.0) { $0 + $1.timelineDuration }
    }

    /// While a clip is lifted and the finger is in the left/right edge band, auto-scroll the timeline so
    /// the clip can be carried to the very front/end. We add the *applied* (clamped) scroll delta into
    /// `autoPanX`; because `xFor` subtracts `scrollX`, adding `autoPanX/pps` to the clip's displayed time
    /// (see the `displayStart` helpers) keeps it pinned under the finger while everything else scrolls.
    private func driveAutoScroll(fingerX: CGFloat) {
        // Only engage when the user is actually dragging the clip TOWARD that edge — otherwise grabbing a
        // clip that happens to sit near an edge (or dragging it straight down to demote) would wrongly
        // scroll the whole timeline back to the start.
        let dx = lift?.t.width ?? 0
        let movingLeft = dx < -8, movingRight = dx > 8
        autoScroller.onTick = { delta in
            let newX = clampScroll(scrollX + delta)
            autoPanX += (newX - scrollX)
            scrollX = newX
            seekPlayerOnly(to: playheadTime)
        }
        autoScroller.update(location: fingerX, viewportLength: laneWidth,
                            canScrollStart: scrollX > 0 && movingLeft,
                            canScrollEnd: scrollX < CGFloat(total) * pps && movingRight)
    }

    /// Hold (~0.3s) to lift a clip, then drag to move a B-roll clip or reorder a Main clip.
    private func liftGesture(_ sel: Selection, baseStart: Double) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value, !narration.isBusy else { return }
                if lift == nil {
                    lift = LiftDrag(sel: sel, baseStart: baseStart)
                    autoPanX = 0
                    selection = sel; inspector = nil
                    previewPlaying = false; player.pause()
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                lift?.t = drag?.translation ?? .zero
                driveAutoScroll(fingerX: (drag?.location.x ?? 0) - gutter)
            }
            .onEnded { _ in commitLift() }
    }

    private func commitLift() {
        autoScroller.stop()
        defer { autoPanX = 0 }
        guard let l = lift, let store else { lift = nil; return }
        // A lift with no real drag is just a selection — don't push a no-op onto the undo stack.
        guard abs(l.t.width) > 2 || abs(l.t.height) > 2 || autoPanX != 0 else { lift = nil; return }
        store.pushUndo()
        defer { lift = nil; if case .text = l.sel {} else { rebuildTick += 1 } }   // text isn't in the render model
        let dragX = Double((l.t.width + autoPanX) / pps)                            // includes any auto-scroll
        switch l.sel {
        case .overlay(let oid):
            if draggingBrollToMain, let o = store.brollLane.first(where: { $0.id == oid }),
               let idx = promoteInsertionIndex() {
                // Promote the chip onto the Main spine at the drop slot (mirror of base→B-roll demote).
                if let newId = store.unmarkBroll(o.sourceSegmentId, at: idx) { selection = .base(newId) }
                inspector = nil
            } else {
                let dur = store.brollLane.first(where: { $0.id == oid })?.duration ?? 0
                store.moveOverlay(oid, toStart: max(0, min(l.baseStart + dragX, max(0, total - dur))))
            }
        case .base(let cid):
            if draggingBaseToBroll, let clip = store.order.first(where: { $0.id == cid }) {
                // Dropped onto the B-roll lane → move the clip off the spine and place it there. Capture
                // the drop position BEFORE markBroll shortens the spine (which shifts baseDuration).
                let segId = clip.sourceSegmentId
                let dropStart = max(0, displayStart(forBase: clip))   // left edge in base seconds at release
                store.markBroll(segId)                                // pull off the spine (ripples the lane)
                store.addOverlay(sourceId: segId, at: dropStart)      // re-clamps to the now-shorter timeline
                if let newId = store.brollLane.last?.id { selection = .overlay(newId) }
                inspector = nil
            } else if let idx = mainInsertionIndex() {
                store.reorder(cid: cid, to: idx)
            }
        case .text(let tid):
            let dur = store.textOverlays.first(where: { $0.id == tid })?.duration ?? 0
            store.moveTextOverlay(tid, toStart: max(0, min(l.baseStart + dragX, max(0, total - dur))))
        case .narration(let nid):
            if let c = store.narrationLane.first(where: { $0.id == nid }) {
                // The store resolves any overlap by snapping flush beside the hit take (or reverting).
                store.moveNarration(nid, toStart: max(0, min(l.baseStart + dragX, max(0, total - c.duration))))
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func splitAtPlayhead() {
        guard !narration.isBusy else { return }
        let t = playheadTime
        // Split the SELECTED overlay/take when one is chosen (act on the highlighted clip, not the base
        // beneath it); otherwise split the base spine under the playhead as before.
        if case .overlay(let oid) = selection {
            guard let rightId = store?.splitOverlay(oid, at: t) else { return }
            selection = .overlay(rightId); rebuildTick += 1
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showSplitFlash(at: t)
            return
        }
        if case .narration(let nid) = selection {
            guard let rightId = store?.splitNarration(nid, at: t) else { return }
            selection = .narration(rightId); rebuildTick += 1
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            showSplitFlash(at: t)
            return
        }
        guard let rightId = store?.split(at: t) else { return }
        selection = .base(rightId); rebuildTick += 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        showSplitFlash(at: t)
    }

    /// Pop the scissor badge + toast, then auto-dismiss after ~1.5s (cancelling any prior flash).
    private func showSplitFlash(at t: Double) {
        splitFlashTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            splitFlash = SplitFlash(time: t, clips: store?.order.count ?? 0)
        }
        splitFlashTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run { withAnimation(.easeOut(duration: 0.3)) { splitFlash = nil } }
        }
    }

    /// Trim toolbar: select the clip under the playhead (or clear the current selection).
    private func trimAction() {
        guard !narration.isBusy else { return }
        if selection != nil { selection = nil }
        else if let cid = clipUnderPlayhead() { select(.base(cid)) }
    }

    private func clipUnderPlayhead() -> UUID? {
        guard let store else { return nil }
        var t = 0.0
        for c in store.order { if playheadTime < t + c.timelineDuration { return c.id }; t += c.timelineDuration }
        return store.order.last?.id
    }

    private func deleteSelected() {
        guard selection != nil, !narration.isBusy else { return }
        store?.pushUndo()
        switch selection {
        case .base(let cid): store?.deleteClip(cid)
        case .overlay(let oid): store?.removeOverlay(oid)
        case .text(let tid): store?.deleteTextOverlay(tid)
        case .narration(let nid): store?.removeNarration(nid)
        case .none: return
        }
        selection = nil; inspector = nil; editingText = nil; rebuildTick += 1
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func dim(forBase cid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .base(let s): return s == cid ? 1 : 0.5
        case .overlay, .text, .narration: return 0.42
        }
    }
    private func dim(forOverlay oid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .overlay(let s): return s == oid ? 1 : 0.5
        case .base, .text, .narration: return 0.42
        }
    }
    private func dim(forText tid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .text(let s): return s == tid ? 1 : 0.5
        case .base, .overlay, .narration: return 0.42
        }
    }
    private func dim(forNarration nid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .narration(let s): return s == nid ? 1 : 0.5
        case .base, .overlay, .text: return 0.42
        }
    }
    private var dimTextAudio: Double { selection == nil ? 1 : 0.42 }

    /// The selected clip's on-timeline duration — read through the live trim display so the bubble
    /// updates as you drag an edge.
    private var selectedDuration: Double? {
        switch selection {
        case .base(let cid):
            guard let clip = store?.order.first(where: { $0.id == cid }) else { return nil }
            return displayDur(forBase: clip)
        case .overlay(let oid):
            guard let o = store?.brollLane.first(where: { $0.id == oid }) else { return nil }
            return displayDur(forOverlay: o)
        case .text(let tid):
            guard let o = store?.textOverlays.first(where: { $0.id == tid }) else { return nil }
            return displayDur(forText: o)
        case .narration(let nid):
            guard let clip = store?.narrationLane.first(where: { $0.id == nid }) else { return nil }
            return clip.duration
        case .none: return nil
        }
    }

    private var durationBubble: some View {
        let d = selectedDuration ?? 0
        return Text("\(String(format: "%.1f", d))s · \(Int((d * 30).rounded()))f")
            .font(VeFont.mono(9.5, weight: .semibold)).foregroundStyle(Color.veOnTerracotta)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.25), radius: 6, y: 2)
    }

    // MARK: - Text editor sheet (Keyboard / Font / Style — mockup Frames A/B/C)

    private func closeTextEditor() {
        editingText = nil; textFieldFocused = false; textSessionPushed = false
    }

    /// Mutate the editing overlay, pushing undo once per edit session (so a whole styling pass is one undo).
    private func editText(_ mutate: (inout TextOverlay) -> Void) {
        guard let id = editingText, let store else { return }
        if !textSessionPushed { store.pushUndo(); textSessionPushed = true }
        store.updateTextOverlay(id, mutate)
    }

    private var editingOverlay: TextOverlay? {
        guard let id = editingText else { return nil }
        return store?.textOverlays.first { $0.id == id }
    }

    @ViewBuilder private var textEditorSheet: some View {
        if let o = editingOverlay {
            VStack(spacing: 0) {
                Color.clear.frame(height: 20)   // clear the sheet's drag grabber so the center "Font" tab is tappable
                HStack(spacing: 0) {
                    ForEach(TextTab.allCases) { tab in
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { textTab = tab }
                            textFieldFocused = (tab == .keyboard)
                        } label: {
                            Text(tab.rawValue)
                                .font(VeFont.sans(12.5, weight: textTab == tab ? .bold : .semibold))
                                .foregroundStyle(textTab == tab ? Color.veTerracotta : Color(hex: 0x9A968C))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .overlay(alignment: .bottom) { if textTab == tab { Rectangle().fill(Color.veTerracotta).frame(height: 2) } }
                        }.buttonStyle(.plain)
                    }
                }
                .overlay(alignment: .top) { Rectangle().fill(Color.veCharcoal.opacity(0.1)).frame(height: 1) }

                switch textTab {
                case .keyboard: keyboardTab(o)
                case .font:     fontTab(o)
                case .style:    styleTab(o)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(hex: 0xF2ECE1))
        }
    }

    private func keyboardTab(_ o: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Add text", text: Binding(get: { editingOverlay?.string ?? "" },
                                                set: { v in editText { $0.string = v } }), axis: .vertical)
                .font(VeFont.sans(17, weight: .semibold)).foregroundStyle(Color.veCharcoal)
                .focused($textFieldFocused)
                .textInputAutocapitalization(.sentences)
                .lineLimit(1...4)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.veCharcoal.opacity(0.1), lineWidth: 1))
                .onAppear { textFieldFocused = true }
            Text("Drag the caption on the video to move it; drag a corner dot to resize, the ↻ handle to rotate.")
                .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
        }
        .padding(16)
    }

    private func fontTab(_ o: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 11) {
                    ForEach(TextFontFamily.allCases) { fam in
                        Button { editText { $0.font = fam } } label: { fontCard(fam, selected: o.font == fam) }
                            .buttonStyle(.plain)
                    }
                }.padding(.horizontal, 16)
            }
            HStack(spacing: 8) {
                ForEach(TextWeight.allCases) { w in
                    Button { editText { $0.weight = w } } label: {
                        Text(w.label).font(VeFont.sans(12, weight: .bold))
                            .foregroundStyle(o.weight == w ? Color.veOnTerracotta : Color.veWarmGray)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(o.weight == w ? Color.veTerracotta : Color.white, in: Capsule())
                            .overlay(Capsule().stroke(Color.veCharcoal.opacity(o.weight == w ? 0 : 0.1), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
        .padding(.top, 18)
    }

    private func fontCard(_ fam: TextFontFamily, selected: Bool) -> some View {
        VStack(spacing: 7) {
            Text("Ag").font(fam.swiftUIFont(size: 27, weight: .regular)).foregroundStyle(Color.veCharcoal)
            Text(fam.label).font(VeFont.sans(10.5, weight: selected ? .bold : .semibold))
                .foregroundStyle(selected ? Color.veTerracotta : Color.veWarmGray)
        }
        .frame(width: 72, height: 84)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(selected ? Color.veTerracotta : Color.veCharcoal.opacity(0.08), lineWidth: 2))
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(Color.veTerracotta, in: Circle()).offset(x: 7, y: -7)
            }
        }
        .shadow(color: Color.veCharcoal.opacity(selected ? 0.12 : 0.05), radius: selected ? 8 : 3, y: 2)
    }

    private func styleTab(_ o: TextOverlay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Color").font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veNoteText)
            HStack(spacing: 11) {
                ColorPicker("", selection: Binding(get: { (editingOverlay?.color ?? .white).swiftUI },
                                                   set: { c in editText { $0.color = RGBAColor(c) } }), supportsOpacity: false)
                    .labelsHidden().frame(width: 30, height: 30)
                ForEach(Array(RGBAColor.presets.enumerated()), id: \.offset) { _, c in
                    Button { editText { $0.color = c } } label: {
                        Circle().fill(c.swiftUI).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.veCharcoal.opacity(c == .white ? 0.15 : 0), lineWidth: 1.5))
                            .overlay(Circle().stroke(Color.veTerracotta, lineWidth: sameColor(o.color, c) ? 2 : 0).padding(-3))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Text("Size").font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veNoteText)
                Spacer()
                Text("\(Int(o.fontSize * 1080))").font(VeFont.mono(12, weight: .bold)).foregroundStyle(Color.veTerracotta)
            }
            Slider(value: Binding(get: { editingOverlay?.fontSize ?? 0.055 }, set: { v in editText { $0.fontSize = v } }), in: 0.02...0.2)
                .tint(Color.veTerracotta)
            HStack(spacing: 8) {
                stylePill("Align", system: o.alignment.sfSymbol, active: false) { editText { $0.alignment = $0.alignment.next } }
                stylePill("Background", system: "textformat", active: o.background) { editText { $0.background.toggle() } }
                stylePill("Outline", system: "a.square", active: o.outline) { editText { $0.outline.toggle() } }
            }
        }
        .padding(16)
    }

    private func stylePill(_ title: String, system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: system).font(.system(size: 12, weight: .semibold))
                Text(title).font(VeFont.sans(12, weight: active ? .bold : .semibold))
            }
            .foregroundStyle(active ? Color.white : Color.veWarmGray)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(active ? Color.veTerracotta : Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.veCharcoal.opacity(active ? 0 : 0.1), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func sameColor(_ a: RGBAColor, _ b: RGBAColor) -> Bool {
        abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
    }

    // MARK: - Undo / redo + Speed/Volume inspector (CP3.6)

    private func doUndo() {
        guard !narration.isBusy else { return }
        store?.undo(); selection = nil; inspector = nil; rebuildTick += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func doRedo() {
        guard !narration.isBusy else { return }
        store?.redo(); selection = nil; inspector = nil; rebuildTick += 1
    }

    /// Speed/Volume toolbar: open the inspector for the selected clip (or the clip under the playhead).
    private func openInspector(_ mode: InspectorMode) {
        guard !narration.isBusy else { return }
        if case .text = selection { return }                       // text uses its own editor, not speed/volume
        if selection == nil, let cid = clipUnderPlayhead() { selection = .base(cid) }
        if mode == .speed, case .overlay = selection { return }   // speed is main-clip only
        if mode == .speed, case .narration = selection { return } // narration is never speed-scaled
        inspector = (inspector == mode) ? nil : mode
    }

    /// Record toolbar: toggle the voiceover panel (master mixer + the record button). Clearing the
    /// selection keeps the panel on the master controls rather than a clip's volume.
    private func openRecordPanel() {
        guard store != nil, !narration.isBusy else { return }
        inspector = (inspector == .record) ? nil : .record
        if inspector == .record { selection = nil; editingText = nil }
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if inspector == .voice, let store {
            voiceInspector(store)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.veCharcoal.opacity(0.08), radius: 10, y: 4)
                .padding(.horizontal, 16).padding(.top, 8)
        } else if inspector == .record, let store {
            recordInspector(store)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.veCharcoal.opacity(0.08), radius: 10, y: 4)
                .padding(.horizontal, 16).padding(.top, 8)
                .onAppear { narration.refreshMicPermission() }   // opening the panel shows fresh permission state
                // Deliberate downward swipe on the panel dismisses it (in addition to ✕ / background
                // tap / the toolbar toggle) — never mid-take, the Stop button lives here.
                .gesture(
                    DragGesture(minimumDistance: 14)
                        .onEnded { v in
                            guard !narration.isBusy else { return }
                            if v.translation.height > 40, v.translation.height > abs(v.translation.width) {
                                withAnimation(.easeOut(duration: 0.2)) { inspector = nil }
                            }
                        }
                )
        } else if inspector != nil, let store, let sel = selection {
            VStack(alignment: .leading, spacing: 12) {
                switch sel {
                case .base(let cid):
                    if let clip = store.order.first(where: { $0.id == cid }) {
                        if inspector == .speed { speedRow(cid, clip) }
                        else {
                            volumeRow(value: Double(clip.clampedVolume),
                                      onChange: { store.setClipVolume(cid, Float($0)) },
                                      onMute: { store.pushUndo(); store.setClipVolume(cid, clip.clampedVolume > 0 ? 0 : 1); rebuildTick += 1 },
                                      muted: clip.clampedVolume <= 0.001)
                            mixHint(start: baseStart(clip), end: baseStart(clip) + clip.timelineDuration)
                        }
                        inspectorButton("Make B-roll", "square.on.square") {
                            store.pushUndo(); store.markBroll(clip.sourceSegmentId); selection = nil; inspector = nil; rebuildTick += 1
                        }
                    }
                case .overlay(let oid):
                    if let o = store.brollLane.first(where: { $0.id == oid }) {
                        volumeRow(value: Double(o.volume),
                                  onChange: { store.setOverlayVolume(oid, Float($0)) },
                                  onMute: { store.pushUndo(); store.setOverlayVolume(oid, o.volume > 0 ? 0 : 1); rebuildTick += 1 },
                                  muted: o.volume <= 0.001)
                        mixHint(start: o.startOnBase, end: o.endOnBase)
                        HStack(spacing: 10) {
                            inspectorButton("Swap", "arrow.triangle.2.circlepath") { sourcePicker = .swap(oid) }
                            inspectorButton("To main", "arrow.down") {
                                store.pushUndo()
                                if let newId = store.unmarkBroll(o.sourceSegmentId) { selection = .base(newId) }
                                inspector = nil; rebuildTick += 1
                            }
                            inspectorButton("Remove", "trash", tint: Color.veTerracotta) {
                                store.pushUndo(); store.removeOverlay(oid); selection = nil; inspector = nil; rebuildTick += 1
                            }
                        }
                    }
                case .narration(let nid):
                    if let clip = store.narrationLane.first(where: { $0.id == nid }) {
                        volumeRow(value: Double(clip.volume),
                                  onChange: { store.setNarrationVolume(nid, Float($0)) },
                                  onMute: { store.pushUndo(); store.setNarrationVolume(nid, clip.volume > 0 ? 0 : 1); rebuildTick += 1 },
                                  muted: clip.volume <= 0.001)
                        inspectorButton("Remove take", "trash", tint: Color.veTerracotta) {
                            store.pushUndo(); store.removeNarration(nid)
                            selection = nil; inspector = nil; rebuildTick += 1
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                    }
                case .text:
                    EmptyView()   // captions are edited in the text editor panel, not this inspector
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.08), radius: 10, y: 4)
            .padding(.horizontal, 16).padding(.top, 8)
        }
    }

    private func speedRow(_ cid: UUID, _ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Text("Speed").font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veWarmGray)
            ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { sp in
                Button {
                    store?.pushUndo(); store?.setSpeed(cid, sp); rebuildTick += 1
                } label: {
                    Text(sp == 1 ? "1×" : "\(sp.formatted(.number.precision(.fractionLength(0...1))))×")
                        .font(VeFont.sans(12, weight: .bold))
                        .foregroundStyle(abs(clip.clampedSpeed - sp) < 0.01 ? Color.veOnTerracotta : Color.veWarmGray)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(abs(clip.clampedSpeed - sp) < 0.01 ? Color.veTerracotta : Color.veSurface, in: Capsule())
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func volumeRow(value: Double, onChange: @escaping (Double) -> Void,
                           onMute: @escaping () -> Void, muted: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(muted ? Color.veTerracotta : Color.veWarmGray).frame(width: 24)
            }.buttonStyle(.plain)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0...1) { editing in
                if editing { store?.pushUndo() } else { rebuildTick += 1 }
            }.tint(Color.veTerracotta)
            Text("\(Int(value * 100))%").font(VeFont.sans(11, weight: .bold))
                .foregroundStyle(Color.veWarmGray).frame(width: 38, alignment: .trailing)
        }
    }

    private func inspectorButton(_ title: String, _ system: String, tint: Color = .veCharcoal, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: system).font(.system(size: 11, weight: .bold))
                Text(title).font(VeFont.sans(12, weight: .bold))
            }
            .foregroundStyle(tint).padding(.horizontal, 11).padding(.vertical, 7)
            .background(tint.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain)
    }

    // MARK: - Voice Isolation inspector

    /// The "Clean" inspector: kick off isolation (whole video / this clip), watch progress, and A/B the
    /// Original ↔ Cleaned voice once a cleaned track exists. Cleaned audio sent to / from ElevenLabs.
    @ViewBuilder
    private func voiceInspector(_ store: EditPlanStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clean voice").font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veWarmGray)
                Spacer()
                if !store.isolatedAudio.isEmpty, !voiceIso.isRunning {
                    originalCleanedToggle(store)
                }
            }

            if voiceIso.isRunning {
                HStack(spacing: 10) {
                    ProgressView().scaleEffect(0.8).tint(Color.veTerracotta)
                    Text(voiceIso.label).font(VeFont.sans(12)).foregroundStyle(Color.veCharcoal)
                    Spacer()
                    Text("\(Int(voiceIso.progress * 100))%").font(VeFont.sans(11, weight: .bold))
                        .foregroundStyle(Color.veWarmGray)
                }
            } else {
                let minDur = VoiceIsolationCoordinator.minDurationSeconds
                let entireOK = store.baseDuration >= minDur
                let selectedClip: Clip? = {
                    if case .base(let cid) = selection { return store.order.first(where: { $0.id == cid }) }
                    return nil
                }()
                let clipOK = (selectedClip?.sourceDuration ?? 0) >= minDur
                HStack(spacing: 10) {
                    inspectorButton(store.isolatedAudio.isEmpty ? "Isolate entire video" : "Re-isolate all",
                                    "mic.fill", tint: Color.veTerracotta) {
                        voiceIso.start(session: session, scope: .entire)
                    }
                    .disabled(!entireOK)
                    .opacity(entireOK ? 1 : 0.4)
                    if let clip = selectedClip {
                        inspectorButton("This clip", "wand.and.stars", tint: Color.veSage) {
                            voiceIso.start(session: session, scope: .clip(start: clip.inPoint, end: clip.outPoint))
                        }
                        .disabled(!clipOK)
                        .opacity(clipOK ? 1 : 0.4)
                    }
                }
                if case .failed(let msg) = voiceIso.phase {
                    Text(msg).font(VeFont.sans(10)).foregroundStyle(Color.veTerracotta).lineLimit(3)
                } else if !entireOK {
                    ReasonNote(text: "Your video is \(String(format: "%.1f", store.baseDuration))s. Voice isolation needs at least \(Int(minDur)) seconds — add or pick a longer clip.")
                } else if let clip = selectedClip, !clipOK {
                    ReasonNote(text: "This clip is \(String(format: "%.1f", clip.sourceDuration))s. Isolating one clip needs at least \(Int(minDur)) seconds — try “Isolate entire video” or pick a longer clip.")
                } else {
                    Text(voiceHint(store)).font(VeFont.sans(10)).foregroundStyle(Color.veNoteText)
                }
            }
        }
    }

    private func voiceHint(_ store: EditPlanStore) -> String {
        if store.isolatedAudio.isEmpty {
            return "Strips background noise from your voice with ElevenLabs. Select a clip to clean just that one."
        }
        let cleaned = store.order.filter { isClipCleaned($0) }.count
        return "\(cleaned) of \(store.order.count) clip(s) cleaned · toggle Original/Cleaned to compare. Edits stay aligned."
    }

    private func originalCleanedToggle(_ store: EditPlanStore) -> some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { cleaned in
                let on = store.useIsolatedAudio == cleaned
                Button {
                    guard store.useIsolatedAudio != cleaned else { return }
                    store.useIsolatedAudio = cleaned
                    // Seamless A/B: swap the audioMix in place (no item reload). An audioMix change only
                    // takes effect after a render boundary, so re-seek to the current time to apply it.
                    if let d = voicePreview {
                        let t = player.currentTime()
                        player.currentItem?.audioMix = PolishComposition.voiceAudioMix(d, useIsolated: cleaned)
                        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                    } else {
                        rebuildTick += 1   // fallback if the preview descriptor isn't ready
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(cleaned ? "Cleaned" : "Original")
                        .font(VeFont.sans(11, weight: .bold))
                        .foregroundStyle(on ? Color.veOnTerracotta : Color.veWarmGray)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Color.veTerracotta : Color.clear, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.veSurface, in: Capsule())
    }

    // MARK: - Voiceover Record inspector + recording flow

    /// The "Record" panel: a big record button (idle) or live level meter + Stop (recording), plus the
    /// master "Original audio" mixer that ducks/mutes everything from the footage under the voiceover.
    @ViewBuilder
    private func recordInspector(_ store: EditPlanStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Voiceover").font(VeFont.sans(12, weight: .bold)).foregroundStyle(Color.veWarmGray)
                Spacer()
                if narration.phase == .recording {
                    Text(timecode(narration.elapsed))
                        .font(VeFont.mono(12, weight: .semibold)).foregroundStyle(Color.veTerracotta)
                } else if !narration.isBusy {
                    // ✕ close (mid-take the panel must stay — it holds the Stop button)
                    Button { withAnimation(.easeOut(duration: 0.2)) { inspector = nil } } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold)).foregroundStyle(Color.veWarmGray)
                            .frame(width: 26, height: 26)
                            .background(Color.veSurface, in: Circle())
                    }.buttonStyle(.plain)
                }
            }

            if narration.micDenied {
                ReasonNote(text: "Vela needs microphone access to record your voiceover. Enable it in Settings, then come back.")
                inspectorButton("Open Settings", "gearshape.fill", tint: Color.veTerracotta) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else if narration.isBusy {
                HStack(spacing: 14) {
                    levelMeter
                    Spacer(minLength: 0)
                    Button { narration.stop() } label: {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(Color.veOnTerracotta).frame(width: 10, height: 10)
                            Text(narration.phase == .recording ? "Stop" : "Cancel")
                                .font(VeFont.sans(13, weight: .bold))
                        }
                        .foregroundStyle(Color.veOnTerracotta)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Color.veTerracotta, in: Capsule())
                        .shadow(color: Color.veTerracotta.opacity(0.3), radius: 6, y: 3)
                    }.buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 14) {
                    recordButton(store)
                    if store.canRecord(at: playheadTime) {
                        Text("Records from the playhead — the video plays silently while you speak. Recording stops at the next take or the video's end.")
                            .font(VeFont.sans(10)).foregroundStyle(Color.veNoteText)
                    }
                }
                if !store.canRecord(at: playheadTime) {
                    ReasonNote(text: total <= 0.1
                               ? "Nothing on the timeline yet — add clips before recording a voiceover."
                               : "The playhead is on a take (or too close to one). Scrub to open space, or delete the take.")
                }
            }

            duckRow(store)
        }
    }

    private func recordButton(_ store: EditPlanStore) -> some View {
        let enabled = store.canRecord(at: playheadTime)
        return Button(action: startRecording) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 14, weight: .bold))
                Text("Record").font(VeFont.sans(14, weight: .bold))
            }
            .foregroundStyle(Color.veOnTerracotta)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .background(Color.veTerracotta, in: Capsule())
            .shadow(color: Color.veTerracotta.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// Live mic-input meter: recent levels as terracotta bars, newest at the right. `pow(v, 0.5)`
    /// perceptually lifts quiet speech so the meter visibly breathes at conversational volume.
    private var levelMeter: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 2.5, gap: CGFloat = 1.5
            let step = barW + gap
            let capacity = max(1, Int(size.width / step))
            let recent = narration.levels.suffix(capacity)
            var x = size.width - CGFloat(recent.count) * step
            for v in recent {
                let h = max(2, CGFloat(pow(Double(v), 0.5)) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(Color.veTerracotta.opacity(0.85)))
                x += step
            }
        }
        .frame(width: 160, height: 34)
    }

    /// "Under voiceover": how loud the original bed (all footage audio) stays while a take plays — a
    /// mix-time envelope scoped to the takes, never written into clip volumes. Commits like `volumeRow`
    /// (undo on drag-begin, rebuild on release), with mid-drag values held in `dragGain` so the preview
    /// signature only changes once.
    private func duckRow(_ store: EditPlanStore) -> some View {
        let shown = dragGain ?? Double(store.voDuckLevel)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text("Under voiceover").font(VeFont.sans(11, weight: .semibold)).foregroundStyle(Color.veNoteText)
                    .fixedSize()
                Slider(value: Binding(get: { dragGain ?? Double(store.voDuckLevel) },
                                      set: { dragGain = $0 }), in: 0...1) { editing in
                    if editing {
                        store.pushUndo()
                        dragGain = Double(store.voDuckLevel)
                    } else {
                        if let g = dragGain { store.setVoDuckLevel(Float(g)) }
                        dragGain = nil
                        rebuildTick += 1
                    }
                }
                .tint(Color.veTerracotta)
                .disabled(narration.isBusy)
                Text("\(Int(shown * 100))%").font(VeFont.sans(11, weight: .bold))
                    .foregroundStyle(Color.veWarmGray).frame(width: 38, alignment: .trailing)
            }
            Text("How loud the original audio stays while your voiceover talks.")
                .font(VeFont.sans(10)).foregroundStyle(Color.veNoteText)
        }
    }

    /// CapCut-style track mute at the head of the Main lane: one tap silences ALL original footage
    /// audio (base clips + audible B-roll) via a non-destructive flag — per-clip volumes stay
    /// untouched, so unmuting returns the exact mix. The voiceover keeps playing.
    private var muteAllButton: some View {
        let muted = store?.originalAudioMuted ?? false
        return Button {
            guard let store, !narration.isBusy else { return }
            store.pushUndo()
            store.originalAudioMuted.toggle()
            rebuildTick += 1
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(muted ? Color.veTerracotta : Color.veFaintGray)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(narration.isBusy)
    }

    /// One-line mix transparency under a volume slider — why this clip can sound quieter than its
    /// number says.
    @ViewBuilder
    private func mixHint(start: Double, end: Double) -> some View {
        if let store {
            if store.originalAudioMuted {
                Text("Track is muted — tap the speaker by the Main lane.")
                    .font(VeFont.sans(10)).foregroundStyle(Color.veNoteText)
            } else if store.voDuckLevel < 0.999,
                      store.narrationLane.contains(where: { $0.startOnBase < end && start < $0.endOnBase && $0.volume > 0.001 }) {
                Text("Dips to \(Int(store.voDuckLevel * 100))% wherever your voiceover plays.")
                    .font(VeFont.sans(10)).foregroundStyle(Color.veNoteText)
            }
        }
    }

    /// Kick off a take at the playhead: capture into the project's narration/ dir, mute the preview
    /// while the mic is live (no speaker bleed), and land the chip on the lane when the take ends.
    private func startRecording() {
        guard let store, !narration.isBusy, store.canRecord(at: playheadTime) else { return }
        let start = playheadTime
        let boundary = store.narrationBoundary(after: start)
        let dir = projects.narrationDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("narration", isDirectory: true)
        if projects.narrationDirectory == nil {
            Log.audio("⚠️ No current project — recording narration into a temp directory (won't survive relaunch).")
        }
        store.narrationDirectory = dir
        selection = nil; editingText = nil
        previewPlaying = false; player.pause()
        takeStart = start
        narration.start(into: dir, maxDuration: boundary - start,
            onRecordingBegan: {
                player.isMuted = true          // visual reference only — nothing for the mic to pick up
                previewPlaying = true
                player.play()
            },
            completion: { outcome in
                handleTake(outcome, at: start, boundary: boundary)
            })
    }

    private func handleTake(_ outcome: NarrationRecorder.Outcome, at start: Double, boundary: Double) {
        player.pause()
        player.isMuted = false
        previewPlaying = false
        takeStart = nil
        switch outcome {
        case .saved(let url, let duration):
            guard let store else { return }
            store.pushUndo()
            let clip = store.addNarration(fileName: url.lastPathComponent, fileDuration: duration,
                                          at: start, cappedTo: boundary)
            selection = .narration(clip.id)
            rebuildTick += 1
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if store.noteFirstTake() {
                showVoiceToast(text: "Original audio dips to \(Int(store.voDuckLevel * 100))% under your voiceover — fine-tune in Voiceover.", ok: true)
            }
        case .tooShort:
            showVoiceToast(text: "That take was too short — record for at least half a second.", ok: false)
        case .cancelled:
            break
        case .denied:
            break   // the Record panel shows the Open-Settings hint via narration.micDenied
        case .failed(let msg):
            showVoiceToast(text: "Recording failed: \(msg)", ok: false)
        }
    }

    // MARK: - Voiceover nudge (one-shot)

    /// Show the "record a voiceover?" nudge once per session: when the brief planned a voiceover, or
    /// the cut carries no talking-head content — and no take exists yet. Tap opens the Voiceover panel.
    private func maybeShowNarrationNudge() {
        guard !session.narrationNudgeShown, let store, store.baseDuration > 0,
              store.narrationLane.isEmpty, !narration.isBusy else { return }
        let plansVO = session.brief?.plansVoiceover == true
        let noSpeech = !store.order.contains { store.segment($0.sourceSegmentId)?.sceneType == .talkingHead }
        guard plansVO || noSpeech else { return }
        session.narrationNudgeShown = true
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            narrationNudge = plansVO ? "Ready for your voiceover — tap to record over the cut."
                                     : "This cut has no talking — want to record a voiceover?"
        }
        narrationNudgeTask = Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if Task.isCancelled { return }
            await MainActor.run { withAnimation(.easeOut(duration: 0.25)) { narrationNudge = nil } }
        }
    }

    private func dismissNarrationNudge() {
        narrationNudgeTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { narrationNudge = nil }
    }

    /// Sage capsule under the toast slot — the voiceover discovery moment. Tap → the Voiceover panel.
    @ViewBuilder private var narrationNudgeBanner: some View {
        if let text = narrationNudge {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.system(size: 13, weight: .bold))
                Text(text).font(VeFont.sans(13, weight: .semibold)).lineLimit(2)
                Button {
                    dismissNarrationNudge()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.8)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .foregroundStyle(Color.veOnTerracotta)
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 11)
            .background(Color.veSage, in: Capsule())
            .shadow(color: Color.veCharcoal.opacity(0.2), radius: 10, y: 4)
            .padding(.top, 10).padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture {
                dismissNarrationNudge()
                inspector = .record
                selection = nil; editingText = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    /// Transient banner shown when isolation finishes / fails — visible even if the inspector is closed.
    @ViewBuilder private var voiceToastBanner: some View {
        if let t = voiceToast {
            HStack(spacing: 8) {
                Image(systemName: t.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(t.text).font(VeFont.sans(13, weight: .semibold)).lineLimit(2)
            }
            .foregroundStyle(Color.veOnTerracotta)
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(t.ok ? Color.veSage : Color.veTerracotta, in: Capsule())
            .shadow(color: Color.veCharcoal.opacity(0.2), radius: 10, y: 4)
            .padding(.top, 10).padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
            .onTapGesture { dismissVoiceToast() }
        }
    }

    private func showVoiceToast(text: String, ok: Bool) {
        voiceToastTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { voiceToast = (text, ok) }
        voiceToastTask = Task {
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            if Task.isCancelled { return }
            dismissVoiceToast()
        }
    }

    private func dismissVoiceToast() {
        voiceToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { voiceToast = nil }
        voiceIso.acknowledge()
    }

    private func seekPlayerOnly(to t: Double) {
        player.seek(to: CMTime(seconds: max(0, min(t, total)), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: - Source picker sheet (add / swap B-roll)

    private func sourceSheet(_ picker: SourcePicker) -> some View {
        let pool = store?.brollClips ?? []
        return VStack(spacing: 0) {
            Capsule().fill(Color(hex: 0xD8D0C2)).frame(width: 40, height: 4).padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(isSwap(picker) ? "Swap B-roll" : "Add B-roll").font(VeFont.serif(21)).foregroundStyle(Color.veCharcoal)
                Text("Plays over your cut — muted by default; raise its volume in the inspector.")
                    .font(VeFont.sans(12.5)).foregroundStyle(Color.veWarmGray)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 14)
            ScrollView {
                VStack(spacing: 10) {
                    if pool.isEmpty {
                        Text("No B-roll clips yet — swipe a clip down in Triage, or tap “Make B-roll” later.")
                            .font(VeFont.sans(13)).foregroundStyle(Color.veFaintGray)
                            .multilineTextAlignment(.center).padding(.vertical, 30).padding(.horizontal, 20)
                    }
                    ForEach(pool, id: \.self) { id in sourceRow(id, picker: picker) }
                }
                .padding(.horizontal, 22).padding(.bottom, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.veCream)
        .presentationDetents([.medium, .large])
    }

    private func sourceRow(_ id: Int, picker: SourcePicker) -> some View {
        let seg = store?.segment(id)
        return Button {
            apply(picker, sourceId: id)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            sourcePicker = nil
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if let img = thumbs[id] { Image(uiImage: img).resizable().scaledToFill() }
                    else { FoodTile(tone: seg?.sceneType.foodTone ?? .cheese, cornerRadius: 10) }
                }
                .frame(width: 50, height: 50).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text((seg?.description.isEmpty == false ? seg!.description : (seg?.sceneType.label ?? "Clip")))
                        .font(VeFont.sans(13.5, weight: .semibold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                    Text("\(Int((store?.sourceLength(id) ?? 0).rounded()))s clip")
                        .font(VeFont.sans(11.5)).foregroundStyle(Color.veWarmGray)
                }
                Spacer(minLength: 0)
                Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundStyle(Color.veTerracotta)
            }
            .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.veCharcoal.opacity(0.05), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func isSwap(_ p: SourcePicker) -> Bool { if case .swap = p { return true }; return false }

    private func apply(_ picker: SourcePicker, sourceId: Int) {
        store?.pushUndo()
        switch picker {
        case .add:
            store?.addOverlay(sourceId: sourceId, at: playheadTime)
            if let id = store?.brollLane.last?.id { selection = .overlay(id) }
            rebuildTick += 1
        case .swap(let overlayId):
            store?.swapOverlaySource(overlayId, to: sourceId); rebuildTick += 1
        }
    }

    // MARK: - Preview rebuild

    private var previewSignature: String {
        guard let store else { return "" }
        let base = store.order.map {
            "\($0.id)i\(Int($0.inPoint * 100))o\(Int($0.outPoint * 100))s\(Int($0.speed * 100))v\(Int($0.volume * 100))"
        }.joined(separator: ",")
        let lane = store.brollLane.map {
            "\($0.sourceSegmentId):\(Int($0.startOnBase * 100))+\(Int($0.duration * 100))v\(Int($0.volume * 100))"
        }.joined(separator: ",")
        // NOTE: `useIsolatedAudio` is intentionally NOT here — toggling Original↔Cleaned swaps the
        // audioMix in place (no rebuild). Only the SET of cleaned files (filenames) rebuilds the preview.
        let iso = store.isolatedAudio.map { $0.url.lastPathComponent }.joined(separator: ",")
        let nar = store.narrationLane.map {
            "\($0.fileName):\(Int($0.startOnBase * 100))+\(Int($0.inPoint * 100))-\(Int($0.outPoint * 100))v\(Int($0.volume * 100))"
        }.joined(separator: ",")
        return base + "|" + lane + "|iso\(iso)|nar\(nar)|dk\(Int(store.voDuckLevel * 100))|m\(store.originalAudioMuted ? 1 : 0)|t\(rebuildTick)"
    }

    private func rebuildPreview() async {
        guard !scrubbing, !trimming, !lifting, !narration.isBusy, let store, let proxyURL else { return }
        let slots = store.renderSlots()
        let baseAudio = store.baseAudioPieces()
        let overlayAudio = store.overlayAudioPieces()
        // Build BOTH base tracks whenever cleaned files exist; the toggle selects which is audible.
        guard let preview = await PolishComposition.makeItem(proxyURL: proxyURL, slots: slots,
                                                             baseAudio: baseAudio, overlayAudio: overlayAudio,
                                                             isolated: store.isolatedAudio,
                                                             useIsolated: store.useIsolatedAudio,
                                                             narration: store.narrationPieces(),
                                                             duckLevel: store.voDuckLevel,
                                                             originalMuted: store.originalAudioMuted) else { return }
        await MainActor.run {
            AudioSession.configureForPlayback()
            voicePreview = preview
            player.replaceCurrentItem(with: preview.item)
            seekPlayerOnly(to: playheadTime)
            if previewPlaying && !fullscreen { player.play() }
        }
    }

    private func addObserver() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main
        ) { t in
            if previewPlaying && !scrubbing { scrollX = clampScroll(CGFloat(t.seconds) * pps) }
        }
    }

    private func teardown() {
        narration.stop()   // leaving the page stops-and-keeps any in-flight take
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause()
    }

    /// Generate a poster frame per segment from the proxy. Re-runnable: skips ids already loaded, so it
    /// fills in only newly-imported clips after an "Add videos" re-merge. Reads `store.allSegments`
    /// (plan + imported), not the immutable `plan.segments`.
    private func loadThumbnails() async {
        guard let proxyURL, let store else { return }
        for seg in store.allSegments where thumbs[seg.id] == nil {
            let t = seg.startSeconds + min(0.4, max(0, (seg.endSeconds - seg.startSeconds) / 2))
            if let img = await ThumbnailService.thumbnail(for: proxyURL, at: t) {
                await MainActor.run { thumbs[seg.id] = img }
            }
        }
    }

    // MARK: - Formatting

    /// MM:SS:FF timecode (frames at 30fps), matching the mockup.
    private func timecode(_ t: Double) -> String {
        let totalFrames = Int((max(0, t) * 30).rounded())
        return String(format: "%02d:%02d:%02d", totalFrames / 1800, (totalFrames / 30) % 60, totalFrames % 30)
    }
    /// M:SS clock label for the ruler.
    private func clock(_ t: Double) -> String {
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Faux audio waveform

/// A decorative waveform fill for the AUDIO lane: vertical bars at pseudo-random heights, centered and
/// fading toward the edges. Heights are a deterministic hash of (bar index, seed) so the same clip always
/// draws the same shape — no per-frame jitter, no asset sampling. Drawn in a `Canvas` for cheap redraws.
private struct WaveformBar: View {
    let color: Color
    let seed: Int
    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 1.5, gap: CGFloat = 2.5
            let step = barW + gap
            var x: CGFloat = 1
            var i = 0
            while x < size.width {
                let s = sin(Double(i) * 12.9898 + Double(seed) * 4.1414) * 43758.5453
                let n = s - floor(s)                                  // 0…1 pseudo-random
                let h = max(2, CGFloat(0.22 + 0.78 * n) * size.height)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(color))
                x += step; i += 1
            }
        }
    }
}

// MARK: - Playhead triangle

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Full-screen player

private struct FullScreenPlayer: View {
    let player: AVPlayer
    let onClose: () -> Void
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player).ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain).padding(20)
        }
        .swipeDownToDismiss { onClose() }
        .onAppear { player.play() }
    }
}
