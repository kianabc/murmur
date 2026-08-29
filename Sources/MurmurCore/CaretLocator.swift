import AppKit
import ApplicationServices

/// Finds where the user is about to type, so the HUD can sit beside it.
///
/// There is no single API that works everywhere, so this is a ladder — each rung
/// less precise than the last, and every rung has to *look* deliberate, because
/// in practice you land on the lower ones more often than you'd like
/// (SPEC.md §3.3).
///
///   1. Caret rect from the focused text element   — native apps, good Electron
///   2. Bounds of the focused element               — knows the field, not the caret
///   3. Frame of the focused window                 — knows the app
///   4. Mouse position                              — knows where you're looking
///   5. Bottom-centre of the screen                 — always works
public enum CaretLocator {
    public enum Precision: String, Sendable {
        case caret, element, window, mouse, screen
    }

    public struct Anchor: Sendable {
        /// Screen rect to sit next to, in Cocoa coordinates (origin bottom-left).
        public let rect: CGRect
        public let precision: Precision
    }

    public static func locate() -> Anchor {
        // Every rung above `mouse` needs Accessibility. Without it, don't even
        // ask — the AX calls just fail slowly.
        if AXIsProcessTrusted(), let anchor = accessibilityAnchor() {
            return anchor
        }
        if let screen = NSScreen.main {
            let mouse = NSEvent.mouseLocation
            if screen.frame.contains(mouse) {
                return Anchor(
                    rect: CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1),
                    precision: .mouse
                )
            }
        }
        return Anchor(rect: screenFallback(), precision: .screen)
    }

    // MARK: - Accessibility ladder

    /// Same reasoning as FocusProbe: six seconds of default timeout has no place
    /// anywhere near the dictation path.
    private static let messagingTimeout: Float = 0.15

    private static func accessibilityAnchor() -> Anchor? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success, let focused = focusedRef as! AXUIElement? else {
            return windowAnchor()
        }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        // 1. The caret itself: bounds of the (empty) selected range.
        if let rect = caretRect(of: focused) {
            return Anchor(rect: flip(rect), precision: .caret)
        }

        // 2. The focused element — right field, wrong line.
        if let rect = elementRect(of: focused) {
            return Anchor(rect: flip(rect), precision: .element)
        }

        return windowAnchor()
    }

    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success, let rangeValue = rangeRef as! AXValue? else { return nil }

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        // A zero-length range is the caret; collapse a selection to its start so
        // the HUD doesn't jump to the far end of a long selection.
        range.length = 0

        guard let queryValue = AXValueCreate(.cfRange, &range) else { return nil }

        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            queryValue,
            &boundsRef
        ) == .success, let boundsValue = boundsRef as! AXValue? else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect), rect.width >= 0, rect.height > 0 else {
            return nil
        }
        return rect
    }

    private static func elementRect(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef as! AXValue?,
              let sizeValue = sizeRef as! AXValue? else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 1, size.height > 1 else { return nil }

        return CGRect(origin: origin, size: size)
    }

    private static func windowAnchor() -> Anchor? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            axApp, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let window = windowRef as! AXUIElement?,
            let rect = elementRect(of: window) else { return nil }

        return Anchor(rect: flip(rect), precision: .window)
    }

    // MARK: - Coordinates

    /// AX reports top-left origin against the primary screen; Cocoa windows use
    /// bottom-left. Getting this wrong puts the HUD off-screen, not slightly off.
    private static func flip(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let maxY = primary.frame.maxY
        return CGRect(
            x: rect.origin.x,
            y: maxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func screenFallback() -> CGRect {
        guard let screen = NSScreen.main else {
            return CGRect(x: 400, y: 200, width: 1, height: 1)
        }
        let frame = screen.visibleFrame
        return CGRect(x: frame.midX, y: frame.minY + 140, width: 1, height: 1)
    }
}
