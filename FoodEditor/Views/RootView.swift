import SwiftUI

/// Top-level container that swaps screens based on the `AppRouter` state machine, with a soft
/// fade between them (the mockup's `fadeScreen`). Real screens replace the placeholder per milestone.
struct RootView: View {
    @State private var router = AppRouter()
    @State private var session = VideoSession()

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
                default:
                    PlaceholderScreen(screen: router.screen)
                }
            }
            .environment(router)
            .environment(session)
            .transition(.opacity.combined(with: .offset(y: 7)))
            .id(router.screen)
        }
        .animation(.easeOut(duration: 0.3), value: router.screen)
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
