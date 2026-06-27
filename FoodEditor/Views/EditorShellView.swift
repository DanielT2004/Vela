import SwiftUI

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

    /// Presented when the user taps Sort after they've already moved past it (frame 3).
    @State private var showResumeSheet = false

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
            Text(projectTitle)
                .font(VeFont.sans(14.5, weight: .semibold))
                .foregroundStyle(Color.veWarmGray)
                .lineLimit(1)
            Spacer()
            Button { router.go(.export) } label: {
                Text("Export")
                    .font(VeFont.sans(12.5, weight: .bold)).foregroundStyle(Color.veOnTerracotta)
                    .frame(height: 34).padding(.horizontal, 15)
                    .background(Color.veTerracotta, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 54)
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
            session.store = EditPlanStore(plan: plan, openerCount: session.brief?.hookSequence.count ?? 0)
        }
        session.furthestStage = .sort
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            session.editorStage = .sort
        }
    }

    /// A short friendly title from the AI summary (mirrors the derivation the views used in their headers).
    private var projectTitle: String {
        let s = (store?.plan.videoSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Your cut" }
        let words = s.split(separator: " ").prefix(3).joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}
