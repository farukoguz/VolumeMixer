import AppKit
import SwiftUI

/// Reports whether the window hosting this view is actually on screen.
///
/// Driven by the window's occlusion state, which AppKit updates whenever any
/// part of a window moves on or off screen. That covers the menu bar panel
/// opening and closing, and also the screen locking or the display sleeping,
/// when there is equally nothing to draw meters for.
struct PanelVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
    }

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        /// Deferred to the next main-loop turn: this can run in the middle of a
        /// SwiftUI update, where publishing model changes is not allowed.
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let visible = self.window.map {
                    $0.isVisible && $0.occlusionState.contains(.visible)
                } ?? false
                self.onChange?(visible)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
