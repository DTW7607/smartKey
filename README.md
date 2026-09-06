# smartKey demo

最小验证：内置 3.5mm 线控的**播放/暂停**，以及插孔插拔。只在终端打印。

- 插入 / 拔出 → `插入` / `拔出`（只认 UID `BuiltInHeadphoneOutputDevice`）
- 中央键 → `单击 × N` / `双击 × N` / `长按 × N`（`smartKey.conf`，默认双击 600ms、长按 1300ms）
- 只匹配 `Transport=Audio` 的 HID Consumer Control（`AppleCS42L84Mikey`）
- `IOHIDDevice` **seize** 独占；失败则不启用按键（不做共享监听，避免泄漏到系统）
- seize 是整台线控 HID，音量 ± 也会被挡住，不会进系统 OSD

```bash
swift run
```

手势超时见仓库根目录 `smartKey.conf`（`doubleClickMs` / `longPressMs`）。从仓库根目录运行即可读到该文件。

Ctrl+C 退出。终端应出现 `[hid] 已独占 Headset`。若出现 `独占失败`，系统仍会收到按键，demo 不会计数。
