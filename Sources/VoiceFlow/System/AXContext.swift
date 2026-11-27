import AppKit
import ApplicationServices

/// Reads the focused text field through the Accessibility API: text before the cursor
/// (context for the AI editor), the selection (Command Mode), and the window title.
enum AXContext {
    private static let timeout: Float = 0.25

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        return element(system, kAXFocusedUIElementAttribute)
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    /// `known` is false when the app doesn't expose a selection at all.
    static func selectedText(_ element: AXUIElement) -> (known: Bool, text: String?) {
        guard let value = attribute(element, kAXSelectedTextAttribute) else { return (false, nil) }
        guard let text = value as? String, !text.isEmpty else { return (true, nil) }
        return (true, text)
    }

    static func precedingText(_ element: AXUIElement, maxCharacters: Int) -> String? {
        guard let range = selectedRange(element) else { return nil }
        let end = range.location
        guard end > 0 else { return "" }
        let start = max(0, end - maxCharacters)

        // Cheap path: ask for just the slice we need.
        var slice = CFRange(location: start, length: end - start)
        if let axRange = AXValueCreate(.cfRange, &slice) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, axRange, &out) == .success,
               let text = out as? String {
                return text
            }
        }
        // Fallback: the whole value, unless the document is huge.
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count > 50_000 { return nil }
        guard let value = string(element, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard end <= ns.length else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    static func focusedWindowTitle(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let window = element(app, kAXFocusedWindowAttribute) else { return nil }
        return string(window, kAXTitleAttribute)
    }

    // MARK: - Helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let value = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}
