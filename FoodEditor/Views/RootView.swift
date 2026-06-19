import SwiftUI

/// Top-level container that swaps screens based on the `AppRouter` state machine, with a soft
/// fade between them (the mockup's `fadeScreen`). Real screens replace the placeholder per milestone.
struct RootView: View {
    @State private var router = AppRouter()
    @State private var session = VideoSession()
    @State private var projects = ProjectService()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.veCream.ignoresSafeArea()

            Group {
                switch router.screen {
                case .home:
                    HomeView()
                case .picker:
                    PickerView()
                case .processing:
                    ProcessingView()
                case .segments:
                    SegmentListView()
                case .triage:
                    TriageView()
                case .timeline:
                    TimelineView()
                case .hook:
                    HookSpotlightView()
                case .polish:
                    PolishView()
                case .export:
                    ExportView()
                default:
                    PlaceholderScreen(screen: router.screen)
                }
            }
            .environment(router)
            .environment(session)
            .environment(projects)
            .transition(.opacity.combined(with: .offset(y: 7)))
            .id(router.screen)
        }
        .animation(.easeOut(duration: 0.3), value: router.screen)
        // Persist the in-progress project whenever the app backgrounds (covers app kill)…
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { projects.save(session: session, reaching: Self.status(for: router.screen)) }
        }
        // …and whenever the user leaves the editor back to the Kitchen.
        .onChange(of: router.screen) { old, new in
            if new == .home && old != .home { projects.save(session: session, reaching: Self.status(for: old)) }
        }
    }

    /// Editor screens imply the project has advanced past triage.
    private static func status(for screen: AppScreen) -> ProjectStatus? {
        switch screen {
        case .timeline, .polish, .hook, .export: return .polishing
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
