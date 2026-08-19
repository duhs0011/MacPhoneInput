import AppKit
import CoreBluetooth
import XCTest
@testable import MacPhoneInput

final class HIDReportTests: XCTestCase {
    @MainActor
    func testIdleConnectionRestoresSoftwareKeyboardOnlyOnce() async {
        var consumerReports: [ConsumerReport] = []
        let controller = DirectInputController(
            softwareKeyboardRestoreDelayNanoseconds: 0,
            connectionHelpPresenter: {}
        )
        let connectedHID = HIDInput(
            sendMouse: { _ in },
            sendKeyboard: { _ in },
            sendConsumer: { consumerReports.append($0) },
            updateBattery: { _ in },
            isActive: true,
            isConnected: true,
            activeError: nil,
            batteryLevel: 100
        )

        controller.configure(connectedHID)
        await Task.yield()
        await Task.yield()
        controller.configure(connectedHID)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(consumerReports, [ConsumerReport(key: .eject), .zero])
        XCTAssertTrue(controller.isDeviceConnected)
        XCTAssertFalse(controller.isCapturing)
    }

    @MainActor
    func testPendingIdleRestoreIsCancelledWhenConnectionDrops() async {
        var consumerReports: [ConsumerReport] = []
        let controller = DirectInputController(
            softwareKeyboardRestoreDelayNanoseconds: 100_000_000,
            connectionHelpPresenter: {}
        )
        let connectedHID = HIDInput(
            sendMouse: { _ in },
            sendKeyboard: { _ in },
            sendConsumer: { consumerReports.append($0) },
            updateBattery: { _ in },
            isActive: true,
            isConnected: true,
            activeError: nil,
            batteryLevel: 100
        )

        controller.configure(connectedHID)
        controller.configure(.unavailable)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(consumerReports.isEmpty)
        XCTAssertFalse(controller.isDeviceConnected)
    }

