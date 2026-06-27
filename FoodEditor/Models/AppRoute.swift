import Observation

/// A tiny shared signal for "the system (a notification tap) wants the app to navigate somewhere."
///
/// `NotificationService` is a non-View singleton and can't touch `RootView`'s `@State` router directly,
/// so it writes a *pending* route here; `RootView` observes this and consumes it once it's safe to move
/// (i.e. not mid-edit). A shared `@Observable` mirrors how `AnalysisCoordinator` / `ProjectService` are
/// shared, and survives `RootView`'s `.id(router.screen)` body recreation (a registered closure would not).
@MainActor
@Observable
final class AppRoute {
    static let shared = AppRoute()

    enum Pending: Equatable {
        case analysis   // open into the freshly-finished analysis (reveal → breakdown)
    }

    /// Set by `NotificationService` on a notification tap; cleared by `RootView` after it routes.
    var pending: Pending?
}
