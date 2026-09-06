# smartKey

内置 3.5mm 智键的 macOS 菜单栏程序：完成设备配置后独占线控，点击 / 长按弹出玻璃气泡，按下时右下角出现按压缩罩。需要 macOS 26。

开发运行：

```bash
swift run smartKey
```

安装到 `/Applications`（release 打包、本机 ad-hoc 签名、注册登录项并启动）：

```bash
./scripts/install-app.sh
```

布局与手势配置在 `~/Library/Application Support/智键/smartKey.conf`。首次启动若该文件不存在，会把当前出厂配置写进去；之后改完保存即热更新，不必重启。仓库根目录的 `smartKey.conf` 只作出厂模板。

- 启动检查已插入的内置 3.5mm 设备，同时监听后续插拔。检测到插入时，右下角先播放黑色遮罩动画，再延迟显示设备类型选择气泡；时长见 `insertionMaskDurationMs` / `insertionPopupDelayMs`。
- 每次启动检测到设备或重新插入设备都弹窗，不提供默认识别或隐藏设置。焦点落在上次确认的选项上（首次默认为智键，跨启动持久化），右上角仅显示倒计时数字；超时则按当前焦点项继续。超时见 `deviceChoiceTimeoutMs`。
- 选择「音频设备」时，如当前默认输出不是 3.5mm 耳机孔，则切换到该端口并读回确认；不独占、不响应智键线控。切换失败可重试。
- 配置音频输出前先排除 3.5mm 设备：仅剩一个可用输出时，跳过选择页并自动切换，读回确认后进入独占；多个输出时显示选择页，无可用输出时提示连接设备。自动切换失败或超时会返回选择页，等待用户重试。
- 音频选择采用系统原生「名称 / 类型」双列表格，设备列表随连接状态更新。列表不显示耳机端口，需选择内建扬声器、蓝牙、USB 等其他输出。点击「使用此设备」调用后端 `SmartKeyService.setDefaultOutput(uid:)`，读回确认后才调用 `setRemoteEnabled(true)`。这里使用现有 Swift 公共接口，无需额外网络端口；只修改默认音频输出，不修改输入设备。
- 切换失败、没有其他音频设备时保留音频选择页。HID 连接错误使用独立提示，区分设备占用、访问被拒绝和等待设备；等待超过 5 秒显示提示，但继续发现设备，迟到的设备仍可自动恢复。支持重试和取消，取消仅停用智键，不切回耳机孔，也不回滚已成功的音频切换。
- 配置成功且 HID 独占成功后才接收按键。独占对象为 `Transport=Audio` Consumer Control，键盘 / 蓝牙 / USB 媒体键不会误触发。
- 拔出设备立即释放独占、关闭提示并取消倒计时；再次插入重新选择。工作期间若默认输出不可用或切回耳机端口，会暂停智键并重新配置音频输出，同样遵循单输出自动切换规则。
- 菜单栏保留状态、「重新配置设备…」和「退出」。安装到 `/Applications` 后多一项「登录时打开」，首次启动会注册登录项（系统设置 → 通用 → 登录项）。开发运行不显示该项。手动重新配置不启动自动选择倒计时。
- 所有提示和遮罩优先显示在可用的内置屏幕，即使外接屏幕被设为主显示器。内置屏幕不可用时退回 `CGMainDisplayID()` 对应的主显示器，不跟随鼠标或前台窗口。
- 配置窗口使用固定的系统背景色，与原生列表和按钮保持一致，不依赖切换桌面时会更换合成策略的模糊背板。
- 不推断“拔掉智键后”的系统输出。当前或本次运行中记录到的非耳机孔输出仅用于预选，多个输出时，用户确认前不切换。
- 默认只认点击和长按。气泡分别显示「点击事件」「长按事件」；气泡彻底消失前忽略新手势。
- 黑色遮罩只跟按下 / 松开，与气泡是否在场无关。
- 手势、插入动画、选择超时和配置窗口尺寸见用户 `smartKey.conf`。用户上次选择的设备类型不写入 conf，由程序单独持久化。
- 卸载：取消「登录时打开」，再把 `/Applications/智键.app` 移到废纸篓。

验证：`swift test` 覆盖选择倒计时、插入延迟、上次选择记忆、音频模式、切换确认、切换失败与超时、热拔插、设备消失及独占失败。默认测试使用模拟后端，不修改真实音频路由或独占硬件；在 macOS 26 上会额外输出 `/tmp/smartKey-device-type.png`、`/tmp/smartKey-audio-output.png`、`/tmp/smartKey-audio-output-dark.png` 和 `/tmp/smartKey-audio-error.png` 用于布局检查。实际插拔、音频路由及按键仍需设备验收。

如果系统默认选中 Command Line Tools 且找不到 `Testing` 模块，可使用已安装的完整 Xcode：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

HID 回归测试（先退出正在运行的智键，包括 `/Applications` 那份；会短暂独占内置 Audio 线控三次，不切换音频路由）：

```bash
SMARTKEY_HID_INTEGRATION=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter realHIDCanRestartThreeTimes
```

本机对照验证：旧实现第一次启动为 `seized`，第二、三次为 `waiting`；新实现三次均为 `seized`，停止后均为 `idle`。修复采用每次新建 HID 管理器、`independentDevices` 下单独独占设备、初始枚举补取及 common run-loop 模式；按键物理动作仍需单独验证。
