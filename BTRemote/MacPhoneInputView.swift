#if os(macOS)
import AppKit
import CoreBluetooth
import SwiftUI

struct MacPhoneInputView: View {
    @EnvironmentObject private var lowEnergy: HIDPeripheral
    @EnvironmentObject private var directInput: DirectInputController
    @Environment(\.hid) private var hid
    @State private var isShowingShortcutRecorder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            statusCard
            controlCard
            pairingGuide
            Text("本工具基于 darwin-bt-remote（AGPL-3.0）制作，仅在本机运行。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(26)
        .frame(minWidth: 500, minHeight: 760, alignment: .topLeading)
        .onAppear(perform: refreshController)
        .onChange(of: hid.isConnected) { refreshController() }
        .onChange(of: hid.isActive) { refreshController() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshController()
        }
        .sheet(isPresented: $isShowingShortcutRecorder) {
            GlobalShortcutRecorderSheet(directInput: directInput)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("MacPhone Input")
                    .font(.title2.bold())
                Text("用 Mac 键盘和可选触控板控制旁边的 iPhone")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusCard: some View {
        GroupBox("连接状态") {
            VStack(alignment: .leading, spacing: 10) {
                statusRow("Mac 蓝牙", value: bluetoothText, good: lowEnergy.state == .poweredOn)
                statusRow("对外广播", value: lowEnergy.isAdvertising ? "MacPhoneInput 可供 iPhone 发现" : "正在准备", good: lowEnergy.isAdvertising)
                statusRow("iPhone", value: hid.isConnected ? "已连接" : "未连接", good: hid.isConnected)
                statusRow(
                    "Mac 辅助功能",
                    value: directInput.hasAccessibilityPermission ? "已允许" : "等待授权",
                    good: directInput.hasAccessibilityPermission
                )
                if let error = lowEnergy.lastError ?? directInput.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controlCard: some View {
        GroupBox("快速切换") {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: directInput.toggle) {
                    Label(
                        primaryControlTitle,
                        systemImage: primaryControlIcon
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if directInput.needsAccessibility && !directInput.hasAccessibilityPermission {
                    accessibilityPermissionGuide
                }

                controlModePicker

                HStack {
                    Text("全局快捷键")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(directInput.globalShortcut.displayText)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Button("修改…") {
                        isShowingShortcutRecorder = true
                    }
                    .controlSize(.small)
                    .disabled(directInput.isCapturing)
                }
                Text("控制 iPhone 时：按地球/Fn 或 ⌃Space 切换输入法。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(captureStatusText)
                    .font(.callout)
                    .foregroundStyle(directInput.isCapturing ? .orange : .secondary)
            }
            .padding(.vertical, 6)
        }
    }

    private var pairingGuide: some View {
        GroupBox("首次使用（只做一次）") {
            VStack(alignment: .leading, spacing: 9) {
                guideRow(1, "在 iPhone 打开“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”，点选 MacPhoneInput。")
                guideRow(2, pairingStepTwo)
                guideRow(3, accessibilityGuideText)
                Text("不需要登录同一个 iCloud；首次蓝牙配对后，日常切换无需重新连接。")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
                    .padding(.top, 3)
            }
            .padding(.vertical, 6)
        }
    }

    private var bluetoothText: String {
        switch lowEnergy.state {
        case .poweredOn: "已开启"
        case .poweredOff: "已关闭"
        case .unauthorized: "未授权"
        case .unsupported: "不支持"
        case .resetting: "正在重置"
        default: "正在检测"
        }
    }

    private var trackpadBinding: Binding<Bool> {
        Binding(
            get: { directInput.controlsTrackpad },
            set: { directInput.setTrackpadControlEnabled($0) }
        )
    }

    private var controlModePicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("控制方式")
                .font(.callout.weight(.semibold))
            HStack(spacing: 10) {
                controlModeOption(
                    title: "仅键盘",
                    detail: "键盘 → iPhone\n触控板 → Mac",
                    trackpadEnabled: false
                )
                controlModeOption(
                    title: "键盘 + 触控板",
                    detail: "键盘、触控板 → iPhone",
                    trackpadEnabled: true
                )
            }

            Text(trackpadHelpText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if directInput.isCapturing {
                Label("切回 Mac 后可更改控制方式", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func controlModeOption(
        title: String,
        detail: String,
        trackpadEnabled: Bool
    ) -> some View {
        let isSelected = directInput.controlsTrackpad == trackpadEnabled
        return Button {
            directInput.setTrackpadControlEnabled(trackpadEnabled)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 4)
                        if isSelected {
                            Text("已选择")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(isSelected ? Color.accentColor.opacity(0.09) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.28),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(directInput.isCapturing)
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint(detail.replacingOccurrences(of: "\n", with: "，"))
    }

    private var trackpadHelpText: String {
        directInput.controlsTrackpad
            ? "可在 iPhone 上移动光标、点击、按住拖动和双指上下滚动。不支持捏合缩放或三/四指手势；切换后触控板不再操作 Mac。需要开启“辅助触控”。"
            : "只有键盘切换到 iPhone；触控板继续操作 Mac。首次配对完成后，iPhone 无需开启“辅助触控”。"
    }

    private var captureStatusText: String {
        if directInput.isCapturing {
            return directInput.controlsTrackpad
                ? "当前：键盘 + 触控板 → iPhone"
                : "当前：键盘正在控制 iPhone，触控板仍控制 Mac"
        }
        if !hid.isConnected {
            return "尚未连接 iPhone；连接后可用快捷键切换输入去向。"
        }
        return "蓝牙保持连接；快捷键只切换输入去向。"
    }

    private var primaryControlTitle: String {
        if directInput.isCapturing { return "切回 Mac" }
        return hid.isConnected ? "开始控制 iPhone" : "连接 iPhone…"
    }

    private var primaryControlIcon: String {
        if directInput.isCapturing { return "laptopcomputer" }
        return hid.isConnected ? "iphone" : "cable.connector"
    }

    private var pairingStepTwo: String {
        directInput.controlsTrackpad
            ? "保持“辅助触控”开启，并关闭“显示屏幕键盘”和“始终显示菜单”：保留指针，同时隐藏软键盘和悬浮圆圈。"
            : "配对完成后可以关闭“辅助触控”；使用时只有键盘切换到 iPhone，触控板留在 Mac。"
    }

    private var accessibilityGuideText: String {
        directInput.hasAccessibilityPermission
            ? "Mac 已允许本工具使用“辅助功能”，之后用 \(directInput.globalShortcut.displayText) 随时切换。"
            : "点“开始控制 iPhone”，在 macOS 授权提示中选择“打开系统设置”，再打开 MacPhone Input 的开关。"
    }

    private var accessibilityPermissionGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要辅助功能权限", systemImage: "hand.raised.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text("macOS 已收到授权请求。请在系统提示中点“打开系统设置”；MacPhone Input 会自动出现在列表中。如果没有看到系统提示，可使用下方按钮。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新请求系统授权") {
                    AccessibilityPermission.request()
                }
                Button("打开辅助功能设置") {
                    AccessibilityPermission.openSettings()
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35))
        }
    }

    private func statusRow(_ title: String, value: String, good: Bool) -> some View {
        HStack {
            Circle()
                .fill(good ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func guideRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(String(number))
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func refreshController() {
        directInput.refreshAccessibilityPermission()
        directInput.configure(hid)
    }
}

struct MacPhoneInputMenuView: View {
    @EnvironmentObject private var lowEnergy: HIDPeripheral
    @EnvironmentObject private var directInput: DirectInputController
    @Environment(\.hid) private var hid
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(hid.isConnected ? "iPhone 已连接" : "等待 iPhone 连接")
        Button(
            directInput.isCapturing
                ? "切回 Mac  \(directInput.globalShortcut.displayText)"
                : hid.isConnected
                    ? "控制 iPhone  \(directInput.globalShortcut.displayText)"
                    : "连接 iPhone…  \(directInput.globalShortcut.displayText)"
        ) {
            directInput.toggle()
        }
        Picker("控制方式", selection: trackpadBinding) {
            Text("仅键盘").tag(false)
            Text("键盘 + 触控板").tag(true)
        }
            .disabled(directInput.isCapturing)
        if directInput.isCapturing {
            Text("切回 Mac 后可更改控制方式")
        }
        Divider()
        Button("打开 MacPhone Input") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("退出") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
        EmptyView()
            .onAppear(perform: refreshController)
            .onChange(of: hid.isConnected) { refreshController() }
            .onChange(of: hid.isActive) { refreshController() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshController()
            }
    }

    private func refreshController() {
        directInput.refreshAccessibilityPermission()
        directInput.configure(hid)
    }

    private var trackpadBinding: Binding<Bool> {
        Binding(
            get: { directInput.controlsTrackpad },
            set: { directInput.setTrackpadControlEnabled($0) }
        )
    }
}

private struct GlobalShortcutRecorderSheet: View {
    @ObservedObject var directInput: DirectInputController
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("设置全局快捷键")
                    .font(.title3.bold())
                Text("直接按下新的快捷键；按 Esc 取消。")
                    .foregroundStyle(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.08))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        errorMessage == nil ? Color.accentColor.opacity(0.55) : Color.red.opacity(0.7),
                        lineWidth: 2
                    )
                VStack(spacing: 7) {
                    Text(errorMessage == nil ? "等待输入…" : "快捷键不可用")
                        .font(.headline)
                        .foregroundStyle(errorMessage == nil ? Color.primary : Color.red)
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    } else {
                        Text("至少两个修饰键，且包含 ⌘ 或 ⌃")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                GlobalShortcutCaptureView(
                    onShortcut: saveShortcut,
                    onError: { errorMessage = $0 },
                    onCancel: { dismiss() }
                )
            }
            .frame(height: 100)

            Text("会检查已启用的 macOS 系统快捷键和其他应用的独占全局快捷键；无法检测只在某个应用前台生效的菜单快捷键。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("恢复默认") {
                    saveShortcut(.default)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { directInput.beginGlobalShortcutRecording() }
        .onDisappear { directInput.endGlobalShortcutRecording() }
    }

    private func saveShortcut(_ shortcut: GlobalShortcut) {
        if let error = directInput.setGlobalShortcut(shortcut) {
            errorMessage = error
        } else {
            dismiss()
        }
    }
}

private struct GlobalShortcutCaptureView: NSViewRepresentable {
    let onShortcut: (GlobalShortcut) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        configure(nsView)
        if let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    private func configure(_ view: ShortcutCaptureNSView) {
        view.onShortcut = onShortcut
        view.onError = onError
        view.onCancel = onCancel
    }
}

private final class ShortcutCaptureNSView: NSView {
    var onShortcut: ((GlobalShortcut) -> Void)?
    var onError: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let relevantFlags = event.modifierFlags.intersection([
            .command, .control, .option, .shift
        ])
        if event.keyCode == 0x35, relevantFlags.isEmpty {
            onCancel?()
            return
        }

        switch GlobalShortcut.capture(from: event) {
        case let .success(shortcut):
            onShortcut?(shortcut)
        case let .failure(error):
            onError?(error.localizedDescription)
        }
    }
}
#endif
