import SwiftUI
import UIKit

/// The editor **shell** (the RECOMMENDED option from the "Navigation Options" mockup). It owns the
/// chrome — a Home button, the project title, an Export button, and the persistent `StageSwitcher` —
/// and swaps between the three content views (Sort/Arrange/Polish) by reading `session.editorStage`.
///
/// **Why this is simple & safe:** only the ACTIVE stage is mounted (a `switch`), so there is never more
/// than one inline `AVPlayer` alive (CLAUDE.md's one-player rule) — switching unmounts the old stage
/// (its `.onDisappear`/`teardown` pauses the player). Meanwhile all three stages bind the same
/// `EditPlanStore`, so the edit is identical across them with zero state threading.
struct EditorShellView: View {
    @Environment(AppRouter.self) private var router
    @Environment(VideoSession.self) private var session
    @Environment(ProjectService.self) private var projects

    /// Presented when the user taps Sort after they've already moved past it (frame 3).
    @State private var showResumeSheet = false

    /// "The Read" from anywhere in the editor — the same BreakdownSheet as the Cut Card's lip and the
    /// deck's done-card, so analytics is reachable without ever being a page.
    @State private var showRead = false

    /// Inline rename state for the header title (mirrors ProfileView's serif field + ✓ flash).
    /// `editingTitle` swaps the truncating display Text for the editable field (see `header`).
    @State private var titleDraft = ""
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool
    @State private var savedFlash = false

    private var store: EditPlanStore? { session.store }

    var body: some View {
        VStack(spacing: 0) {
            header
            StageSwitcher(current: session.editorStage,
                          furthest: session.furthestStage,
                          onSelect: select)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 4)
            stageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
        .sheet(isPresented: $showRead) {
            if let store {
                BreakdownSheet(store: store,
                               read: RetentionRead(plan: store.plan, store: store),
                               thumbs: [:], proxyURL: session.merged?.url)   // sheet self-loads its thumbs
                    .presentationDetents([.fraction(0.55), .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showResumeSheet) {
            ResumeSortSheet(
                onContinue: { showResumeSheet = false; goToSort() },
                onResort: { showResumeSheet = false; resortEverything() },
                onCancel: { showResumeSheet = false }
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.hidden)
        }
    }

    // MARK: - Header (Home · title · Export)

    private var header: some View {
        HStack(spacing: 12) {
            HomeButton { router.home() }
            Spacer()
            // Tap-to-rename title — the persisted project name (single source of truth), so this and the
            // Home tile stay in sync. Commits on Done and on focus-loss; a ✓ flashes on save.
            // At rest it's a TRUNCATING one-line Text ("A food reviewer visi…"), so a long name can
            // never spill over the Home button or squeeze Read/Export into mid-word wraps — the title
            // is the row's only compressible element; tapping it swaps in the editable field.
            HStack(spacing: 5) {
                if editingTitle {
                    TextField("Your cut", text: $titleDraft)
                        .font(VeFont.sans(14.5, weight: .semibold))
                        .foregroundStyle(Color.veCharcoal)
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onAppear { titleFocused = true }
                } else {
                    Text(titleDraft.isEmpty ? "Your cut" : titleDraft)
                        .font(VeFont.sans(14.5, weight: .semibold))
                        .foregroundStyle(Color.veWarmGray)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if savedFlash {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(Color.veSage)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else if !editingTitle {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.veFaintGray)
                }
            }
            .frame(maxWidth: 150)
            .contentShape(Rectangle())
            .onTapGesture { if !editingTitle { editingTitle = true } }
            Spacer()
            Button {
                guard !showResumeSheet else { return }   // never co-present with the resume sheet
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showRead = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 11, weight: .semibold))
                    // "Analysis", not "Analytics" — the sheet is Vela's read of the FOOTAGE, never
                    // platform performance metrics (the Retention Map's no-fake-metrics rule).
                    Text("Analysis").font(VeFont.sans(12, weight: .bold))
                }
                .foregroundStyle(Color.veNoteText)
                .frame(height: 34).padding(.horizontal, 11)
                .background(Color.veSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .fixedSize()   // never compress into a mid-word wrap — the title truncates instead
            }
            .buttonStyle(.plain)
            Button { router.go(.export) } label: {
                Text("Export")
                    .font(VeFont.sans(12.5, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
                    .frame(height: 34).padding(.horizontal, 15)
                    .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .fixedSize()   // never compress into a mid-word wrap — the title truncates instead
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 54)
        .onAppear { titleDraft = projects.name }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle(); editingTitle = false }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: savedFlash)
    }

    /// Commit the edited title. Empty or unchanged reverts to the stored name; a real rename persists it,
    /// gives a light haptic, and flashes a ✓.
    private func commitTitle() {
        guard projects.rename(to: titleDraft, session: session) else {
            titleDraft = projects.name
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        savedFlash = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            savedFlash = false
        }
    }

    // MARK: - The active stage (only one mounted at a time → one AVPlayer)

    @ViewBuilder
    private var stageContent: some View {
        switch session.editorStage {
        case .sort:    TriageView()
        case .arrange: TimelineView()
        case .polish:  PolishView()
        }
    }

    // MARK: - Stage selection

    /// Tapping a segment or swiping the strip routes here. Re-entering **Sort** after the user has moved
    /// past it doesn't drop them into a stale deck — it presents the "Back to sorting" resume sheet.
    private func select(_ stage: EditorStage) {
        guard stage != session.editorStage else { return }
        if stage == .sort && session.furthestStage.index > EditorStage.sort.index {
            showResumeSheet = true
            return
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            session.editorStage = stage
        }
    }

    /// "Continue sorting": keep all edits and open the synced Sort deck (reflecting the current cut).
    private func goToSort() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            session.editorStage = .sort
        }
    }

    /// "Re-sort everything" (confirmed): discard ALL edits by re-seeding the store from the immutable
    /// plan, reset progress, and walk the deck fresh from the top.
    private func resortEverything() {
        if let plan = session.store?.plan {
            session.store = EditPlanStore(plan: plan)
        }
        session.furthestStage = .sort
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            session.editorStage = .sort
        }
    }

}
