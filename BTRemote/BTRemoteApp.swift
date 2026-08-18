import SwiftUI

@main
struct BTRemoteApp: App {
    @StateObject private var lowEnergy = HIDPeripheral()
    @StateObject private var directInput = DirectInputController()

    init() {
        UserDefaults.standard.register(defaults: [
            AppSettings.useServiceChangedKey: true,
            AppSettings.controlTrackpadKey: AppSettings.defaultControlTrackpad,
            AppSettings.globalShortcutKeyCodeKey: Int(GlobalShortcut.default.keyCode),
            AppSettings.globalShortcutModifiersKey: Int(GlobalShortcut.default.modifiers),
            AppSettings.globalShortcutKeyLabelKey: GlobalShortcut.default.keyLabel
        ])
    }

    private var hid: HIDInput {
        HIDInput.make(lowEnergy: lowEnergy)
    }

    var body: some Scene {
        WindowGroup("MacPhone Input", id: "main") {
            MacPhoneInputView()
                .environmentObject(lowEnergy)
                .environmentObject(directInput)
                .environment(\.hid, hid)
                .onAppear { lowEnergy.start() }
        }
        .defaultSize(width: 540, height: 780)

        MenuBarExtra {
            MacPhoneInputMenuView()
                .environmentObject(lowEnergy)
                .environmentObject(directInput)
                .environment(\.hid, hid)
                .onAppear { lowEnergy.start() }
        } label: {
            if directInput.isCapturing {
                Label("iPhone", systemImage: "iphone.radiowaves.left.and.right")
            } else {
                Image(systemName: "keyboard")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
