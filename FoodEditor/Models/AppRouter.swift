import Foundation
import Observation

/// Screens in the flow, mirroring the mockup's screen state machine.
enum AppScreen: Equatable {
    case home, picker, processing, segments, triage, timeline, hook, polish, export, profile

    var title: String {
        switch self {
        case .home:       return "Kitchen"
        case .picker:     return "Camera roll"
        case .processing: return "Working"
        case .segments:   return "Your breakdown"
        case .triage:     return "Triage"
        case .timeline:   return "Shape"
        case .hook:       return "Pick your hook"
        case .polish:     return "Polish"
        case .export:     return "Export"
        case .profile:    return "Your style"
        }
    }
}

/// Lightweight navigation state machine with a history stack (matches the mockup's `go`/`back`).
@Observable
final class AppRouter {
    var screen: AppScreen = .home
    private(set) var history: [AppScreen] = []

    func go(_ screen: AppScreen) {
        history.append(self.screen)
        self.screen = screen
    }

    func back() {
        screen = history.popLast() ?? .home
    }

    func home() {
        history.removeAll()
        screen = .home
    }
}
