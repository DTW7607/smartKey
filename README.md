# smartKey demo

最小验证：内置 3.5mm 线控的**播放/暂停**，以及插孔插拔。只在终端打印。

- 插入 / 拔出 → `插入` / `拔出`（只认 UID `BuiltInHeadphoneOutputDevice`，即内置 3.5mm）
- 中央键 → `播放键 × N`
- 只匹配 `Transport=Audio` 的 HID Consumer Control
- listen-only，不 seize

```bash
swift run
```

Ctrl+C 退出。
