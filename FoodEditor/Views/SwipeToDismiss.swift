import SwiftUI

/// Interactive **swipe-down-to-dismiss** — a permanent UX rule for Vela: any full-screen video player
/// must be dismissible by a top-to-bottom swipe (not only a close button).
///
/// Apply `.swipeDownToDismiss { … }` to the full-screen content. The content follows the finger as you
/// drag down (revealing whatever is behind the cover); releasing past a distance/velocity threshold
/// calls `onDismiss`, otherwise it springs back. Uses `.simultaneousGesture` so it coexists with an
/// `AVKit` `VideoPlayer`'s own controls (taps / scrubber) — only deliberate downward drags dismiss.
///
/// `.sheet`-presented players already get this for free (the system sheet drag), so this is mainly for
/// `.fullScreenCover` content.
struct SwipeDownToDismiss: ViewModifier {
    let onDismiss: () -> Void
    @State private var dy: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(y: dy)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { v in
                        // Only respond to downward motion that's clearly vertical.
                        if v.translation.height > 0 && v.translation.height > abs(v.translation.width) {
                            dy = v.translation.height
                        }
                    }
                    .onEnded { v in
                        let far = v.translation.height > 130
                        let flick = v.predictedEndTranslation.height > 350 && v.translation.height > 40
                        if far || flick {
                            onDismiss()
                        } else {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { dy = 0 }
                        }
                    }
            )
    }
}

extension View {
    /// Make full-screen content dismissible with a top-to-bottom swipe. See `SwipeDownToDismiss`.
    func swipeDownToDismiss(perform onDismiss: @escaping () -> Void) -> some View {
        modifier(SwipeDownToDismiss(onDismiss: onDismiss))
    }
}
