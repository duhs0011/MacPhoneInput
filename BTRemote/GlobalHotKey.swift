#if os(macOS)
import AppKit
import Carbon.HIToolbox
import Foundation

struct GlobalShortcut: Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let `default` = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "Space"
    )

    var displayText: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    static func load(from defaults: UserDefaults = .standard) -> GlobalShortcut {
        guard let keyCode = defaults.object(forKey: AppSettings.globalShortcutKeyCodeKey) as? NSNumber,
              let modifiers = defaults.object(forKey: AppSettings.globalShortcutModifiersKey) as? NSNumber,
              let keyLabel = defaults.string(forKey: AppSettings.globalShortcutKeyLabelKey),
              !keyLabel.isEmpty,
              keyCode.uint32Value <= UInt16.max,
              modifiers.uint32Value != 0
        else {
            return .default
        }
        return GlobalShortcut(
            keyCode: keyCode.uint32Value,
            modifiers: modifiers.uint32Value,
            keyLabel: keyLabel
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: AppSettings.globalShortcutKeyCodeKey)
        defaults.set(Int(modifiers), forKey: AppSettings.globalShortcutModifiersKey)
        defaults.set(keyLabel, forKey: AppSettings.globalShortcutKeyLabelKey)
    }

    static func capture(from event: NSEvent) -> Result<GlobalShortcut, GlobalShortcutCaptureError> {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifiers = carbonModifiers(from: flags)
        let modifierCount = [cmdKey, controlKey, optionKey, shiftKey]
            .filter { modifiers & UInt32($0) != 0 }
            .count
        guard modifierCount >= 2,
              modifiers & UInt32(cmdKey | controlKey) != 0
        else {
            return .failure(.notEnoughModifiers)
        }

        let keyCode = UInt32(event.keyCode)
        guard let keyLabel = keyLabel(for: event, keyCode: keyCode) else {
            return .failure(.unsupportedKey)
        }
        return .success(GlobalShortcut(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: keyLabel
        ))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        return result
    }

    var cocoaModifierRawValue: UInt {
        var result: UInt = 0
        if modifiers & UInt32(cmdKey) != 0 { result |= NSEvent.ModifierFlags.command.rawValue }
        if modifiers & UInt32(controlKey) != 0 { result |= NSEvent.ModifierFlags.control.rawValue }
        if modifiers & UInt32(optionKey) != 0 { result |= NSEvent.ModifierFlags.option.rawValue }
        if modifiers & UInt32(shiftKey) != 0 { result |= NSEvent.ModifierFlags.shift.rawValue }
        return result
    }

    private static func keyLabel(for event: NSEvent, keyCode: UInt32) -> String? {
        let specialKeys: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "Tab",
            UInt32(kVK_Escape): "Esc",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_Home): "Home",
            UInt32(kVK_End): "End",
            UInt32(kVK_PageUp): "Page Up",
            UInt32(kVK_PageDown): "Page Down",
            UInt32(kVK_F1): "F1",
            UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5",
            UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7",
            UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11",
            UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13",
            UInt32(kVK_F14): "F14",
            UInt32(kVK_F15): "F15",
            UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17",
            UInt32(kVK_F18): "F18",
            UInt32(kVK_F19): "F19",
            UInt32(kVK_F20): "F20"
        ]
        if let label = specialKeys[keyCode] { return label }

        guard let characters = event.charactersIgnoringModifiers,
              let first = characters.first,
              !first.isWhitespace,
              !first.isNewline
        else {
            return nil
        }
        return String(first).uppercased()
    }
}

enum GlobalShortcutCaptureError: LocalizedError, Equatable {
    case notEnoughModifiers
    case unsupportedKey

    var errorDescription: String? {
        switch self {
        case .notEnoughModifiers:
            "请使用至少两个修饰键，并且包含 ⌘ 或 ⌃。"
        case .unsupportedKey:
            "这个按键不能用作全局快捷键，请换一个按键。"
        }
    }
}

