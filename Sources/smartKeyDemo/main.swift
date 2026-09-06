import Foundation
import SmartKey

var config = DemoConfig.load()
let service = SmartKeyService(configuration: config)
var lineBuffer = Data()

service.onJackChange = { connected in
    log("[jack] \(connected ? "插入" : "拔出")")
}
service.onAudioChange = { snapshot in
    log("[audio] 设备列表变化")
    printAudio(snapshot)
}
service.onButton = { phase in
    switch phase {
    case .pressed: log("[button] 按下  pressed=\(service.isButtonPressed)")
    case .released: log("[button] 抬起  pressed=\(service.isButtonPressed)")
    }
}
service.onGesture = { event in
    switch event.gesture {
    case .singleClick: log("[gesture] 单击 × \(event.count)")
    case .doubleClick: log("[gesture] 双击 × \(event.count)")
    case .longPress: log("[gesture] 长按 × \(event.count)")
    }
}
service.onSeizeStatusChange = { status in
    log("[hid] \(seizeText(status))")
}

log("smartKey 接口测试。输入 help 查看命令。")
printStatus()
prompt()

let stdin = DispatchSource.makeReadSource(
    fileDescriptor: FileHandle.standardInput.fileDescriptor,
    queue: .main
)
stdin.setEventHandler {
    let data = FileHandle.standardInput.availableData
    if data.isEmpty {
        service.stop()
        exit(0)
    }
    lineBuffer.append(data)
    while let range = lineBuffer.range(of: Data([0x0a])) {
        var lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
        lineBuffer.removeSubrange(..<range.upperBound)
        if lineData.last == 0x0d { lineData.removeLast() }
        let line = String(data: lineData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        handle(line)
        prompt()
    }
}
stdin.resume()
RunLoop.main.run()

func handle(_ line: String) {
    if line.isEmpty { return }
    let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
    let cmd = parts[0].lowercased()
    let args = Array(parts.dropFirst())
    switch cmd {
    case "help", "h", "?":
        printHelp()
    case "status", "s":
        printStatus()
    case "start":
        service.start()
        log("start  isRunning=\(service.isRunning)")
    case "stop":
        service.stop()
        log("stop  isRunning=\(service.isRunning)  hid=\(seizeText(service.seizeStatus))")
    case "remote":
        guard let on = parseOnOff(args) else {
            log("用法: remote on|off")
            return
        }
        service.setRemoteEnabled(on)
        log("remote \(on ? "on" : "off")  hid=\(seizeText(service.seizeStatus))")
    case "audio", "a":
        printAudio(service.audio)
    case "out":
        setDefault(args, outputs: true)
    case "in":
        setDefault(args, outputs: false)
    case "double":
        guard let ms = parseMs(args) else {
            log("用法: double <ms>")
            return
        }
        service.configuration.doubleClickMs = ms
        log("doubleClickMs=\(service.configuration.doubleClickMs)")
    case "long":
        guard let ms = parseMs(args) else {
            log("用法: long <ms>")
            return
        }
        service.configuration.longPressMs = ms
        log("longPressMs=\(service.configuration.longPressMs)")
    case "emit-jack":
        guard let on = parseOnOff(args) else {
            log("用法: emit-jack on|off")
            return
        }
        service.configuration.emitJackOnStart = on
        log("emitJackOnStart=\(on)")
    case "events":
        setEvents(args)
    case "quit", "q", "exit":
        service.stop()
        exit(0)
    default:
        log("未知命令: \(cmd)  （help 查看）")
    }
}

func setDefault(_ args: [String], outputs: Bool) {
    guard let token = args.first else {
        log(outputs ? "用法: out <序号|uid>" : "用法: in <序号|uid>")
        printAudio(service.audio)
        return
    }
    let snapshot = service.audio
    let devices = outputs ? snapshot.outputs : snapshot.inputs
    let uid: String
    if let index = Int(token) {
        guard devices.indices.contains(index - 1) else {
            log("序号超出范围 1..\(devices.count)")
            return
        }
        uid = devices[index - 1].uid
    } else {
        uid = token
    }
    do {
        if outputs {
            try service.setDefaultOutput(uid: uid)
        } else {
            try service.setDefaultInput(uid: uid)
        }
        log("已切换\(outputs ? "输出" : "输入") → \(uid)")
    } catch {
        log("切换失败: \(error)")
    }
}

func setEvents(_ args: [String]) {
    if args.isEmpty {
        log("enabledEvents=\(eventsText(service.configuration.enabledEvents))")
        return
    }
    let current = service.configuration.enabledEvents
    if let replaced = parseEventSet(args, base: current) {
        service.configuration.enabledEvents = replaced
        log("enabledEvents=\(eventsText(replaced))")
    }
}

func parseEventSet(_ args: [String], base: SmartKeyEventKind) -> SmartKeyEventKind? {
    let modifying = args.contains { $0.hasPrefix("+") || $0.hasPrefix("-") }
    var kind: SmartKeyEventKind = modifying ? base : []
    for raw in args {
        let op: Character?
        let name: String
        if raw.hasPrefix("+") || raw.hasPrefix("-") {
            op = raw.first
            name = String(raw.dropFirst())
        } else if modifying {
            log("混用了 ± 与绝对列表")
            return nil
        } else {
            op = nil
            name = raw
        }
        guard let bit = eventKind(name) else {
            log("未知事件: \(name)")
            return nil
        }
        if op == "-" {
            kind.remove(bit)
        } else {
            kind.formUnion(bit)
        }
    }
    return kind
}

func eventKind(_ name: String) -> SmartKeyEventKind? {
    switch name.lowercased() {
    case "press", "按下": return .press
    case "release", "抬起": return .release
    case "single", "单击": return .singleClick
    case "double", "双击": return .doubleClick
    case "long", "longpress", "长按": return .longPress
    case "jack", "插孔": return .jack
    case "raw": return .raw
    case "gestures", "手势": return .gestures
    case "all", "全部": return .all
    case "none", "无": return []
    default: return nil
    }
}

func parseOnOff(_ args: [String]) -> Bool? {
    guard let token = args.first?.lowercased() else { return nil }
    switch token {
    case "on", "1", "true", "yes", "开": return true
    case "off", "0", "false", "no", "关": return false
    default: return nil
    }
}

func parseMs(_ args: [String]) -> Int? {
    guard let token = args.first, let value = Int(token), value > 0 else { return nil }
    return value
}

func printStatus() {
    let c = service.configuration
    log("isRunning=\(service.isRunning)")
    log("isJackConnected=\(service.isJackConnected)")
    log("isRemoteEnabled=\(service.isRemoteEnabled)")
    log("seizeStatus=\(seizeText(service.seizeStatus))")
    log("isButtonPressed=\(service.isButtonPressed)")
    log("doubleClickMs=\(c.doubleClickMs)  longPressMs=\(c.longPressMs)  emitJackOnStart=\(c.emitJackOnStart)")
    log("enabledEvents=\(eventsText(c.enabledEvents))")
    printAudio(service.audio)
}

func printAudio(_ snapshot: SmartKeyAudioSnapshot) {
    log("[audio] 输出  analogDefault=\(snapshot.isAnalogJackDefaultOutput)")
    printDeviceList(snapshot.outputs, defaultUID: snapshot.defaultOutputUID)
    log("[audio] 输入  analogDefault=\(snapshot.isAnalogJackDefaultInput)")
    printDeviceList(snapshot.inputs, defaultUID: snapshot.defaultInputUID)
}

func printDeviceList(_ devices: [SmartKeyAudioDevice], defaultUID: String?) {
    if devices.isEmpty {
        log("    (无)")
        return
    }
    for (i, device) in devices.enumerated() {
        let star = device.uid == defaultUID ? "*" : " "
        let jack = device.isAnalogJack ? " jack" : ""
        log("    \(i + 1) \(star)\(jack) \(device.name) [\(device.uid)] \(transportText(device.transport))")
    }
}

func printHelp() {
    log("""
    start / stop                 启动、停止（插孔 + 音频图）
    status                       查询全部状态
    remote on|off                线控 HID seize
    audio                        打印输入/输出列表
    out <序号|uid>               设置默认输出
    in  <序号|uid>               设置默认输入
    double <ms> / long <ms>      手势超时
    emit-jack on|off             start 时是否回调插孔
    events                       查看事件开关
    events all|none|raw|gestures
    events +双击 -长按            增减事件
    quit                         退出
    """)
}

func seizeText(_ status: SmartKeySeizeStatus) -> String {
    switch status {
    case .idle: return "idle"
    case .waiting: return "等待设备"
    case .seized: return "已独占"
    case .failed: return "独占失败"
    }
}

func eventsText(_ kind: SmartKeyEventKind) -> String {
    let items: [(SmartKeyEventKind, String)] = [
        (.press, "press"),
        (.release, "release"),
        (.singleClick, "single"),
        (.doubleClick, "double"),
        (.longPress, "long"),
        (.jack, "jack"),
    ]
    let names = items.compactMap { kind.contains($0.0) ? $0.1 : nil }
    return names.isEmpty ? "none" : names.joined(separator: ",")
}

func transportText(_ transport: SmartKeyAudioTransport) -> String {
    switch transport {
    case .builtIn: return "builtIn"
    case .bluetooth: return "bluetooth"
    case .usb: return "usb"
    case .displayPort: return "displayPort"
    case .hdmi: return "hdmi"
    case .airPlay: return "airPlay"
    case .aggregate: return "aggregate"
    case .virtual: return "virtual"
    case .other: return "other"
    }
}

func log(_ text: String) {
    fputs(text + "\n", stdout)
    fflush(stdout)
}

func prompt() {
    fputs("> ", stdout)
    fflush(stdout)
}
