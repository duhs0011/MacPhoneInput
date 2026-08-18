# MacPhone Input（本机版）

这是一个面向本机 Mac 和 iPhone 15 Pro 的蓝牙键盘/触控板工具。Mac 通过标准 BLE HID 协议模拟蓝牙键盘和鼠标；iPhone 不需要安装 App，也不需要与 Mac 登录相同的 iCloud 账户。

## 使用

1. 打开 `MacPhoneInput.app`，保持它在菜单栏运行。
2. 首次使用时，在 iPhone 的“设置 → 辅助功能 → 触控 → 辅助触控 → 设备 → 蓝牙设备”中连接 `MacPhoneInput` 并确认配对。
3. 如果选择“仅键盘”，配对完成后即可关闭 iPhone 的辅助触控；如果选择“键盘 + 触控板”，则保持辅助触控开启。
4. 在 Mac 的“系统设置 → 隐私与安全性 → 辅助功能”中允许 `MacPhoneInput`。
5. 按默认快捷键 `Control + Option + Space`，在控制 Mac 和控制 iPhone 之间切换。也可以在 App 中自定义快捷键；如果与已启用的 macOS 系统快捷键冲突，App 会提示并保留原快捷键。

切换输入去向不会主动断开蓝牙。只要应用保持运行，日常使用无需重新配对。

## 开发和测试

工程文件是 `MacPhoneInput.xcodeproj`，目标系统为 macOS 15。执行测试：

```sh
xcodebuild test -project MacPhoneInput.xcodeproj -scheme MacPhoneInput -destination 'platform=macOS,arch=arm64'
```

## 开源许可

本项目基于 [darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote)，沿用 GNU Affero General Public License v3.0。完整条款见 `LICENSE`。
