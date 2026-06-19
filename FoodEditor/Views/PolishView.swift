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
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

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
    @State private var sourcePicker: SourcePicker?
    @State private var trimming = false
    @State private var trimDrag: TrimDrag?
    @State private var lift: LiftDrag?
    @State private var inspector: InspectorMode?

    @State private var pps: CGFloat = 14             // points per second (pinch-zoomable)
    @State private var zoomBasePps: CGFloat = 14
    @State private var zoomAnchorTime: Double = 0
    @State private var zooming = false

    private var store: EditPlanStore? { session.store }
    private var proxyURL: URL? { session.merged?.url }

    enum Selection: Equatable { case base(UUID), overlay(UUID) }
    private enum InspectorMode { case speed, volume }
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

    private let timelineSpace = "ptl"
    private let oneFrame = 1.0 / 30.0
    private let gutter: CGFloat = 24
    private let trackGap: CGFloat = 4
    private let rulerH: CGFloat = 16
    private let textH: CGFloat = 22
    private let mainH: CGFloat = 40
    private let brollH: CGFloat = 30
    private let audioH: CGFloat = 20

    private var total: Double { store?.baseDuration ?? 0 }
    private var playheadTime: Double { pps > 0 ? Double(scrollX) / Double(pps) : 0 }
    private var lifting: Bool { lift != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            transportRow
            playbackRow
            timeline
            inspectorPanel
            bottomToolbar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
        .task { await loadThumbnails() }
        .task(id: previewSignature) { await rebuildPreview() }
        .onAppear(perform: addObserver)
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            player.seek(to: .zero); scrollX = 0
            if previewPlaying && !fullscreen { player.play() }
        }
        .onDisappear(perform: teardown)
        .sheet(item: $sourcePicker) { picker in sourceSheet(picker) }
        .fullScreenCover(isPresented: $fullscreen) {
            FullScreenPlayer(player: player) { fullscreen = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button { player.pause(); router.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.veNoteText)
                    .frame(width: 34, height: 34)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.veCharcoal.opacity(0.1), lineWidth: 1))
                    .shadow(color: Color.veCharcoal.opacity(0.07), radius: 3, y: 1)
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 1) {
                Text(projectTitle).font(VeFont.sans(14.5, weight: .bold)).foregroundStyle(Color.veCharcoal).lineLimit(1)
                Text("POLISH").font(VeFont.mono(9, weight: .semibold)).tracking(1.2).foregroundStyle(Color.veTerracotta)
            }
            Spacer()
            Button { player.pause(); router.go(.export) } label: {
                Text("Export")
                    .font(VeFont.sans(12.5, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
                    .frame(height: 34).padding(.horizontal, 14)
                    .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 54).padding(.bottom, 4)
    }

    private var projectTitle: String {
        let s = (store?.plan.videoSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Your cut" }
        let words = s.split(separator: " ").prefix(3).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.vePreviewMat)
            PlayerLayerView(player: player, gravity: .resizeAspect)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    Text(previewCaption).font(VeFont.serif(13, italic: true)).foregroundStyle(.white.opacity(0.82))
                    Spacer()
                    Button { player.pause(); fullscreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.85))
                            .frame(width: 30, height: 30).background(.black.opacity(0.3), in: Circle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(14)

            if !previewPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(.black.opacity(0.4), in: Circle())
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 264)
        .padding(.horizontal, 16).padding(.top, 16)
        .shadow(color: Color.veCharcoal.opacity(0.12), radius: 12, y: 6)
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
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.veWarmGray)
                Text(zoomLabel).font(VeFont.mono(11)).foregroundStyle(Color.veNoteText)
            }
            .frame(height: 26).padding(.horizontal, 9)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.veCharcoal.opacity(0.1), lineWidth: 1))
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
                    laneRow(kind: .text, height: textH) { Color.clear }     // TEXT — empty // TODO: text overlays
                        .opacity(dimTextAudio)
                    laneRow(kind: .main, height: mainH) { mainLane(laneW) }
                    laneRow(kind: .broll, height: brollH) { brollLane(laneW) }
                    laneRow(kind: .audio, height: audioH) { Color.clear }    // AUDIO — empty // TODO: audio track
                        .opacity(dimTextAudio)
                }
                .padding(.top, 4)

                // fixed centered playhead over the lane area (line centered in an 11pt-wide frame)
                playhead
                    .offset(x: gutter + laneW / 2 - 5.5)

                // selected-clip duration bubble, pinned over the playhead
                if selectedDuration != nil { durationBubble.position(x: gutter + laneW / 2, y: rulerH + 14) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: timelineSpace)
            .gesture(scrubGesture)
            .simultaneousGesture(zoomGesture)
            .onTapGesture { if selection != nil { selection = nil; inspector = nil } }
            .onAppear { laneWidth = laneW }
            .onChange(of: laneW) { _, n in laneWidth = n }
        }
        .frame(maxHeight: .infinity)
        .background(Color.veTrackLane)
        .overlay(alignment: .top) { Rectangle().fill(Color.veCharcoal.opacity(0.08)).frame(height: 1) }
        .overlay(alignment: .topTrailing) { addBrollButton.padding(.trailing, 10).padding(.top, 8) }
    }

    private var addBrollButton: some View {
        Button { sourcePicker = .add } label: {
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
            ForEach(marks, id: \.self) { τ in
                Text(step >= 1 ? clock(τ) : timecode(τ))
                    .font(VeFont.mono(8)).foregroundStyle(Color.veFaintGray).fixedSize()
                    .offset(x: gutter + xFor(τ, laneW), y: 5)
            }
        }
        .frame(height: rulerH, alignment: .topLeading)
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .contentShape(Rectangle())
        .onTapGesture { select(.base(clip.id)) }
        .opacity(dim(forBase: clip.id))
        .shadow(color: Color.veCharcoal.opacity(isLifted(.base(clip.id)) ? 0.3 : 0), radius: isLifted(.base(clip.id)) ? 10 : 0, y: 5)
        .simultaneousGesture(liftGesture(.base(clip.id), baseStart: baseStart(clip)))
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

    private var playhead: some View {
        VStack(spacing: 0) {
            Triangle().fill(Color.veCharcoal).frame(width: 11, height: 7)
            Rectangle().fill(Color.veCharcoal).frame(width: 2)
        }
        .frame(width: 11)
        .padding(.top, rulerH)
        .shadow(color: Color.veCharcoal.opacity(0.3), radius: 4)
        .allowsHitTesting(false)
    }

    // MARK: - Bottom toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 0) {
            toolbarItem(.split, "Split", active: (store?.baseDuration ?? 0) > 0) { splitAtPlayhead() }
            toolbarItem(.trim, "Trim", active: selection != nil) { trimAction() }
            toolbarItem(.speed, "Speed", active: inspector == .speed) { openInspector(.speed) }
            toolbarItem(.volume, "Volume", active: inspector == .volume) { openInspector(.volume) }
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

    // MARK: - Scrub / transport actions

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if zooming || lifting { return }
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
                if !zooming { zooming = true; zoomBasePps = pps; zoomAnchorTime = playheadTime }
                pps = clampPps(zoomBasePps * scale)
                scrollX = clampScroll(CGFloat(zoomAnchorTime) * pps)
            }
            .onEnded { _ in zooming = false }
    }

    /// 8 pt/s (a ~minute fits) up to 1320 pt/s (one 30fps frame ≈ 44 pt — comfortably tappable).
    private func clampPps(_ v: CGFloat) -> CGFloat { max(8, min(v, 1320)) }

    private func togglePlay() {
        previewPlaying.toggle()
        if previewPlaying {
            if playheadTime >= total - 0.05 { scrollX = 0; player.seek(to: .zero) }
            player.play()
        } else {
            player.pause()
        }
    }

    private func step(by frames: Int) {
        previewPlaying = false; player.pause()
        let snapped = (playheadTime * 30).rounded() / 30
        let t = max(0, min(snapped + Double(frames) * oneFrame, total))
        scrollX = clampScroll(CGFloat(t) * pps)
        seekPlayerOnly(to: t)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func select(_ sel: Selection) {
        selection = (selection == sel) ? nil : sel
        if selection == nil { inspector = nil }
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
        defer { trimDrag = nil; trimming = false; rebuildTick += 1 }
        guard let d = trimDrag, let store else { return }
        let disp = trimDisplay(d)
        switch d.sel {
        case .base(let cid):
            if d.leftEdge { store.setIn(cid, toSource: disp.lo) } else { store.setOut(cid, toSource: disp.hi) }
        case .overlay(let oid):
            store.setOverlayBounds(oid, start: disp.lo, end: disp.hi)
        }
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
            guard let o = store.brollLane.first(where: { $0.id == oid }) else { return (d.baseLeft, d.baseRight) }
            let srcLen = store.sourceLength(o.sourceSegmentId)
            if d.leftEdge { return (min(max(d.baseLeft + delta, max(0, d.baseRight - srcLen)), d.baseRight - 0.3), d.baseRight) }
            return (d.baseLeft, max(min(d.baseRight + delta, min(total, d.baseLeft + srcLen)), d.baseLeft + 0.3))
        }
    }

    // MARK: - Lift move (B-roll) / reorder (Main) + display geometry

    private func isLifted(_ sel: Selection) -> Bool { lift?.sel == sel }
    private func isTrimming(_ sel: Selection) -> Bool { trimDrag?.sel == sel }
    private func liftY(_ sel: Selection) -> CGFloat { lift?.sel == sel ? min(0, lift!.t.height) : 0 }

    /// Display start (base time) for a Main clip — dragged clip follows the finger, others reflow.
    /// While the **left** handle is trimmed, the left edge follows the finger (right edge stays put); it
    /// settles back into the contiguous spine on release.
    private func displayStart(forBase clip: Clip) -> Double {
        if let l = lift, case .base(let did) = l.sel {
            if clip.id == did { return baseStart(clip) + Double(l.t.width / pps) }
            return previewBaseStart(clip)
        }
        if let d = trimDrag, d.sel == .base(clip.id), d.leftEdge {
            return baseStart(clip) + (trimDisplay(d).lo - clip.inPoint) / clip.clampedSpeed
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
            return max(0, min(o.startOnBase + Double(l.t.width / pps), max(0, total - o.duration)))
        }
        return o.startOnBase
    }
    private func displayDur(forOverlay o: OverlayClip) -> Double {
        if let d = trimDrag, d.sel == .overlay(o.id) { let t = trimDisplay(d); return t.hi - t.lo }
        return o.duration
    }

    /// Main reorder: insertion index among the other clips for the dragged clip's current center.
    private func mainInsertionIndex() -> Int? {
        guard let l = lift, case .base(let cid) = l.sel, let store,
              let dc = store.order.first(where: { $0.id == cid }) else { return nil }
        let center = baseStart(dc) + Double(l.t.width / pps) + dc.timelineDuration / 2
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
        guard let l = lift, case .base(let cid) = l.sel, let idx = mainInsertionIndex(), let store else { return nil }
        return store.order.filter { $0.id != cid }.prefix(idx).reduce(0.0) { $0 + $1.timelineDuration }
    }

    /// Hold (~0.3s) to lift a clip, then drag to move a B-roll clip or reorder a Main clip.
    private func liftGesture(_ sel: Selection, baseStart: Double) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineSpace)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if lift == nil {
                    lift = LiftDrag(sel: sel, baseStart: baseStart)
                    selection = sel; inspector = nil
                    previewPlaying = false; player.pause()
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                }
                lift?.t = drag?.translation ?? .zero
            }
            .onEnded { _ in commitLift() }
    }

    private func commitLift() {
        guard let l = lift, let store else { lift = nil; return }
        defer { lift = nil; rebuildTick += 1 }
        // A lift with no real drag is just a selection — don't push a no-op onto the undo stack.
        guard abs(l.t.width) > 2 || abs(l.t.height) > 2 else { return }
        store.pushUndo()
        switch l.sel {
        case .overlay(let oid):
            let dur = store.brollLane.first(where: { $0.id == oid })?.duration ?? 0
            store.moveOverlay(oid, toStart: max(0, min(l.baseStart + Double(l.t.width / pps), max(0, total - dur))))
        case .base(let cid):
            if let idx = mainInsertionIndex() { store.reorder(cid: cid, to: idx) }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func splitAtPlayhead() {
        guard let rightId = store?.split(at: playheadTime) else { return }
        selection = .base(rightId); rebuildTick += 1
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }

    /// Trim toolbar: select the clip under the playhead (or clear the current selection).
    private func trimAction() {
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
        guard selection != nil else { return }
        store?.pushUndo()
        switch selection {
        case .base(let cid): store?.deleteClip(cid)
        case .overlay(let oid): store?.removeOverlay(oid)
        case .none: return
        }
        selection = nil; inspector = nil; rebuildTick += 1
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    private func dim(forBase cid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .base(let s): return s == cid ? 1 : 0.5
        case .overlay: return 0.42
        }
    }
    private func dim(forOverlay oid: UUID) -> Double {
        switch selection {
        case .none: return 1
        case .overlay(let s): return s == oid ? 1 : 0.5
        case .base: return 0.42
        }
    }
    private var dimTextAudio: Double { selection == nil ? 1 : 0.42 }

    private var selectedDuration: Double? {
        switch selection {
        case .base(let cid): return store?.order.first(where: { $0.id == cid })?.sourceDuration
        case .overlay(let oid): return store?.brollLane.first(where: { $0.id == oid })?.duration
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

    // MARK: - Undo / redo + Speed/Volume inspector (CP3.6)

    private func doUndo() {
        store?.undo(); selection = nil; inspector = nil; rebuildTick += 1
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func doRedo() {
        store?.redo(); selection = nil; inspector = nil; rebuildTick += 1
    }

    /// Speed/Volume toolbar: open the inspector for the selected clip (or the clip under the playhead).
    private func openInspector(_ mode: InspectorMode) {
        if selection == nil, let cid = clipUnderPlayhead() { selection = .base(cid) }
        if mode == .speed, case .overlay = selection { return }   // speed is main-clip only
        inspector = (inspector == mode) ? nil : mode
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if inspector != nil, let store, let sel = selection {
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
        return base + "|" + lane + "|t\(rebuildTick)"
    }

    private func rebuildPreview() async {
        guard !scrubbing, !trimming, !lifting, let store, let proxyURL else { return }
        let slots = store.renderSlots()
        let baseAudio = store.baseAudioPieces()
        let overlayAudio = store.overlayAudioPieces()
        guard let item = await PolishComposition.makeItem(proxyURL: proxyURL, slots: slots,
                                                          baseAudio: baseAudio, overlayAudio: overlayAudio) else { return }
        await MainActor.run {
            AudioSession.configureForPlayback()
            player.replaceCurrentItem(with: item)
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
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.pause()
    }

    private func loadThumbnails() async {
        guard let proxyURL, thumbs.isEmpty else { return }
        for seg in store?.plan.segments ?? [] {
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
