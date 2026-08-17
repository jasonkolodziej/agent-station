import AppKit

/// Hardware-aligned geometry (ARCHITECTURE.md §6.4).
///
/// One layout engine, two silhouettes. Non-notch Macs and external displays are
/// probably a majority of sessions — the floating pill must not feel like a
/// consolation prize, so do NOT fork the view hierarchy for it.
public enum NotchGeometry {
    public static func notchRect(for screen: NSScreen) -> CGRect? {
        guard screen.safeAreaInsets.top > 0 else { return nil }   // no notch
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        let height = screen.safeAreaInsets.top
        return CGRect(x: left.width,
                      y: screen.frame.height - height,
                      width: width, height: height)
    }

    public enum Silhouette { case notched(CGRect), pill(CGRect) }

    public static func silhouette(for screen: NSScreen) -> Silhouette {
        if let r = notchRect(for: screen) { return .notched(r) }
        let w: CGFloat = 200, h: CGFloat = 32
        return .pill(CGRect(x: (screen.frame.width - w) / 2,
                            y: screen.frame.height - h, width: w, height: h))
    }
}
