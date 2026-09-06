import Foundation

let config = GestureConfig.load()

let jack = JackWatcher()
jack.onChange = { connected in
    print(connected ? "插入" : "拔出")
}
jack.start()

let playPause = PlayPauseWatcher(config: config)
playPause.onGesture = { gesture, count in
    switch gesture {
    case .pending: print("按下 × \(count)")
    case .single: print("单击 × \(count)")
    case .double: print("双击 × \(count)")
    case .longPress: print("长按 × \(count)")
    }
}
playPause.start()

RunLoop.main.run()
