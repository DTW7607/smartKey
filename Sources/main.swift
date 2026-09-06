import Foundation

print("smartKey demo 启动")
print("独占内置 3.5mm 线控 Play/Pause；未独占成功则不处理按键。")
print("Ctrl+C 退出\n")

let jack = JackWatcher()
jack.onChange = { connected in
    print(connected ? "插入" : "拔出")
}
jack.start()

let playPause = PlayPauseWatcher()
playPause.onPress = { count in
    print("播放键 × \(count)")
}
playPause.start()

RunLoop.main.run()
