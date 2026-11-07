import AppKit
import SwiftUI

/// Configure our own window when SwiftUI attaches its content.
struct WindowConfiguration: NSViewRepresentable {
    final class ConfigurationView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert([.resizable, .closable, .miniaturizable])
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.standardWindowButton(.zoomButton)?.isEnabled = true
            window.tabbingMode = .disallowed
        }
    }
    func makeNSView(context: Context) -> ConfigurationView { ConfigurationView() }
    func updateNSView(_ nsView: ConfigurationView, context: Context) {}
}
