import SwiftUI

/// Onboarding step 2 — "Connect". Camera-roll import only for now (TikTok/IG deferred — see the seam below).
/// Takes 1–3 finished videos: one works, but the copy actively sells adding more — cross-video repetition
/// is what upgrades a guessed habit into a confirmed signature (evidence badges + the Reveal's "in all
/// three videos…" story). The CTA enables once at least one clip is chosen, then advances to Analyzing.
struct ConnectStepView: View {
    @Environment(VideoSession.self) private var session

    let onBack: () -> Void
    let onContinue: () -> Void
    /// The front door must never be a toll booth: a raw-footage-only first-timer skips the style-learn
    /// entirely and lands in the Kitchen (the learn is re-offered on Home + after the first export).
    let onSkip: () -> Void

    @State private var showPicker = false
    @State private var downloadProgress: Progress?     // non-nil while a picked video copies out of the library
    @State private var showLoadFailToast = false

    private var hasClips: Bool { !session.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackChevronButton(action: onBack)

            Text("Show me a few\nof your videos")
                .font(VeFont.serif(31))
                .foregroundStyle(Color.veCharcoal)
                .lineSpacing(2)
                .padding(.top, 24)

            Text("Pick 1–3 videos you've already edited and posted. Vela studies how you actually cut — your hooks, your pacing, your catchphrases. Nothing is posted or changed.")
                .font(VeFont.sans(14.5))
                .foregroundStyle(Color.veNoteText)
                .lineSpacing(3)
                .padding(.top, 9)

            SourceCard(
                icon: "photo.stack",
                title: "Import from camera roll",
                subtitle: hasClips
                    ? "\(session.count) video\(session.count == 1 ? "" : "s") selected · tap to change"
                    : "Pick 1–3 edited videos to learn from",
                selected: hasClips
            ) { showPicker = true }
            .padding(.top, 22)

            // Sell the extra videos without blocking anyone: one is enough to start, three lets the
            // learn CONFIRM what they always do instead of guessing from a single sample.
            if hasClips && session.count < 3 {
                Text(session.count == 1
                     ? "One works — but with 3 videos we can tell your every-video signatures from one-off moments. Tap to add \(3 - session.count) more."
                     : "Nice — one more and we can confirm what you do in every video. Tap to add it.")
                    .font(VeFont.sans(12.5))
                    .foregroundStyle(Color(hex: 0x9A7350))
                    .lineSpacing(2)
                    .padding(.top, 10)
            } else if !hasClips {
                Text("More videos, sharper template — 3 lets us confirm your signatures instead of guessing from one.")
                    .font(VeFont.sans(12.5))
                    .foregroundStyle(Color.veWarmGray)
                    .lineSpacing(2)
                    .padding(.top, 10)
            }

            // TODO: TikTok / Instagram import — deferred. Add more `SourceCard`s here when wired.

            Spacer(minLength: 24)

            if hasClips {
                PrimaryActionButton(title: session.count == 1
                                    ? "Learn my style"
                                    : "Learn my style from \(session.count) videos",
                                    action: onContinue)
            } else {
                // Disabled-looking CTA (greyed) until a source is chosen.
                Text("Choose your videos")
                    .font(VeFont.sans(16, weight: .bold))
                    .foregroundStyle(Color.veFaintGray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(hex: 0xE2DACB), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            // Visible in BOTH CTA states — even mid-pick the user can bail to raw-clip cutting.
            Button(action: onSkip) {
                Text("No posted videos yet? **Skip** — start cutting, teach Vela later")
                    .font(VeFont.sans(12.5))
                    .foregroundStyle(Color.veNoteText)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
        }
        .padding(.horizontal, 26)
        .padding(.top, 60)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.veCream.ignoresSafeArea())
        .fullScreenCover(isPresented: $showPicker) {
            // Up to 3 finished videos; each re-pick REPLACES the prior selection (deliberate — the iOS 26
            // preselection regression makes additive re-picking unreliable, and replace-all is the
            // simplest mental model for a 3-item choice).
            VideoPicker(preselectedIdentifiers: [], selectionLimit: 3,
                        onLoadingBegan: { progress in
                            showPicker = false           // dismiss the sheet; the overlay shows the copy
                            downloadProgress = progress
                        }) { picked, failedCount in
                showPicker = false
                downloadProgress = nil
                guard !picked.isEmpty else {
                    if failedCount > 0 { withAnimation { showLoadFailToast = true } }
                    return
                }
                session.startFresh()
                session.ingest(picked)
            }
            .ignoresSafeArea()
        }
        .overlay { if let p = downloadProgress { MediaDownloadOverlay(progress: p) } }
        .overlay(alignment: .bottom) {
            if showLoadFailToast {
                ToastView(text: "Couldn't load that video — check your connection and try again.")
                    .padding(.bottom, 30)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_400_000_000)
                        withAnimation { showLoadFailToast = false }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showLoadFailToast)
    }
}

/// A selectable source row (mockup's connect cards). Reusable so TikTok/IG can be slotted in later.
private struct SourceCard: View {
    let icon: String
    let title: String
    let subtitle: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.veSurface)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.veTerracotta)
                }
                .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(VeFont.sans(16, weight: .bold))
                        .foregroundStyle(Color.veCharcoal)
                    Text(subtitle)
                        .font(VeFont.sans(13))
                        .foregroundStyle(Color.veWarmGray)
                }
                Spacer(minLength: 0)

                if selected {
                    ZStack {
                        Circle().fill(Color.veTerracotta)
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.veTerracotta, lineWidth: selected ? 2 : 0)
            )
            .shadow(color: Color.veCharcoal.opacity(0.06), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
    }
}
