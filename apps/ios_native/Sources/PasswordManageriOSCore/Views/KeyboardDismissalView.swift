#if os(iOS)
import SwiftUI
import UIKit

// Attach to this scene's window so presented forms follow the same editing behavior.
struct KeyboardDismissalView: UIViewRepresentable {
    func makeUIView(context: Context) -> KeyboardDismissalObserver {
        KeyboardDismissalObserver()
    }

    func updateUIView(_ uiView: KeyboardDismissalObserver, context: Context) {}

    static func dismantleUIView(_ uiView: KeyboardDismissalObserver, coordinator: ()) {
        uiView.detach()
    }
}

final class KeyboardDismissalObserver: UIView, UIGestureRecognizerDelegate {
    private weak var observedWindow: UIWindow?
    private lazy var outsideInputTap: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        return tap
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        observedWindow = window
        window?.addGestureRecognizer(outsideInputTap)
    }

    func detach() {
        observedWindow?.removeGestureRecognizer(outsideInputTap)
        observedWindow = nil
    }

    @objc private func dismissKeyboard() {
        observedWindow?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Never end editing while focusing, selecting, or moving between inputs.
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
#endif
