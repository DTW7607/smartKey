# 贡献指南

欢迎帮助老款智键在更多 Mac 上继续使用。项目提供[中文 README](README.md) 与[英文 README](README.en.md)，程序目前仅提供中文界面，不提供英文版程序。英语及其他界面语言适配欢迎社区自行完成或提交 PR，也欢迎改进文档翻译。维护精力有限，反馈与合并可能需要等待。

## 反馈问题与兼容性

请提供 macOS 版本、Mac 型号与芯片、智键型号或外观说明、是否直连内置 3.5 mm 接口、当前音频输出设备，以及最短复现步骤。区分「检测不到插入」「HID 未连接」「按键无法识别」和「动作执行失败」，有助于定位问题。截图或日志请去除个人路径、脚本密钥等私人信息。

没有硬件也可以改进文档、翻译、动作模型和模拟测试。未实测的设备请标为未验证，不要仅凭编译成功宣称兼容。

## 本地开发

需要 macOS 26+ 和完整 Xcode 26+。在项目根目录运行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
./scripts/build-app.sh
```

若 Xcode 位于其他位置，请调整路径。受限开发环境若不允许 SwiftPM 创建嵌套沙箱，可使用 `swift test --disable-sandbox`；构建脚本的对应选项是 `SMARTKEY_SWIFT_DISABLE_SANDBOX=1`。普通本机环境不需要这些选项。

仅预览设置窗口：

```bash
.build/release-app/smartKey.app/Contents/MacOS/smartKey --settings-preview
```

预览模式使用独立临时配置，不启动 HID、音频管理或登录项；其中的测试按钮仍会执行选中的真实动作。

默认测试不操作真实音频路由或硬件。可选真实 HID 回归测试会短暂独占内置 Audio 线控；准备好智键并退出其他 smartKey 实例后，才运行：

```bash
SMARTKEY_HID_INTEGRATION=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --filter realHIDCanRestartThreeTimes
```

这只检查 HID 连续启停，不能替代实体单击、双击、长按、插拔和睡眠唤醒验收。

## 提交改动

- 让一次 PR 聚焦一个问题，说明触发条件、修改后的行为和实际验证结果。
- 涉及手势、设备或动作执行逻辑时，补充能覆盖行为变化的测试；涉及界面时附上截图。
- 新动作类型可参考 [动作扩展说明](docs/action-development.md)，避免把执行逻辑耦合到提示气泡。
- 不提交 `.build`、应用产物、个人配置、签名证书或令牌。
- 提交的贡献应当是你有权提交、可以按本项目 MIT 许可证分发的内容。
