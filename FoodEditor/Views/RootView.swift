import SwiftUI

/// Top-level container that swaps screens based on the `AppRouter` state machine, with a soft
/// fade between them (the mockup's `fadeScreen`). Real screens replace the placeholder per milestone.
struct RootView: View {
    @State private var router: AppRouter
    @State private var session = VideoSession()
    @State private var projects = ProjectService()
    @State private var analysis = AnalysisCoordinator()
    @State private var voiceIso = VoiceIsolationCoordinator()
    @State private var clipImport = ClipImportCoordinator()
    @State private var auth = AuthStore()
    @State private var templates = TemplateService()
    @State private var create = CreateFlow()
    @State private var appRoute = AppRoute.shared       // notification-tap → navigation signal
    @Environment(\.scenePhase) private var scenePhase

    /// Gate the first screen synchronously (no home-flash): onboarding until the creator has onboarded.
    init() {
        let onboarded = UserDefaults.standard.bool(forKey: AuthStore.hasOnboardedKey)
        _router = State(initialValue: AppRouter(start: onboarded ? .home : .onboarding))
    }

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()

            Group {
                switch router.screen {
                case .onboarding:
                    OnboardingView()
                case .home:
                    HomeView()
                case .picker:
                    PickerView()
                case .brief:
                    BriefView()
                case .processing:
                    ProcessingView()
                case .analysisReveal:
                    AnalysisRevealView()
                case .segments:
                    SegmentListView()
                case .editor:
                    EditorShellView()
                case .hook:
                    HookSpotlightView()
                case .export:
                    ExportView()
                case .templateLibrary:
                    TemplateLibraryView()
                case .createSource:
                    CreateSourceView()
                case .createSelect:
                    CreateSelectView()
                case .createAnalyzing:
                    AnalyzingStepView(
                        coordinator: create.coordinator,
                        clips: create.selectedClips,
                        kicker: "NEW TEMPLATE",
                        title: "Learning a different\nside of your edits",
                        narration: AnalyzingStepView.newTemplateNarration,
                        onDone: { template in create.draft = template; router.go(.createReview) },
                        onBack: { router.back() }
                    )
                case .createReview:
                    if create.draft != nil {
                        TemplateEditorView(
                            template: Binding(get: { create.draft ?? .sample },
                                              set: { create.draft = $0 }),
                            clips: create.selectedClips,
                            mode: .newTemplate,
                            onSave: {
                                if let draft = create.draft {
                                    templates.save(draft, poster: create.coordinator.posterImage)
                                    templates.setActive(draft.id)   // the freshly-made style becomes active
                                }
                                create.reset()
                                router.go(.templateLibrary)
                            },
                            onCancel: { create.reset(); router.back() }
                        )
                    } else {
                        PlaceholderScreen(screen: router.screen)
                    }
                case .templateEditor:
                    if templates.editingDraft != nil {
                        TemplateEditorView(
                            template: Binding(get: { templates.editingDraft ?? .sample },
                                              set: { templates.editingDraft = $0 }),
                            clips: [],
                            mode: .edit,
                            onSave: {
                                if let draft = templates.editingDraft { templates.save(draft) }
                                router.back()
                            },
                            onCancel: { router.back() }
                        )
                    } else {
                        PlaceholderScreen(screen: router.screen)
                    }
                default:
                    PlaceholderScreen(screen: router.screen)
                }
            }
            .environment(router)
            .environment(session)
            .environment(projects)
            .environment(analysis)
            .environment(voiceIso)
            .environment(clipImport)
            .environment(auth)
            .environment(templates)
            .environment(create)
            .environment(appRoute)
            .transition(.opacity.combined(with: .offset(y: 7)))
            .id(router.screen)
        }
        .animation(.easeOut(duration: 0.3), value: router.screen)
        // Cold-launch recovery: if the app was KILLED mid-analysis, re-attach to the server job and
        // finish. We DON'T force-navigate — the creator lands on Home, where a "Processing" card shows
        // it's still running (HomeView reads `analysis`). Completion routes to the reveal below.
        .task {
            analysis.resumeIfPending(session: session, projects: projects)
        }
        // A notification tap (local or remote) explicitly asks to open the results; consume it once safe.
        .onChange(of: appRoute.pending) { _, pending in
            if pending == .analysis { routeToAnalysisIfSafe(); appRoute.pending = nil }
        }
        // When the analysis finishes (whether the creator is on the Home card or the full Processing
        // page), reveal the results — guarded so it never yanks them out of an active edit.
        .onChange(of: analysis.phase) { _, phase in
            if phase == .done { revealIfSafe() }
        }
        // Persist the in-progress project whenever the app backgrounds (covers app kill)…
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                analysis.resumeIfPending(session: session, projects: projects)   // re-attach after a kill
                if appRoute.pending == .analysis { routeToAnalysisIfSafe(); appRoute.pending = nil }
            } else {
                // Backgrounding mid-compression interrupts the on-device prep (iOS suspends the
                // AVFoundation export), so it can't finish while away. Ping the creator to come right
                // back. Gated to `.background` (not transient `.inactive`, e.g. Control Center) and to
                // the compress step only — uploading/analysis survive a tap-away on their own.
                if newPhase == .background && analysis.isCompressing {
                    NotificationService.shared.notify(
                        title: "Open Vela to finish",
                        body: "Compression couldn't complete while you were away — please go back to the app to finish prepping your footage."
                    )
                }
                projects.save(session: session, reaching: Self.status(for: router.screen))
            }
        }
        // …and whenever the user leaves the editor back to the Kitchen.
        .onChange(of: router.screen) { old, new in
            if new == .home && old != .home { projects.save(session: session, reaching: Self.status(for: old)) }
        }
    }

    /// A notification tap asking to open the analysis. From a "safe" pre-editor screen only (never yanks
    /// the creator out of an active edit): if it's already finished → straight to the reveal; if still
    /// running → the Processing page (the `analysis.phase` observer reveals it on completion). A stale tap
    /// with nothing in flight is a harmless no-op.
    private func routeToAnalysisIfSafe() {
        let safe: Set<AppScreen> = [.home, .picker, .brief, .processing]
        guard safe.contains(router.screen) else { return }
        if analysis.phase == .done, session.store?.plan != nil {
            router.go(.analysisReveal)
        } else if analysis.phase == .running {
            router.go(.processing)
        }
    }

    /// On analysis completion, hand off to the celebratory reveal — from Home (the Processing card),
    /// the Processing page, or the pre-brief screens. Never interrupts an active edit/export/reveal.
    private func revealIfSafe() {
        guard session.store?.plan != nil else { return }
        let safe: Set<AppScreen> = [.home, .processing, .picker, .brief]
        guard safe.contains(router.screen) else { return }
        router.go(.analysisReveal)
    }

    /// Editor screens imply the project has advanced past triage.
    private static func status(for screen: AppScreen) -> ProjectStatus? {
        switch screen {
        case .editor, .hook, .export: return .polishing
        default: return nil
        }
    }
}

/// Temporary stand-in for screens not yet built in the current milestone.
struct PlaceholderScreen: View {
    @Environment(AppRouter.self) private var router
    let screen: AppScreen

    var body: some View {
        VStack(spacing: 14) {
            Text(screen.title)
                .font(VeFont.serif(28))
                .foregroundStyle(Color.veCharcoal)
            Text("Coming in a later milestone")
                .font(VeFont.sans(14))
                .foregroundStyle(Color.veWarmGray)
            Button("← Back to Kitchen") { router.home() }
                .font(VeFont.sans(15, weight: .bold))
                .foregroundStyle(Color.veTerracotta)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.veCream.ignoresSafeArea())
    }
}

#Preview {
    RootView()
}
