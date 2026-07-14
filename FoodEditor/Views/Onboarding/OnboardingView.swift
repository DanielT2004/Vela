import SwiftUI

/// First-run onboarding. One router screen that owns its own linear `step` machine:
/// 0 Welcome → 1 Sign up → 2 Connect → 3 Analyzing → 4 The Reveal → 5 Style profile → enter the app.
struct OnboardingView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AuthStore.self) private var auth
    @Environment(VideoSession.self) private var session
    @Environment(TemplateService.self) private var templates

    @State private var step = 0
    @State private var styleCoordinator = StyleAnalysisCoordinator(origin: .onboarding)
    @State private var analyzedTemplate: StyleTemplate?

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()

            Group {
                switch step {
                case 0:
                    WelcomeStepView { goTo(1) }
                case 1:
                    SignUpStepView { goTo(2) }
                case 2:
                    ConnectStepView(onBack: { goTo(1) }, onContinue: { goTo(3) }, onSkip: { skipAndEnter() })
                case 3:
                    AnalyzingStepView(
                        coordinator: styleCoordinator,
                        clips: session.clips,
                        onDone: { template in analyzedTemplate = template; goTo(4) },
                        onBack: { goTo(2) }
                    )
                case 4:
                    // The Reveal — the feel-heard moment between analysis and the editable template.
                    if analyzedTemplate != nil {
                        StyleRevealView(
                            template: Binding($analyzedTemplate)!,
                            firstName: auth.firstName,
                            onDone: { goTo(5) }
                        )
                    } else {
                        Color.veCream  // shouldn't happen; step 4 only follows a successful analysis
                    }
                default:
                    if analyzedTemplate != nil {
                        TemplateEditorView(
                            template: Binding($analyzedTemplate)!,
                            clips: session.clips,
                            mode: .onboarding,
                            onSave: { saveAndEnter() }
                        )
                    } else {
                        Color.veCream  // shouldn't happen; step 5 only follows a successful analysis
                    }
                }
            }
            .transition(.opacity.combined(with: .offset(y: 7)))
            .id(step)
        }
        .animation(.easeOut(duration: 0.3), value: step)
        // Kill recovery: if the app was closed mid-style-learn during onboarding, re-attach to the server
        // job on relaunch and jump to the Analyzing step — which polls to completion and advances to review.
        .task {
            if styleCoordinator.resumeIfPending() { step = 3 }
        }
    }

    private func goTo(_ next: Int) { step = next }

    private func saveAndEnter() {
        if let t = analyzedTemplate {
            templates.save(t, poster: styleCoordinator.posterImage)   // first template auto-becomes active
        }
        StyleJobStore.clear()   // template is now durable — safe to drop the kill-recovery record
        auth.hasOnboarded = true
        router.home()
    }

    /// Skip the style-learn at the Connect door. Defensive `startFresh()`: Connect ingests picks into
    /// the SHARED VideoSession, so a skip after any pick must not leak onboarding clips into the
    /// Kitchen → Picker flow. The learn path itself stays byte-identical.
    private func skipAndEnter() {
        session.startFresh()
        auth.hasOnboarded = true
        router.home()
    }
}