enum SystemShortcutConflictDetector {
    static func conflicts(with shortcut: GlobalShortcut) -> Bool {
        let applicationID = "com.apple.symbolichotkeys" as CFString
        let key = "AppleSymbolicHotKeys" as CFString
        guard let entries = CFPreferencesCopyAppValue(key, applicationID) as? [String: Any] else {
            return false
        }
        return conflicts(with: shortcut, entries: entries)
    }

    static func conflicts(with shortcut: GlobalShortcut, entries: [String: Any]) -> Bool {
        let modifierMask = NSEvent.ModifierFlags.command.rawValue
            | NSEvent.ModifierFlags.control.rawValue
            | NSEvent.ModifierFlags.option.rawValue
            | NSEvent.ModifierFlags.shift.rawValue

        return entries.values.contains { rawEntry in
            guard let entry = rawEntry as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber],
                  parameters.count >= 3
            else {
                return false
            }
            return parameters[1].uint32Value == shortcut.keyCode
                && parameters[2].uintValue & modifierMask == shortcut.cocoaModifierRawValue
        }
    }
}

enum GlobalHotKeyRegistrationError: Error, Equatable {
    case conflict
    case failed(OSStatus)
}

private let globalHotKeySignature: OSType = 0x4D_50_49_4E // "MPIN"
private let globalHotKeyIdentifier: UInt32 = 1

private func handleGlobalHotKey(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr,
          hotKeyID.signature == globalHotKeySignature,
          hotKeyID.id == globalHotKeyIdentifier
    else {
        return OSStatus(eventNotHandledErr)
    }

    let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in owner.performAction() }
    return noErr
}

/// Carbon hot keys work system-wide without requiring Input Monitoring access.
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var action: (() -> Void)?
    private var currentShortcut: GlobalShortcut?
    private var currentOptions: OptionBits = 0

    @discardableResult
    func register(
        shortcut: GlobalShortcut,
        exclusive: Bool,
        action: @escaping () -> Void
    ) -> Result<Void, GlobalHotKeyRegistrationError> {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handleGlobalHotKey,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            self.action = nil
            return .failure(.failed(handlerStatus))
        }

        let options = exclusive ? OptionBits(kEventHotKeyExclusive) : 0
        switch registerReference(shortcut: shortcut, options: options) {
        case .success:
            currentShortcut = shortcut
            currentOptions = options
            return .success(())
        case let .failure(error):
            unregister()
            return .failure(error)
        }
    }

    func update(
        shortcut: GlobalShortcut,
        exclusive: Bool
    ) -> Result<Void, GlobalHotKeyRegistrationError> {
        if shortcut == currentShortcut {
            return resume()
        }

        let previousShortcut = currentShortcut
        let previousOptions = currentOptions
        unregisterReference()
        let newOptions = exclusive ? OptionBits(kEventHotKeyExclusive) : 0
        switch registerReference(shortcut: shortcut, options: newOptions) {
        case .success:
            currentShortcut = shortcut
            currentOptions = newOptions
            return .success(())
        case let .failure(error):
            if let previousShortcut {
                _ = registerReference(shortcut: previousShortcut, options: previousOptions)
            }
            currentShortcut = previousShortcut
            currentOptions = previousOptions
            return .failure(error)
        }
    }

    func suspend() {
        unregisterReference()
    }

    @discardableResult
    func resume() -> Result<Void, GlobalHotKeyRegistrationError> {
        guard hotKeyRef == nil, let currentShortcut else { return .success(()) }
        return registerReference(shortcut: currentShortcut, options: currentOptions)
    }

    func unregister() {
        unregisterReference()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        eventHandlerRef = nil
        currentShortcut = nil
        currentOptions = 0
        action = nil
    }

    fileprivate func performAction() {
        action?()
    }

    private func registerReference(
        shortcut: GlobalShortcut,
        options: OptionBits
    ) -> Result<Void, GlobalHotKeyRegistrationError> {
        let hotKeyID = EventHotKeyID(signature: globalHotKeySignature, id: globalHotKeyIdentifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            options,
            &hotKeyRef
        )
        guard status == noErr else {
            hotKeyRef = nil
            if status == OSStatus(eventHotKeyExistsErr) {
                return .failure(.conflict)
            }
            return .failure(.failed(status))
        }
        return .success(())
    }

    private func unregisterReference() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
#endif
