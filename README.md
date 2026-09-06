# smartKey

内置 3.5mm 线控后端库：插孔插拔、系统音频设备列表/默认切换、线控 HID 独占与手势。CLI 只作示例。

## 库

```swift
import SmartKey

let service = SmartKeyService()
service.onJackChange = { connected in /* 插入 / 拔出 */ }
service.onAudioChange = { snapshot in /* 设备列表与默认 I/O */ }
service.onButton = { phase in /* 按下 / 抬起，做动画 */ }
service.onGesture = { event in /* 单击 / 双击 / 长按，做动作 */ }
service.start()
service.setRemoteEnabled(true)

try service.setDefaultOutput(uid: "BuiltInSpeakerDevice")
try service.setDefaultInput(uid: "BuiltInMicrophoneDevice")
```

- 只认内置模拟插孔（输出 `BuiltInHeadphoneOutputDevice`，输入 `BuiltInHeadphoneInputDevice` / `BuiltInHeadsetInputDevice`，transport `'bltn'`）。蓝牙 / USB / USB-C 不会当成插孔，也不会被 seize。
- `setDefault*` 由库写 Core Audio HAL。插上后不自动切走默认设备；`isAnalogJack` 供 GUI 提示勿把插孔当媒体 I/O。
- 线控 HID：`Transport=Audio` Consumer Control，整机 seize。失败不共享监听，避免按键漏到系统。音量 ± 被挡住，不进系统 OSD，也不回调。
- 手势超时与事件开关见 `SmartKeyConfiguration`（`doubleClickMs` / `longPressMs` / `enabledEvents`）。
- 回调在主线程。HID 已在 main 时同步派发。建议从 main 调 `start()` / `stop()` / `setRemoteEnabled` / `setDefault*`。

## 测试 CLI

交互式覆盖全部公开接口。stdin 挂在 main，不挡住 HID。

```bash
swift run smartKeyDemo
```

从仓库根目录运行即可读到 `smartKey.conf`。启动后不自动 `start()`，可先 `status` 再手动开。

| 命令 | 接口 |
|---|---|
| `start` / `stop` | `start()` / `stop()` |
| `status` | `isRunning` / `isJackConnected` / `isRemoteEnabled` / `seizeStatus` / `isButtonPressed` / `configuration` / `audio` |
| `remote on\|off` | `setRemoteEnabled` |
| `audio` | `audio` 快照 |
| `out <序号\|uid>` / `in <序号\|uid>` | `setDefaultOutput` / `setDefaultInput` |
| `double <ms>` / `long <ms>` / `emit-jack on\|off` | `configuration` |
| `events …` | `enabledEvents` |
| 线控 / 插拔 / 音频变化 | `onButton` / `onGesture` / `onJackChange` / `onAudioChange` / `onSeizeStatusChange` |
