#if os(macOS)
    import AppKit
    import ApplicationServices

    @MainActor
    enum AccessibilityPermission {
        static var isTrusted: Bool {
            AXIsProcessTrusted()
        }

        @discardableResult
        static func request() -> Bool {
            // kAXTrustedCheckOptionPrompt is imported as mutable global state,
            // which Swift 6 rejects under strict concurrency. This is its
            // documented, stable CFString value.
            let promptOption = "AXTrustedCheckOptionPrompt"
            return AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary)
        }

        static func openSettings() {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }
#endif
