import SwiftUI
import AVKit

/// Screen 2 — Picker. Launches the system camera-roll picker (multi-select), then shows a styled
/// review screen of the chosen clips: ordered rows with thumbnails + durations, drag-to-reorder,
/// swipe-to-remove, "Add more", and the mockup's "Edit this · N clips" CTA. The clips get stitched
/// together (in this order) downstream in M2.
struct PickerView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session

    @State private var showPicker = false
    @State private var editMode: EditMode = .inactive
    @State private var previewClip: SourceClip?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if session.isEmpty {
                emptyState
            } else {
                reviewList
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.veCream.ignoresSafeArea())
        .fullScreenCover(isPresented: $showPicker) {
            VideoPicker(preselectedIdentifiers: session.selectedAssetIdentifiers, onPicked: handlePicked)
                .ignoresSafeArea()
        }
        .sheet(item: $previewClip) { clip in
            ClipPreviewSheet(url: clip.url)
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 14) {
            BackChevronButton { router.back() }
            VStack(alignment: .leading, spacing: 2) {
                Text("Camera roll")
                    .font(VeFont.serif(22))
                    .foregroundStyle(Color.veCharcoal)
                Text(session.isEmpty
                     ? "Pick one or more clips to stitch"
                     : "\(session.count) clip\(session.count == 1 ? "" : "s") · \(session.totalDurationText) total")
                    .font(VeFont.sans(12.5))
                    .foregroundStyle(Color.veWarmGray)
            }
            Spacer()
            if !session.isEmpty {
                Button {
                    withAnimation { editMode = editMode == .active ? .inactive : .active }
                } label: {
                    Text(editMode == .active ? "Done" : "Reorder")
                        .font(VeFont.sans(13.5, weight: .bold))
                        .foregroundStyle(Color.veTerracotta)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 60)
        .padding(.bottom, 12)
    }

    // MARK: empty state

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color.veTerracotta.opacity(0.1)).frame(width: 96, height: 96)
                Image(systemName: "film.stack")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Color.veTerracotta)
            }
            VStack(spacing: 6) {
                Text("Choose your footage")
                    .font(VeFont.serif(22))
                    .foregroundStyle(Color.veCharcoal)
                Text("Raw, unedited is perfect — pick a few clips and we'll stitch them.")
                    .font(VeFont.sans(13.5))
                    .foregroundStyle(Color.veWarmGray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            Spacer()
            PrimaryActionButton(title: "Open camera roll") { showPicker = true }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: review list

    private var reviewList: some View {
        List {
            ForEach(Array(session.clips.enumerated()), id: \.element.id) { index, clip in
                ClipRow(index: index,
                        clip: clip,
                        showRemove: editMode != .active,
                        onPreview: { previewClip = clip },
                        onRemove: { removeClip(clip) })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 22, bottom: 5, trailing: 22))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { removeClip(clip) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .tint(Color.veTerracotta)
                    }
            }
            .onMove { session.move(fromOffsets: $0, toOffset: $1) }
            .onDelete { offsets in   // also powers the minus-circle in Reorder mode
                session.remove(atOffsets: offsets)
                Log.video("Removed clip(s); \(session.count) remaining.")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, $editMode)
    }

    // MARK: bottom bar

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Button { showPicker = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                    Text("Add more")
                }
                .font(VeFont.sans(14, weight: .bold))
                .foregroundStyle(Color.veCharcoal)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.veCharcoal.opacity(0.1), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)

            PrimaryActionButton(title: "Edit this · \(session.count) clip\(session.count == 1 ? "" : "s")") {
                Log.video("Editing \(session.count) clip(s), total \(session.totalDurationText).")
                router.go(.processing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 28)
        .background(Color.veCream)
    }

    // MARK: actions

    private func removeClip(_ clip: SourceClip) {
        guard let idx = session.clips.firstIndex(where: { $0.id == clip.id }) else { return }
        withAnimation { session.remove(atOffsets: IndexSet(integer: idx)) }
        Log.video("Removed clip \(idx + 1); \(session.count) remaining.")
    }

    private func handlePicked(_ newClips: [PickedClip]) {
        showPicker = false
        guard !newClips.isEmpty else { return }
        Log.video("Adding \(newClips.count) clip(s) to the session…")
        for picked in newClips {
            let clip = SourceClip(url: picked.url, assetIdentifier: picked.assetIdentifier)
            session.add(clip)
            Task { await loadDetails(clipID: clip.id, url: picked.url) }
        }
    }

    private func loadDetails(clipID: UUID, url: URL) async {
        async let metaTask = VideoInspector.metadata(for: url)
        async let thumbTask = ThumbnailService.thumbnail(for: url)
        let meta = await metaTask
        let thumb = await thumbTask
        await MainActor.run {
            session.updateDetails(id: clipID, metadata: meta, thumbnail: thumb)
            if let meta, let idx = session.clips.firstIndex(where: { $0.id == clipID }) {
                Log.video("""
                Clip \(idx + 1) — \(url.lastPathComponent): \(meta.durationText) \
                (\(String(format: "%.1f", meta.duration))s), \(meta.resolutionText) \
                (\(meta.isPortrait ? "portrait" : "landscape")), \(meta.fileSizeText)
                """)
            }
            Log.video("Session total: \(session.count) clip(s), \(session.totalDurationText), \(session.totalSizeText).")
        }
    }
}

// MARK: - Clip row

private struct ClipRow: View {
    let index: Int
    let clip: SourceClip
    let showRemove: Bool
    let onPreview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(VeFont.sans(13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.veTerracotta, in: Circle())

            Button(action: onPreview) {
                ZStack {
                    if let thumb = clip.thumbnail {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        FoodTile(tone: FoodTone.tone(for: index), cornerRadius: 10)
                        ProgressView().tint(.white)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(radius: 2)
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clip \(index + 1)")
                    .font(VeFont.sans(14, weight: .semibold))
                    .foregroundStyle(Color.veCharcoal)
                if let meta = clip.metadata {
                    Text("\(meta.durationText) · \(meta.resolutionText) · \(meta.fileSizeText)")
                        .font(VeFont.sans(12))
                        .foregroundStyle(Color.veWarmGray)
                } else {
                    Text("Reading…")
                        .font(VeFont.sans(12))
                        .foregroundStyle(Color.veFaintGray)
                }
            }
            Spacer(minLength: 0)

            if showRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.veWarmGray)
                        .frame(width: 26, height: 26)
                        .background(Color.veSurface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove clip \(index + 1)")
            }
        }
        .padding(10)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.veCharcoal.opacity(0.05), radius: 6, y: 2)
    }
}

// MARK: - Clip preview sheet

private struct ClipPreviewSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.veCharcoal.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .padding(.top, 16)
            .padding(.trailing, 16)
        }
        .onAppear {
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
    }
}
