import SwiftUI
import UIKit

/// Wraps any SwiftUI content in a UIScrollView so users get the full
/// Photos-style pan-while-pinching experience that SwiftUI's built-in
/// ScrollView can't deliver.
///
/// The previous SwiftUI-only approach used MagnifyGesture + ScrollView,
/// but every zoom delta forced a layout pass on the content (because
/// .frame(width:) was the zoom mechanism), which combined with scroll
/// produced visible jitter. UIScrollView solves this natively: zoom is
/// done via a CGAffineTransform on the content view, pan and pinch
/// are coordinated by a single UIKit gesture recognizer, and the OS
/// handles the centering / bounce-back animations for free.
///
/// Gestures inside the SwiftUI content (lasso DragGesture, per-block
/// taps) keep working because the hosting controller's view sees touch
/// points in its own (un-transformed) coordinate space — UIKit translates
/// the screen-space touch back into content coordinates before SwiftUI
/// hit-tests.
struct ZoomablePanContainer<Content: View>: UIViewRepresentable {
    /// Toggle between Browse mode (true → pan + pinch) and Select mode
    /// (false → pinch only, single-finger drag goes to the embedded
    /// lasso gesture). Pinch stays available in both modes because it's
    /// two-finger and never conflicts with single-finger gestures.
    let isScrollEnabled: Bool

    /// When this value changes, the scroll view resets zoom to 1.0.
    /// Used to snap each newly-shown page back to fit on page navigation.
    let resetZoomTrigger: Int

    @ViewBuilder let content: () -> Content

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.isScrollEnabled = isScrollEnabled
        scrollView.backgroundColor = .clear

        let host = UIHostingController(rootView: content())
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)

        // Pin the host view to the scrollView's contentLayoutGuide on all
        // four sides, AND constrain its width to the frameLayoutGuide so
        // at zoom=1.0 the content exactly fills the viewport horizontally.
        // Once UIScrollView applies its zoom transform, contentSize grows
        // and pan becomes available naturally.
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        // Double-tap to toggle 1.0× / 2.0× — Photos shortcut. Doesn't
        // interfere with single tap (per-block selection) because UITap-
        // GestureRecognizer requires exactly two taps.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.contentView = host.view
        context.coordinator.hostingController = host
        context.coordinator.lastResetTrigger = resetZoomTrigger
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        uiView.isScrollEnabled = isScrollEnabled
        context.coordinator.hostingController?.rootView = content()

        if context.coordinator.lastResetTrigger != resetZoomTrigger {
            uiView.setZoomScale(1.0, animated: true)
            context.coordinator.lastResetTrigger = resetZoomTrigger
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var contentView: UIView?
        var hostingController: UIHostingController<Content>?
        var lastResetTrigger: Int = 0

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            let target: CGFloat = scrollView.zoomScale > 1.05 ? 1.0 : 2.0
            UIView.animate(withDuration: 0.3) {
                scrollView.setZoomScale(target, animated: false)
            }
        }
    }
}