    @MainActor
    func testDisconnectedToggleShowsConnectionHelp() {
        var presentationCount = 0
        let controller = DirectInputController {
            presentationCount += 1
        }

        controller.toggle()

        XCTAssertEqual(presentationCount, 1)
        XCTAssertEqual(controller.lastError, DirectInputConnectionAlert.inlineMessage)
        XCTAssertFalse(controller.isCapturing)

        let connectedHID = HIDInput(
            sendMouse: { _ in },
            sendKeyboard: { _ in },
            sendConsumer: { _ in },
            updateBattery: { _ in },
            isActive: true,
            isConnected: true,
            activeError: nil,
            batteryLevel: 100
        )
        controller.configure(connectedHID)

        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.isDeviceConnected)
    }

    func testMouseReportEncodingPreservesSignedDeltas() {
        let report = MouseReport(buttons: [.left, .right], dX: -127, dY: 126, wheel: -1)
        XCTAssertEqual(Array(report.data), [0b0000_0011, 0x81, 0x7E, 0xFF])
    }

    func testKeyboardReportIsEightBytesAndLimitedToSixKeys() {
        let report = KeyboardReport(
            modifiers: [.leftShift, .leftGUI],
            keys: [.a, .b, .c, .d, .e, .f, .g]
        )
        XCTAssertEqual(Array(report.data), [0b0000_1010, 0, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
    }

    func testASCIIKeyboardMapping() {
        XCTAssertEqual(
            HIDInput.keyReports(for: "A"),
            [KeyboardReport(modifiers: .leftShift, keys: [.a]), .zero]
        )
        XCTAssertEqual(
            HIDInput.keyReports(for: "?"),
            [KeyboardReport(modifiers: .leftShift, keys: [.slash]), .zero]
        )
        XCTAssertTrue(HIDInput.keyReports(for: "中").isEmpty)
    }

    func testPointerClampMatchesHIDDescriptorRange() {
        XCTAssertEqual(HIDInput.clamp(999), 127)
        XCTAssertEqual(HIDInput.clamp(-999), -127)
        XCTAssertEqual(HIDInput.clamp(12.9), 12)
    }

    func testAllReportIdentifiersExistInDescriptor() {
        let bytes = Array(HIDProfile.reportMapData)
        var identifiers = Set<UInt8>()
        var index = 0
        while index < bytes.count {
            let prefix = bytes[index]
            if prefix == 0xFE {
                guard index + 2 < bytes.count else { break }
                index += 3 + Int(bytes[index + 1])
                continue
            }
            let sizeCode = Int(prefix & 0x03)
            let payloadSize = sizeCode == 3 ? 4 : sizeCode
            if prefix == 0x85, index + 1 < bytes.count {
                identifiers.insert(bytes[index + 1])
            }
            index += 1 + payloadSize
        }
        XCTAssertEqual(identifiers, Set(ReportID.allCases.map(\.rawValue)))
        XCTAssertEqual(HIDProfile.reportMapData.count, 239)
        XCTAssertEqual(Array(HIDProfile.reportMapData.prefix(6)), [0x05, 0x01, 0x09, 0x06, 0xA1, 0x01])
    }

    func testReportReferenceDescriptors() {
        XCTAssertEqual(ReportID.mouse.descriptor(.input), Data([1, 1]))
        XCTAssertEqual(ReportID.keyboard.descriptor(.input), Data([2, 1]))
        XCTAssertEqual(ReportID.keyboardLEDs.descriptor(.output), Data([3, 2]))
    }

    func testDirectInputToggleShortcutRequiresExactChord() {
        XCTAssertTrue(DirectInputMapping.isToggleShortcut(
            type: .keyDown,
            keyCode: 0x31,
            modifiers: GlobalShortcut.default.modifiers,
            isRepeat: false,
            shortcut: .default
        ))
        XCTAssertFalse(DirectInputMapping.isToggleShortcut(
            type: .keyDown,
            keyCode: 0x31,
            modifiers: GlobalShortcut.carbonModifiers(from: [.control]),
            isRepeat: false,
            shortcut: .default
        ))
        XCTAssertFalse(DirectInputMapping.isToggleShortcut(
            type: .keyUp,
            keyCode: 0x31,
            modifiers: GlobalShortcut.default.modifiers,
            isRepeat: false,
            shortcut: .default
        ))
    }

    func testCustomGlobalShortcutMatchesItsOwnKeyAndModifiers() {
        let shortcut = GlobalShortcut(
            keyCode: 0x28,
            modifiers: GlobalShortcut.carbonModifiers(from: [.control, .shift]),
            keyLabel: "K"
        )
        XCTAssertEqual(shortcut.displayText, "⌃⇧K")
        XCTAssertTrue(DirectInputMapping.isToggleShortcut(
            type: .keyDown,
            keyCode: 0x28,
            modifiers: shortcut.modifiers,
            isRepeat: false,
            shortcut: shortcut
        ))
        XCTAssertFalse(DirectInputMapping.isToggleShortcut(
            type: .keyDown,
            keyCode: 0x28,
            modifiers: shortcut.modifiers,
            isRepeat: true,
            shortcut: shortcut
        ))
    }

    func testGlobalShortcutPersistsAcrossControllerLaunches() {
        let suiteName = "MacPhoneInputTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let shortcut = GlobalShortcut(
            keyCode: 0x28,
            modifiers: GlobalShortcut.carbonModifiers(from: [.control, .shift]),
            keyLabel: "K"
        )

        shortcut.save(to: defaults)

        XCTAssertEqual(GlobalShortcut.load(from: defaults), shortcut)
    }

    func testSystemShortcutConflictDetectionOnlyUsesEnabledExactMatches() {
        let shortcut = GlobalShortcut(
            keyCode: 49,
            modifiers: GlobalShortcut.carbonModifiers(from: [.command, .option]),
            keyLabel: "Space"
        )
        let matching: [String: Any] = [
            "65": [
                "enabled": NSNumber(value: true),
                "value": ["parameters": [
                    NSNumber(value: 65535),
                    NSNumber(value: 49),
                    NSNumber(value: shortcut.cocoaModifierRawValue)
                ]]
            ]
        ]
        XCTAssertTrue(SystemShortcutConflictDetector.conflicts(with: shortcut, entries: matching))

        let disabled: [String: Any] = [
            "65": [
                "enabled": NSNumber(value: false),
                "value": ["parameters": [
                    NSNumber(value: 65535),
                    NSNumber(value: 49),
                    NSNumber(value: shortcut.cocoaModifierRawValue)
                ]]
            ]
        ]
        XCTAssertFalse(SystemShortcutConflictDetector.conflicts(with: shortcut, entries: disabled))
    }

    func testKeyboardOnlyCaptureLeavesAllPointerEventsOnMac() {
        let keyboardOnly = DirectInputMapping.capturedEventMask(trackpadEnabled: false)
        let keyboardAndTrackpad = DirectInputMapping.capturedEventMask(trackpadEnabled: true)

        XCTAssertTrue(mask(keyboardOnly, contains: .keyDown))
        XCTAssertFalse(mask(keyboardOnly, contains: .mouseMoved))
        XCTAssertFalse(mask(keyboardOnly, contains: .leftMouseDown))
        XCTAssertFalse(mask(keyboardOnly, contains: .scrollWheel))
        XCTAssertEqual(keyboardAndTrackpad, CGEventMask.max)
        XCTAssertTrue(mask(keyboardAndTrackpad, contains: .mouseMoved))
        XCTAssertTrue(mask(keyboardAndTrackpad, contains: .leftMouseDown))
        XCTAssertTrue(mask(keyboardAndTrackpad, contains: .scrollWheel))
        XCTAssertTrue(mask(keyboardAndTrackpad, containsRawValue: NSEvent.EventType.gesture.rawValue))
        XCTAssertTrue(mask(keyboardAndTrackpad, containsRawValue: NSEvent.EventType.magnify.rawValue))
        XCTAssertTrue(mask(keyboardAndTrackpad, containsRawValue: NSEvent.EventType.swipe.rawValue))
        XCTAssertTrue(mask(keyboardAndTrackpad, containsRawValue: NSEvent.EventType.rotate.rawValue))
        XCTAssertTrue(mask(keyboardAndTrackpad, containsRawValue: NSEvent.EventType.smartMagnify.rawValue))
    }

    func testTrackpadScrollIsReducedAndReversedForIOS() {
        var filter = DirectInputScrollFilter()
        XCTAssertNil(filter.wheel(rawDelta: 4, pointDelta: 4, isContinuous: true, momentumPhase: 0))
        XCTAssertNil(filter.wheel(rawDelta: 4, pointDelta: 4, isContinuous: true, momentumPhase: 0))
        XCTAssertEqual(filter.wheel(rawDelta: 4, pointDelta: 4, isContinuous: true, momentumPhase: 0), -1)
        XCTAssertEqual(filter.wheel(rawDelta: -12, pointDelta: -12, isContinuous: true, momentumPhase: 0), 1)
    }

    func testMacMomentumTailIsNotForwardedToIOS() {
        var filter = DirectInputScrollFilter()
        XCTAssertNil(filter.wheel(rawDelta: 20, pointDelta: 20, isContinuous: true, momentumPhase: 2))
        XCTAssertEqual(filter.wheel(rawDelta: 1, pointDelta: 0, isContinuous: false, momentumPhase: 0), -1)
        XCTAssertEqual(filter.wheel(rawDelta: -999, pointDelta: 0, isContinuous: false, momentumPhase: 0), 3)
    }

    func testGAPAppearanceIdentifiesKeyboardFirstCompositeHIDDevice() {
        XCTAssertEqual(HIDProfile.keyboardAppearanceValue, Data([0xC1, 0x03]))
        XCTAssertEqual(HIDProfile.genericAccessService.uuidString, "00001800-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(HIDProfile.deviceName.uuidString, "00002A00-0000-1000-8000-00805F9B34FB")
    }

    func testSolitaryGlobeKeyMapsToInputSourceSwitch() {
        var globe = DirectInputGlobeKey()
        XCTAssertFalse(globe.flagsChanged(keyCode: 0x3F, functionDown: true))
        XCTAssertTrue(globe.flagsChanged(keyCode: 0x3F, functionDown: false))

        XCTAssertFalse(globe.flagsChanged(keyCode: 0x3F, functionDown: true))
        globe.noteOtherKey()
        XCTAssertFalse(globe.flagsChanged(keyCode: 0x3F, functionDown: false))
    }

    func testEjectConsumerReportUsesStandardHIDUsage() {
        XCTAssertEqual(Array(ConsumerReport(key: .eject).data), [0xB8, 0x00, 0x00, 0x00, 0x00])
    }

    func testDuplicateReportUUIDSubscriptionsAreTrackedIndependently() {
        let centralID = UUID()
        let firstReport = CBMutableCharacteristic(
            type: HIDProfile.report,
            properties: .notify,
            value: nil,
            permissions: .readable
        )
        let secondReport = CBMutableCharacteristic(
            type: HIDProfile.report,
            properties: .notify,
            value: nil,
            permissions: .readable
        )
        var book = HIDSubscriptionBook()

        XCTAssertEqual(
            book.subscribe(centralID: centralID, characteristic: firstReport),
            Set([HIDProfile.report])
        )
        XCTAssertEqual(
            book.subscribe(centralID: centralID, characteristic: secondReport),
            Set([HIDProfile.report])
        )
        XCTAssertEqual(
            book.unsubscribe(centralID: centralID, characteristic: firstReport),
            Set([HIDProfile.report])
        )
        XCTAssertTrue(book.unsubscribe(centralID: centralID, characteristic: secondReport).isEmpty)
    }


    private func mask(_ mask: CGEventMask, contains type: CGEventType) -> Bool {
        mask & (CGEventMask(1) << CGEventMask(type.rawValue)) != 0
    }

    private func mask(_ mask: CGEventMask, containsRawValue rawValue: UInt) -> Bool {
        mask & (CGEventMask(1) << CGEventMask(rawValue)) != 0
    }
}

final class SoftwareKeyboardStateMachineTests: XCTestCase {
    func testInitialConnectionSchedulesRestoreOnlyOnce() {
        var state = SoftwareKeyboardStateMachine()

        XCTAssertEqual(
            state.connectionChanged(true),
            [.cancelConnectionReset, .scheduleRestore]
        )
        XCTAssertTrue(state.connectionChanged(true).isEmpty)
        XCTAssertTrue(state.isConnected)
        XCTAssertFalse(state.isCapturing)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
    }

    func testRestoreTimerShowsKeyboardOnlyOnce() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)

        XCTAssertEqual(state.restoreDelayExpired(), [.toggleKeyboard])
        XCTAssertTrue(state.restoreDelayExpired().isEmpty)
        XCTAssertTrue(state.isSoftwareKeyboardShown)
    }

    func testDisconnectBeforeInitialRestoreCancelsAndReconnectReschedules() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)

        XCTAssertEqual(
            state.connectionChanged(false),
            [.cancelRestore, .scheduleConnectionReset]
        )
        XCTAssertTrue(state.restoreDelayExpired().isEmpty)
        XCTAssertEqual(
            state.connectionChanged(true),
            [.cancelConnectionReset, .scheduleRestore]
        )
        XCTAssertEqual(state.restoreDelayExpired(), [.toggleKeyboard])
    }

    func testBriefReconnectDoesNotToggleAlreadyVisibleKeyboard() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)
        _ = state.restoreDelayExpired()

        XCTAssertEqual(
            state.connectionChanged(false),
            [.cancelRestore, .scheduleConnectionReset]
        )
        XCTAssertEqual(state.connectionChanged(true), [.cancelConnectionReset])
        XCTAssertTrue(state.restoreDelayExpired().isEmpty)
        XCTAssertTrue(state.isSoftwareKeyboardShown)
    }

    func testSustainedDisconnectForgetsVisibilityAndReconnectRestores() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)
        _ = state.restoreDelayExpired()
        _ = state.connectionChanged(false)

        XCTAssertTrue(state.connectionResetDelayExpired().isEmpty)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
        XCTAssertEqual(
            state.connectionChanged(true),
            [.cancelConnectionReset, .scheduleRestore]
        )
        XCTAssertEqual(state.restoreDelayExpired(), [.toggleKeyboard])
        XCTAssertTrue(state.isSoftwareKeyboardShown)
    }

    func testCaptureBeforeRestoreCancelsPendingRestore() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)

        XCTAssertEqual(state.captureStarted(), [.cancelRestore])
        XCTAssertTrue(state.restoreDelayExpired().isEmpty)
        XCTAssertTrue(state.isCapturing)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
        XCTAssertEqual(state.captureStopped(), [.toggleKeyboard])
        XCTAssertTrue(state.isSoftwareKeyboardShown)
    }

    func testCaptureHidesVisibleKeyboardAndStopRestoresIt() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)
        _ = state.restoreDelayExpired()

        XCTAssertEqual(state.captureStarted(), [.cancelRestore, .toggleKeyboard])
        XCTAssertTrue(state.isCapturing)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
        XCTAssertEqual(state.captureStopped(), [.toggleKeyboard])
        XCTAssertFalse(state.isCapturing)
        XCTAssertTrue(state.isSoftwareKeyboardShown)
    }

    func testDisconnectDuringCaptureDoesNotToggleWhenCaptureStops() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)
        _ = state.restoreDelayExpired()
        _ = state.captureStarted()

        XCTAssertEqual(
            state.connectionChanged(false),
            [.cancelRestore, .scheduleConnectionReset]
        )
        _ = state.connectionResetDelayExpired()
        XCTAssertTrue(state.captureStopped().isEmpty)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
        XCTAssertEqual(
            state.connectionChanged(true),
            [.cancelConnectionReset, .scheduleRestore]
        )
    }

    func testReconnectWhileCapturingNeverSchedulesRestore() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)
        _ = state.restoreDelayExpired()
        _ = state.captureStarted()
        _ = state.connectionChanged(false)

        XCTAssertEqual(state.connectionChanged(true), [.cancelConnectionReset])
        XCTAssertTrue(state.restoreDelayExpired().isEmpty)
        XCTAssertTrue(state.isCapturing)
        XCTAssertFalse(state.isSoftwareKeyboardShown)
    }

    func testDuplicateCaptureEventsAreIdempotent() {
        var state = SoftwareKeyboardStateMachine()
        _ = state.connectionChanged(true)

        XCTAssertEqual(state.captureStarted(), [.cancelRestore])
        XCTAssertTrue(state.captureStarted().isEmpty)
        XCTAssertEqual(state.captureStopped(), [.toggleKeyboard])
        XCTAssertTrue(state.captureStopped().isEmpty)
    }
}
