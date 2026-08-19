#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation

    @MainActor
    final class DirectInputController: ObservableObject {
        @Published private(set) var isCapturing = false
        @Published private(set) var lastError: String?
        @Published private(set) var needsAccessibility = false
        @Published private(set) var hasAccessibilityPermission: Bool
        @Published private(set) var isDeviceConnected = false
        @Published private(set) var controlsTrackpad: Bool
        @Published private(set) var globalShortcut: GlobalShortcut

        private var eventTap: CFMachPort?
        private var runLoopSource: CFRunLoopSource?
        private let globalHotKey = GlobalHotKey()
        private var indicatorPanel: NSPanel?
        private var configuredHID: HIDInput?
        private var pressedKeys: Set<Keycode> = []
        private var pressedMouseButtons: MouseButtons = []
        private var modifiers: KeyboardModifiers = []
        private var scrollFilter = DirectInputScrollFilter()
        private var globeKey = DirectInputGlobeKey()
        private var cursorAnchor: CGPoint?
        private var hiddenCursorDisplay: CGDirectDisplayID?
        private var usedAppKitCursorFallback = false
        private var disconnectTask: Task<Void, Never>?
        private var softwareKeyboardRestoreTask: Task<Void, Never>?
        private var softwareKeyboardConnectionResetTask: Task<Void, Never>?
        private var softwareKeyboardState = SoftwareKeyboardStateMachine()
        private var isRecordingGlobalShortcut = false
        private let connectionHelpPresenter: @MainActor () -> Void
        private let softwareKeyboardRestoreDelayNanoseconds: UInt64

        private var sendKeyboard: ((KeyboardReport) -> Void)?
        private var sendMouse: ((MouseReport) -> Void)?
        private var sendConsumer: ((ConsumerReport) -> Void)?
        private var onRelease: (() -> Void)?

        init(
            softwareKeyboardRestoreDelayNanoseconds: UInt64 = 800_000_000,
            connectionHelpPresenter: @escaping @MainActor () -> Void = DirectInputConnectionAlert.present
        ) {
            self.connectionHelpPresenter = connectionHelpPresenter
            self.softwareKeyboardRestoreDelayNanoseconds = softwareKeyboardRestoreDelayNanoseconds
            hasAccessibilityPermission = AccessibilityPermission.isTrusted
            controlsTrackpad = UserDefaults.standard.object(forKey: AppSettings.controlTrackpadKey) as? Bool
                ?? AppSettings.defaultControlTrackpad
            globalShortcut = GlobalShortcut.load()
            let registration = globalHotKey.register(
                shortcut: globalShortcut,
                exclusive: globalShortcut != .default
            ) { [weak self] in
                self?.toggle()
            }
            if case .failure = registration, globalShortcut != .default {
                globalShortcut = .default
                globalShortcut.save()
                _ = globalHotKey.register(shortcut: .default, exclusive: false) { [weak self] in
                    self?.toggle()
                }
                lastError = "之前设置的全局快捷键不可用，已恢复为 ⌃⌥Space。"
            } else if case .failure = registration {
                lastError = "全局快捷键注册失败，请重新打开 MacPhone Input。"
            }
        }

        func setTrackpadControlEnabled(_ enabled: Bool) {
            guard enabled != controlsTrackpad else { return }
            guard !isCapturing else {
                lastError = "请先切回 Mac，再更改触控板控制选项。"
                return
            }
            controlsTrackpad = enabled
            UserDefaults.standard.set(enabled, forKey: AppSettings.controlTrackpadKey)
            lastError = nil
        }

        func beginGlobalShortcutRecording() {
            guard !isCapturing else { return }
            isRecordingGlobalShortcut = true
            globalHotKey.suspend()
        }

        func endGlobalShortcutRecording() {
            isRecordingGlobalShortcut = false
            if case let .failure(error) = globalHotKey.resume() {
                lastError = hotKeyRegistrationMessage(error)
            }
        }

        /// Returns a user-facing error and keeps the previous shortcut when the
        /// candidate conflicts or cannot be registered.
        func setGlobalShortcut(_ shortcut: GlobalShortcut) -> String? {
            guard !isCapturing else {
                return "请先切回 Mac，再修改全局快捷键。"
            }
            if shortcut != .default,
               SystemShortcutConflictDetector.conflicts(with: shortcut)
            {
                return "这个组合与当前已启用的 macOS 系统快捷键冲突，请换一个组合。"
            }

            let registration = globalHotKey.update(
                shortcut: shortcut,
                exclusive: shortcut != .default
            )
            switch registration {
            case .success:
                globalShortcut = shortcut
                shortcut.save()
                lastError = nil
                return nil
            case let .failure(error):
                if isRecordingGlobalShortcut { globalHotKey.suspend() }
                return hotKeyRegistrationMessage(error)
            }
        }

        private func hotKeyRegistrationMessage(_ error: GlobalHotKeyRegistrationError) -> String {
            switch error {
            case .conflict:
                "这个组合已被 macOS 或其他应用占用，请换一个组合。"
            case .failed:
                "macOS 无法注册这个组合，请换一个包含 ⌘ 或 ⌃ 的快捷键。"
            }
        }

        /// Keep the report closures alive while refreshing connection state snapshots.
        func configure(_ hid: HIDInput) {
            configuredHID = hid
            isDeviceConnected = hid.isConnected
            performSoftwareKeyboardActions(
                softwareKeyboardState.connectionChanged(hid.isConnected),
                using: hid.sendConsumer
            )
            if hid.isConnected {
                disconnectTask?.cancel()
                disconnectTask = nil
                if lastError == DirectInputConnectionAlert.inlineMessage {
                    lastError = nil
                }
            } else if isCapturing, disconnectTask == nil {
                // iPhone may briefly swap HID report subscriptions while it
                // changes keyboard/pointer mode. Only release Mac input if the
                // device remains unavailable for a full grace period.
                disconnectTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, let self,
                          self.configuredHID?.isConnected == false,
                          self.isCapturing
                    else { return }
                    self.disconnectTask = nil
                    self.stop()
                    self.lastError = "iPhone 已断开，控制已安全切回 Mac。"
                }
            }
        }

        func toggle() {
            if isCapturing {
                stop()
                return
            }
            guard let hid = configuredHID, hid.isConnected else {
                lastError = DirectInputConnectionAlert.inlineMessage
                connectionHelpPresenter()
                return
            }
            start(hid)
        }

        /// capture input and route it to HID backend
        func start(_ hid: HIDInput) {
            start(
                sendKeyboard: hid.sendKeyboard,
                sendMouse: hid.sendMouse,
                sendConsumer: hid.sendConsumer,
                onRelease: {}
            )
        }

        func start(
            sendKeyboard: @escaping (KeyboardReport) -> Void,
            sendMouse: @escaping (MouseReport) -> Void,
            sendConsumer: @escaping (ConsumerReport) -> Void,
            onRelease: @escaping () -> Void
        ) {
            stop()

            self.sendKeyboard = sendKeyboard
            self.sendMouse = sendMouse
            self.sendConsumer = sendConsumer
            self.onRelease = onRelease
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            scrollFilter.reset()
            globeKey.reset()
            lastError = nil

            refreshAccessibilityPermission()
            guard hasAccessibilityPermission else {
                needsAccessibility = true
                AccessibilityPermission.request()
                clearHandlers()
                onRelease()
                return
            }

            let mask = DirectInputMapping.capturedEventMask(trackpadEnabled: controlsTrackpad)

            let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
            guard let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: DirectInputController.eventTapCallback,
                userInfo: refcon
            ) else {
                lastError = L10n.DirectInput.captureFailedString
                clearHandlers()
                onRelease()
                return
            }

            eventTap = tap
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            if controlsTrackpad {
                cursorAnchor = CGEvent(source: nil)?.location
                lockMacCursor()
                let display = CGMainDisplayID()
                if CGDisplayHideCursor(display) == .success {
                    hiddenCursorDisplay = display
                } else {
                    NSCursor.hide()
                    usedAppKitCursorFallback = true
                }
            }
            isCapturing = true
            performSoftwareKeyboardActions(
                softwareKeyboardState.captureStarted(),
                using: sendConsumer
            )
            showIndicator()
        }

        func stop() {
            disconnectTask?.cancel()
            disconnectTask = nil
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            }
            eventTap = nil
            runLoopSource = nil

            if let display = hiddenCursorDisplay {
                CGDisplayShowCursor(display)
                hiddenCursorDisplay = nil
            }
            if usedAppKitCursorFallback {
                NSCursor.unhide()
                usedAppKitCursorFallback = false
            }
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            cursorAnchor = nil

            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            scrollFilter.reset()
            globeKey.reset()
            sendKeyboard?(.zero)
            sendMouse?(.zero)
            performSoftwareKeyboardActions(
                softwareKeyboardState.captureStopped(),
                using: sendConsumer ?? configuredHID?.sendConsumer
            )
            clearHandlers()
            hideIndicator()
            isCapturing = false
        }

        func clearAccessibilityRequest() {
            needsAccessibility = false
        }

        func refreshAccessibilityPermission() {
            hasAccessibilityPermission = AccessibilityPermission.isTrusted
            if hasAccessibilityPermission {
                needsAccessibility = false
            }
        }

        private func clearHandlers() {
            sendKeyboard = nil
            sendMouse = nil
            sendConsumer = nil
            onRelease = nil
        }

        private func performSoftwareKeyboardActions(
            _ actions: [SoftwareKeyboardStateMachine.Action],
            using sendConsumer: ((ConsumerReport) -> Void)?
        ) {
            for action in actions {
                switch action {
                case .scheduleRestore:
                    if let sendConsumer {
                        scheduleSoftwareKeyboardRestore(using: sendConsumer)
                    }
                case .cancelRestore:
                    softwareKeyboardRestoreTask?.cancel()
                    softwareKeyboardRestoreTask = nil
                case .scheduleConnectionReset:
                    scheduleSoftwareKeyboardConnectionReset()
                case .cancelConnectionReset:
                    softwareKeyboardConnectionResetTask?.cancel()
                    softwareKeyboardConnectionResetTask = nil
                case .toggleKeyboard:
                    if let sendConsumer {
                        tapEject(using: sendConsumer)
                    }
                }
            }
        }

        private func scheduleSoftwareKeyboardRestore(using sendConsumer: @escaping (ConsumerReport) -> Void) {
            guard softwareKeyboardRestoreTask == nil else { return }
            softwareKeyboardRestoreTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: softwareKeyboardRestoreDelayNanoseconds)
                guard !Task.isCancelled else { return }
                softwareKeyboardRestoreTask = nil
                performSoftwareKeyboardActions(
                    softwareKeyboardState.restoreDelayExpired(),
                    using: sendConsumer
                )
            }
        }

        private func scheduleSoftwareKeyboardConnectionReset() {
            guard softwareKeyboardConnectionResetTask == nil else { return }
            softwareKeyboardConnectionResetTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                softwareKeyboardConnectionResetTask = nil
                performSoftwareKeyboardActions(
                    softwareKeyboardState.connectionResetDelayExpired(),
                    using: nil
                )
            }
        }

        private func tapEject(using sendConsumer: @escaping (ConsumerReport) -> Void) {
            sendConsumer(ConsumerReport(key: .eject))
            // A physical Eject key is not an instantaneous down/up pair. The
            // short hold also guarantees two separate BLE connection events.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                sendConsumer(.zero)
            }
        }

        private func handle(_ event: DirectInputEvent) {
            if event.matches(globalShortcut) {
                onRelease?()
                stop()
                return
            }

            modifiers = event.modifiers

            switch event.kind {
            case let .keyDown(key):
                globeKey.noteOtherKey()
                pressedKeys.insert(key)
                sendKeyboardReport()
            case let .keyUp(key):
                pressedKeys.remove(key)
                sendKeyboardReport()
            case .capsLockTap:
                globeKey.noteOtherKey()
                sendKeyboard?(KeyboardReport(modifiers: modifiers, keys: [.capsLock]))
                sendKeyboardReport()
            case let .flagsChanged(keyCode, functionDown):
                if globeKey.flagsChanged(keyCode: keyCode, functionDown: functionDown) {
                    // Third-party Bluetooth keyboards switch iPhone layouts with
                    // Control-Space. Make the MacBook's Globe/Fn key feel native.
                    sendKeyboard?(KeyboardReport(modifiers: .leftCtrl, keys: [.space]))
                }
                sendKeyboardReport()
            case let .mouseMove(dx, dy):
                guard controlsTrackpad else { return }
                lockMacCursor()
                sendMouse?(MouseReport(buttons: pressedMouseButtons, dX: dx, dY: dy))
            case let .mouseButton(button, isDown):
                guard controlsTrackpad else { return }
                if isDown {
                    pressedMouseButtons.insert(button)
                } else {
                    pressedMouseButtons.remove(button)
                }
                sendMouse?(MouseReport(buttons: pressedMouseButtons))
            case let .scroll(rawDelta, pointDelta, isContinuous, momentumPhase):
                guard controlsTrackpad else { return }
                guard let wheel = scrollFilter.wheel(
                    rawDelta: rawDelta,
                    pointDelta: pointDelta,
                    isContinuous: isContinuous,
                    momentumPhase: momentumPhase
                ) else { return }
                sendMouse?(MouseReport(buttons: pressedMouseButtons, wheel: wheel))
                sendMouse?(MouseReport(buttons: pressedMouseButtons))
            }
        }

        private func sendKeyboardReport() {
            sendKeyboard?(KeyboardReport(modifiers: modifiers, keys: Array(pressedKeys).prefix(6).map(\.self)))
        }

        /// Some foreground apps re-associate the system pointer after AppKit's
        /// cursor state changes. Reassert both the association and the anchor on
        /// every physical movement while iPhone capture is active.
        private func lockMacCursor() {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            if let cursorAnchor {
                CGWarpMouseCursorPosition(cursorAnchor)
            }
        }

        private func showIndicator() {
            let indicatorText = controlsTrackpad
                ? "●  键盘和触控板正在控制 iPhone    \(globalShortcut.displayText) 切回 Mac"
                : "●  键盘正在控制 iPhone，触控板仍控制 Mac    \(globalShortcut.displayText) 切回"
            let label = NSTextField(labelWithString: indicatorText)
            label.textColor = .white
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.alignment = .center
            label.sizeToFit()
            let panelSize = NSSize(width: max(430, label.fittingSize.width + 28), height: 44)
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: panelSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true

            let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
            background.material = .hudWindow
            background.blendingMode = .behindWindow
            background.state = .active
            background.wantsLayer = true
            background.layer?.cornerRadius = 12

            label.frame = NSRect(x: 10, y: 12, width: panelSize.width - 20, height: 20)
            background.addSubview(label)
            panel.contentView = background

            if let screen = NSScreen.main {
                let frame = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(
                    x: frame.midX - panelSize.width / 2,
                    y: frame.maxY - panelSize.height - 12
                ))
            }
            indicatorPanel = panel
            panel.orderFrontRegardless()
        }

        private func hideIndicator() {
            indicatorPanel?.orderOut(nil)
            indicatorPanel = nil
        }

        private nonisolated static let eventTapCallback: CGEventTapCallBack = { _, type, cgEvent, userInfo in
            guard type != .tapDisabledByTimeout, type != .tapDisabledByUserInput else {
                if let userInfo {
                    let controller = Unmanaged<DirectInputController>.fromOpaque(userInfo).takeUnretainedValue()
                    Task { @MainActor in
                        controller.eventTap.map { CGEvent.tapEnable(tap: $0, enable: true) }
                        if controller.isCapturing {
                            controller.lockMacCursor()
                        }
                    }
                }
                return nil
            }

            guard let userInfo, let event = DirectInputEvent(type: type, event: cgEvent) else {
                return nil
            }

            let controller = Unmanaged<DirectInputController>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                controller.handle(event)
            }
            return nil
        }
    }

    private struct DirectInputEvent: Sendable {
        enum Kind: Sendable {
            case keyDown(Keycode)
            case keyUp(Keycode)
            case capsLockTap
            case flagsChanged(keyCode: UInt16, functionDown: Bool)
            case mouseMove(Int8, Int8)
            case mouseButton(MouseButtons, Bool)
            case scroll(rawDelta: Int64, pointDelta: Int64, isContinuous: Bool, momentumPhase: Int64)
        }

        let kind: Kind
        let modifiers: KeyboardModifiers
        let shortcutKeyCode: UInt32
        let shortcutModifiers: UInt32
        let isShortcutKeyDown: Bool

        init?(type: CGEventType, event: CGEvent) {
            let flags = event.flags
            modifiers = KeyboardModifiers(eventFlags: flags)
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Use the event's actual flags. Querying the combined-session key
            // state is incorrect for a suppressing event tap: intercepted
            // modifier-up events can leave that global state looking stuck and
            // turn a later plain Space into the release shortcut.
            shortcutKeyCode = UInt32(keyCode)
            shortcutModifiers = GlobalShortcut.carbonModifiers(from: flags)
            isShortcutKeyDown = type == .keyDown && !isRepeat

            switch type {
            case .keyDown:
                if isRepeat { return nil }
                guard let key = Keycode(macVirtualKey: UInt16(event.getIntegerValueField(.keyboardEventKeycode))) else { return nil }
                kind = .keyDown(key)
            case .keyUp:
                guard let key = Keycode(macVirtualKey: UInt16(event.getIntegerValueField(.keyboardEventKeycode))) else { return nil }
                kind = .keyUp(key)
            case .flagsChanged:
                if keyCode == 0x39 {
                    kind = .capsLockTap
                } else {
                    kind = .flagsChanged(
                        keyCode: keyCode,
                        functionDown: flags.contains(.maskSecondaryFn)
                    )
                }
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                let dx = Self.clampInt8(event.getIntegerValueField(.mouseEventDeltaX))
                let dy = Self.clampInt8(event.getIntegerValueField(.mouseEventDeltaY))
                guard dx != 0 || dy != 0 else { return nil }
                kind = .mouseMove(dx, dy)
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
                guard let button = Self.mouseButton(for: type) else { return nil }
                kind = .mouseButton(button.0, button.1)
            case .scrollWheel:
                kind = .scroll(
                    rawDelta: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                    pointDelta: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
                    isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                    momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
                )
            default:
                return nil
            }
        }

        func matches(_ shortcut: GlobalShortcut) -> Bool {
            isShortcutKeyDown
                && shortcutKeyCode == shortcut.keyCode
                && shortcutModifiers == shortcut.modifiers
        }

        private static func clampInt8(_ value: Int64) -> Int8 {
            Int8(max(-127, min(127, Int(value))))
        }

        private static func mouseButton(for type: CGEventType) -> (MouseButtons, Bool)? {
            switch type {
            case .leftMouseDown: (.left, true)
            case .leftMouseUp: (.left, false)
            case .rightMouseDown: (.right, true)
            case .rightMouseUp: (.right, false)
            case .otherMouseDown: (.middle, true)
            case .otherMouseUp: (.middle, false)
            default: nil
            }
        }
    }

    /// Pure transition model for iPhone's onscreen keyboard. Keeping timing and
    /// HID side effects outside this type makes every connection/capture race
    /// deterministic and independently testable.
    struct SoftwareKeyboardStateMachine {
        enum Action: Equatable {
            case scheduleRestore
            case cancelRestore
            case scheduleConnectionReset
            case cancelConnectionReset
            case toggleKeyboard
        }

        private(set) var isConnected = false
        private(set) var isCapturing = false
        private(set) var isSoftwareKeyboardShown = false

        mutating func connectionChanged(_ connected: Bool) -> [Action] {
            guard connected != isConnected else { return [] }
            isConnected = connected

            if connected {
                var actions: [Action] = [.cancelConnectionReset]
                if !isCapturing, !isSoftwareKeyboardShown {
                    actions.append(.scheduleRestore)
                }
                return actions
            }

            return [.cancelRestore, .scheduleConnectionReset]
        }

        mutating func restoreDelayExpired() -> [Action] {
            guard isConnected, !isCapturing, !isSoftwareKeyboardShown else { return [] }
            isSoftwareKeyboardShown = true
            return [.toggleKeyboard]
        }

        mutating func connectionResetDelayExpired() -> [Action] {
            guard !isConnected else { return [] }
            isSoftwareKeyboardShown = false
            return []
        }

        mutating func captureStarted() -> [Action] {
            guard !isCapturing else { return [] }
            isCapturing = true
            var actions: [Action] = [.cancelRestore]
            if isSoftwareKeyboardShown {
                isSoftwareKeyboardShown = false
                actions.append(.toggleKeyboard)
            }
            return actions
        }

        mutating func captureStopped() -> [Action] {
            guard isCapturing else { return [] }
            isCapturing = false
            guard isConnected else { return [] }
            isSoftwareKeyboardShown = true
            return [.toggleKeyboard]
        }
    }

    @MainActor
    enum DirectInputConnectionAlert {
        static let inlineMessage = "MacPhoneInput 尚未与 iPhone 建立外接键盘连接。"

        static func present() {
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "iPhone 未连接"
            alert.informativeText = "MacPhoneInput 尚未与 iPhone 建立外接键盘连接。请先确认 Mac 和 iPhone 的蓝牙均已开启；如果没有自动重连，请前往 iPhone 的“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”，点按 MacPhoneInput。"
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    enum DirectInputMapping {
        static func capturedEventMask(trackpadEnabled: Bool) -> CGEventMask {
            // AppKit exposes trackpad magnify, rotate, swipe, smart-magnify,
            // pressure, and generic gesture events outside CGEventType's
            // named mouse cases. An all-events HID tap is necessary to stop
            // those gestures from reaching Mission Control or the foreground
            // Mac app while the trackpad belongs to the iPhone.
            if trackpadEnabled { return .max }

            let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
            return types.reduce(CGEventMask(0)) { result, type in
                result | (CGEventMask(1) << CGEventMask(type.rawValue))
            }
        }

        static func isToggleShortcut(
            type: CGEventType,
            keyCode: UInt16,
            modifiers: UInt32,
            isRepeat: Bool,
            shortcut: GlobalShortcut
        ) -> Bool {
            type == .keyDown
                && UInt32(keyCode) == shortcut.keyCode
                && modifiers == shortcut.modifiers
                && !isRepeat
        }

    }

    /// A MacBook's Globe/Fn key is Apple-specific and has no bit in the standard
    /// Bluetooth keyboard modifier byte. Treat a solitary press as iPhone's
    /// documented Control-Space layout shortcut, while leaving Fn chords alone.
    struct DirectInputGlobeKey {
        private(set) var isArmed = false

        mutating func reset() {
            isArmed = false
        }

        mutating func noteOtherKey() {
            isArmed = false
        }

        mutating func flagsChanged(keyCode: UInt16, functionDown: Bool) -> Bool {
            guard keyCode == 0x3F else {
                isArmed = false
                return false
            }
            if functionDown {
                isArmed = true
                return false
            }
            let shouldSwitchInput = isArmed
            isArmed = false
            return shouldSwitchInput
        }
    }

    /// Converts high-resolution trackpad scrolling into conservative HID wheel
    /// ticks. iOS applies its own scroll physics, so forwarding macOS momentum
    /// would otherwise create a second inertial tail and severe overscroll.
    struct DirectInputScrollFilter {
        private var continuousRemainder = 0.0
        private static let pointsPerTick = 12.0
        private static let maximumTicksPerEvent = 3

        mutating func reset() {
            continuousRemainder = 0
        }

        mutating func wheel(
            rawDelta: Int64,
            pointDelta: Int64,
            isContinuous: Bool,
            momentumPhase: Int64
        ) -> Int8? {
            guard momentumPhase == 0 else { return nil }

            if !isContinuous {
                continuousRemainder = 0
                let inverted = -Int(rawDelta)
                guard inverted != 0 else { return nil }
                return Int8(max(-Self.maximumTicksPerEvent, min(Self.maximumTicksPerEvent, inverted)))
            }

            let points = pointDelta == 0 ? rawDelta : pointDelta
            let scaled = -Double(points) / Self.pointsPerTick
            guard scaled != 0 else { return nil }

            if continuousRemainder != 0, scaled.sign != continuousRemainder.sign {
                continuousRemainder = 0
            }
            continuousRemainder += scaled

            let wholeTicks = Int(continuousRemainder.rounded(.towardZero))
            guard wholeTicks != 0 else { return nil }
            let emitted = max(-Self.maximumTicksPerEvent, min(Self.maximumTicksPerEvent, wholeTicks))
            continuousRemainder -= Double(emitted)
            return Int8(emitted)
        }
    }

    private extension KeyboardModifiers {
        init(eventFlags flags: CGEventFlags) {
            self.init()
            if flags.contains(.maskControl) { insert(.leftCtrl) }
            if flags.contains(.maskShift) { insert(.leftShift) }
            if flags.contains(.maskAlternate) { insert(.leftAlt) }
            if flags.contains(.maskCommand) { insert(.leftGUI) }
        }
    }

    private extension Keycode {
        init?(macVirtualKey key: UInt16) {
            guard let code = Self.macVirtualKeys[key] else { return nil }
            self = code
        }

        static let macVirtualKeys: [UInt16: Keycode] = [
            0x00: .a, 0x0B: .b, 0x08: .c, 0x02: .d, 0x0E: .e, 0x03: .f, 0x05: .g, 0x04: .h,
            0x22: .i, 0x26: .j, 0x28: .k, 0x25: .l, 0x2E: .m, 0x2D: .n, 0x1F: .o, 0x23: .p,
            0x0C: .q, 0x0F: .r, 0x01: .s, 0x11: .t, 0x20: .u, 0x09: .v, 0x0D: .w, 0x07: .x,
            0x10: .y, 0x06: .z,
            0x12: .digit1, 0x13: .digit2, 0x14: .digit3, 0x15: .digit4, 0x17: .digit5,
            0x16: .digit6, 0x1A: .digit7, 0x1C: .digit8, 0x19: .digit9, 0x1D: .digit0,
            0x24: .return, 0x4C: .return,
            0x35: .escape, 0x33: .backspace, 0x30: .tab, 0x31: .space,
            0x1B: .minus, 0x18: .equal, 0x21: .leftBracket, 0x1E: .rightBracket,
            0x2A: .backslash, 0x29: .semicolon, 0x27: .quote, 0x32: .grave,
            0x2B: .comma, 0x2F: .period, 0x2C: .slash, 0x39: .capsLock,
            0x7A: .f1, 0x78: .f2, 0x63: .f3, 0x76: .f4, 0x60: .f5, 0x61: .f6,
            0x62: .f7, 0x64: .f8, 0x65: .f9, 0x6D: .f10, 0x67: .f11, 0x6F: .f12,
            0x7C: .rightArrow, 0x7B: .leftArrow, 0x7D: .downArrow, 0x7E: .upArrow
        ]
    }

#elseif os(iOS)
    import CoreGraphics
    import Foundation
    import GameController
    import SwiftUI
    import UIKit

    @MainActor
    final class DirectInputController: ObservableObject {
        @Published private(set) var isCapturing = false
        @Published private(set) var lastError: String?
        @Published private(set) var hasInputDevice = false

        private var sendKeyboard: ((KeyboardReport) -> Void)?
        private var sendMouse: ((MouseReport) -> Void)?
        private var pressedKeys: Set<Keycode> = []
        private var pressedMouseButtons: MouseButtons = []
        private var modifiers: KeyboardModifiers = []
        private var observers: [NSObjectProtocol] = []

        // GCMouse deltas are in points; tune on-device
        private static let sensitivity: CGFloat = 1
        private static let scrollSensitivity: CGFloat = 1

        init() {
            refreshDevicePresence()
            observeDevices()
        }

        func start(_ hid: HIDInput) {
            start(sendKeyboard: hid.sendKeyboard, sendMouse: hid.sendMouse)
        }

        func start(
            sendKeyboard: @escaping (KeyboardReport) -> Void,
            sendMouse: @escaping (MouseReport) -> Void
        ) {
            stop()
            guard hasInputDevice else { return }

            self.sendKeyboard = sendKeyboard
            self.sendMouse = sendMouse
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            lastError = nil

            attachHandlers()
            isCapturing = true
        }

        func stop() {
            detachHandlers()
            if isCapturing {
                sendKeyboard?(.zero)
                sendMouse?(.zero)
            }
            pressedKeys.removeAll()
            pressedMouseButtons = []
            modifiers = []
            sendKeyboard = nil
            sendMouse = nil
            isCapturing = false
        }

        private func attachHandlers() {
            if let keyboard = GCKeyboard.coalesced {
                keyboard.handlerQueue = .main
                keyboard.keyboardInput?.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
                    let raw = keyCode.rawValue
                    Task { @MainActor in self?.handleKey(raw: raw, pressed: pressed) }
                }
            }
            if let mouse = GCMouse.current {
                mouse.handlerQueue = .main
                let input = mouse.mouseInput
                input?.mouseMovedHandler = { [weak self] _, dx, dy in
                    Task { @MainActor in self?.handleMove(dx: dx, dy: dy) }
                }
                input?.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.left, pressed) }
                }
                input?.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.right, pressed) }
                }
                input?.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                    Task { @MainActor in self?.handleButton(.middle, pressed) }
                }
                input?.scroll.valueChangedHandler = { [weak self] _, _, y in
                    Task { @MainActor in self?.handleScroll(y) }
                }
            }
        }

        private func detachHandlers() {
            GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
            if let input = GCMouse.current?.mouseInput {
                input.mouseMovedHandler = nil
                input.leftButton.pressedChangedHandler = nil
                input.rightButton?.pressedChangedHandler = nil
                input.middleButton?.pressedChangedHandler = nil
                input.scroll.valueChangedHandler = nil
            }
        }

        /// GCKeyCode raw values are HID usage IDs; 0xE0...0xE7 are modifier keys
        private func handleKey(raw: Int, pressed: Bool) {
            if (0xE0 ... 0xE7).contains(raw) {
                let mod = KeyboardModifiers(rawValue: UInt8(1) << UInt8(raw - 0xE0))
                if pressed { modifiers.insert(mod) } else { modifiers.remove(mod) }
            } else if let key = Keycode(rawValue: UInt8(truncatingIfNeeded: raw)) {
                if pressed { pressedKeys.insert(key) } else { pressedKeys.remove(key) }
            } else {
                return
            }
            if releaseComboHeld {
                stop()
                return
            }
            sendKeyboard?(KeyboardReport(modifiers: modifiers, keys: Array(pressedKeys.prefix(6))))
        }

        private var releaseComboHeld: Bool {
            !modifiers.isDisjoint(with: [.leftCtrl, .rightCtrl]) &&
                !modifiers.isDisjoint(with: [.leftAlt, .rightAlt])
        }

        private func handleMove(dx: Float, dy: Float) {
            let mx = HIDInput.clamp(CGFloat(dx) * Self.sensitivity)
            let my = HIDInput.clamp(CGFloat(-dy) * Self.sensitivity) // GC y is up-positive, HID is down-positive
            guard mx != 0 || my != 0 else { return }
            sendMouse?(MouseReport(buttons: pressedMouseButtons, dX: mx, dY: my))
        }

        private func handleButton(_ button: MouseButtons, _ pressed: Bool) {
            if pressed { pressedMouseButtons.insert(button) } else { pressedMouseButtons.remove(button) }
            sendMouse?(MouseReport(buttons: pressedMouseButtons))
        }

        private func handleScroll(_ y: Float) {
            let wheel = HIDInput.clamp(CGFloat(y) * Self.scrollSensitivity)
            guard wheel != 0 else { return }
            sendMouse?(MouseReport(buttons: pressedMouseButtons, wheel: wheel))
            sendMouse?(MouseReport(buttons: pressedMouseButtons))
        }

        private func refreshDevicePresence() {
            hasInputDevice = GCKeyboard.coalesced != nil || GCMouse.current != nil
        }

        private func observeDevices() {
            let names: [Notification.Name] = [
                .GCKeyboardDidConnect, .GCKeyboardDidDisconnect, .GCMouseDidConnect, .GCMouseDidDisconnect
            ]
            for name in names {
                let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        self.refreshDevicePresence()
                        if self.isCapturing { self.attachHandlers() }
                        if !self.hasInputDevice { self.stop() }
                    }
                }
                observers.append(token)
            }
        }
    }

    /// iPadOS pointer lock hides system pointer so GameController receives raw deltas
    struct PointerLockHost: UIViewControllerRepresentable {
        var locked: Bool

        func makeUIViewController(context: Context) -> PointerLockController {
            PointerLockController()
        }

        func updateUIViewController(_ controller: PointerLockController, context: Context) {
            controller.locked = locked
        }
    }

    final class PointerLockController: UIViewController {
        var locked = false {
            didSet {
                guard locked != oldValue else { return }
                setNeedsUpdateOfPrefersPointerLocked()
            }
        }

        override var prefersPointerLocked: Bool {
            locked
        }
    }
#endif
