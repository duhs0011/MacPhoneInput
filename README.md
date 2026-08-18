# MacPhone Input

把 Mac 自带键盘和触控板变成 iPhone 的蓝牙外接键盘与鼠标。

MacPhone Input 不镜像 iPhone 屏幕，不需要两台设备登录同一个 Apple 账号，也不需要在 iPhone 安装配套 App。输入数据只通过蓝牙 BLE HID 发送。

> 当前是朋友测试版，已在 MacBook Air M4（macOS 15.7.5）与 iPhone 15 Pro 上完成实机验证。其他设备和系统版本仍需要更多测试。

## 下载

从 [GitHub Releases](https://github.com/duhs0011/MacPhoneInput/releases/latest) 下载最新 DMG。

当前测试包尚未使用 Developer ID 公证。首次打开时，可能需要按住 Control 点击 App 选择“打开”，或前往“系统设置 → 隐私与安全性”选择“仍要打开”。

## 功能

- 使用 Mac 键盘在 iPhone 上输入文字
- 可选用 Mac 触控板移动、点击、拖动和双指滚动
- 一键在控制 Mac 与控制 iPhone 之间切换，蓝牙连接保持不断开
- 自定义全局快捷键，并检查 macOS 系统快捷键冲突
- Fn/地球键或 Control + Space 切换 iPhone 输入法
- 支持数字键选择中文输入候选项
- 连接外接键盘时隐藏 iPhone 屏幕键盘，停止控制后恢复
- 控制 iPhone 时拦截对应的 Mac 键盘和触控板事件

默认切换快捷键是 `Control + Option + Space`。

## 两种控制方式

### 仅键盘

键盘控制 iPhone，触控板继续控制 Mac。完成首次配对后，iPhone 可以关闭“辅助触控”。

### 键盘 + 触控板

键盘和触控板一起控制 iPhone。支持移动指针、单击、按住拖动和双指纵向滚动。

iPhone 必须打开“设置 → 辅助功能 → 触控 → 辅助触控”。受 iPhone 系统限制，目前不支持捏合缩放及三指、四指系统手势。

## 首次使用

1. 打开 DMG，把 `MacPhoneInput.app` 拖进“应用程序”。
2. 启动 App，在 Mac 的“系统设置 → 隐私与安全性 → 辅助功能”中允许 MacPhone Input。
3. 在 iPhone 打开“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”。
4. 选择 `MacPhoneInput` 并完成配对。
5. 回到 App 选择“仅键盘”或“键盘 + 触控板”。
6. 使用默认或自定义快捷键切换输入去向。

配对通常只需完成一次。只要 App 保持运行，日常切换不需要重新连接蓝牙。

## 系统要求

- macOS 15 或更高版本
- 支持 BLE 的 Mac
- iPhone 15 Pro 已验证
- 如需触控板控制，iPhone 必须开启辅助触控

## 开发与测试

工程包含已提交的 `MacPhoneInput.xcodeproj`，可直接使用 Xcode 打开。也可以执行：

```sh
./build.sh
```

单独运行测试：

```sh
xcodebuild test \
  -project MacPhoneInput.xcodeproj \
  -scheme MacPhoneInput \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

## 隐私

App 不包含账号系统、网络服务器或统计 SDK。键盘和触控板事件通过本地蓝牙连接发送给已配对的 iPhone。

## 开源许可

本项目基于 [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote) 修改，遵循 [GNU Affero General Public License v3.0](LICENSE)。分发修改版或基于本项目提供网络服务时，请遵守许可证规定并提供对应源码。
