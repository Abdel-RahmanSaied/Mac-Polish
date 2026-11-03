import AppKit
import SwiftUI

/// Tracks the app's single main window. `openWindow(id:)` on a WindowGroup always creates another
/// window, so callers bring this one forward and only open a new window when none exists.
@MainActor
enum MainWindow {
    private(set) static var window: NSWindow?

    /// Called by the main content when it is placed in a window, so the right window is tracked
    /// whenever SwiftUI creates it (including a replacement after `openWindow`).
    static func register(_ window: NSWindow) {
        window.isReleasedWhenClosed = false
        self.window = window
    }

    /// Brings the tracked main window forward, including after it was closed. Returns false when none exists.
    @discardableResult
    static func showExisting() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}

/// Place in the main content's background; registers the hosting window with `MainWindow`.
struct MainWindowRegistration: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Reporter() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Reporter: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainWindow.register(window) }
        }
    }
}
