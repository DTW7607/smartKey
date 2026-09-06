import Foundation

print("smartKey demo 启动")
print("只监听内置 3.5mm 线控播放/暂停；键盘/蓝牙媒体键不会触发。")
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
