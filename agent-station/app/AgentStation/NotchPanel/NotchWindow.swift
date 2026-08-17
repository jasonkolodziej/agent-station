import AppKit

/// Borderless transparent panel above the menu bar.
///
/// The two properties below are not stylistic — a notch UI that pulls focus
/// mid-typing gets uninstalled the same day.
public final class NotchWindow: NSPanel {
    public init(contentRect: CGRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // TODO(M3): observe NSApplication.didChangeScreenParametersNotification
        // and re-lay-out. Display reconfiguration is the #1 way these panels die.
    }
}
