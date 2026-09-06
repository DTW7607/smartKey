# smartKey

独占内置 3.5mm 线控的 macOS 菜单栏程序：点击 / 长按弹出玻璃气泡，按下时右下角出现按压缩罩。需要 macOS 26。

```bash
swift run smartKey
```

从仓库根目录运行即可读到 `popup.conf`。改完保存即热更新，不必重启。

- 启动即独占插孔 HID（`Transport=Audio` Consumer Control）。键盘 / 蓝牙 / USB 媒体键不会误触发。
- 默认只认点击和长按。气泡分别显示「点击事件」「长按事件」；气泡彻底消失前忽略新手势。
- 黑色遮罩只跟按下 / 松开，与气泡是否在场无关。
- 手势时长见 `popup.conf` 的 `doubleClickMs` / `longPressMs`。
