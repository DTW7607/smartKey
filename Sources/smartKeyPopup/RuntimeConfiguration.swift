import AppKit
import Combine
import Foundation

/// User-facing runtime settings. smartKey.conf uses milliseconds and points.
struct RuntimeSettings: Equatable {
    var sidePt: CGFloat = 6
    var bottomPt: CGFloat = 6
    var cornerRadiusPt: CGFloat = 24
    var sideLengthPt: CGFloat = 80
    var bottomLengthPt: CGFloat = 80
    var positiveRadiusPt: CGFloat = 8
    var negativeRadiusPt: CGFloat = 8
    var taperLengthPt: CGFloat = 24
    var shadowRadiusPt: CGFloat = 3
    var shadowOpacity: CGFloat = 0.4
    var appearMs: CGFloat = 75
    var disappearMs: CGFloat = 120
    var cornerSpeed: CGFloat = 2.2
    var bubbleHoldMs: CGFloat = 1000
    var bubbleAppearMs: CGFloat = 300
    var bubbleDisappearMs: CGFloat = 180
    var bubbleRetriggerMs: CGFloat = 20
    var bubbleEndX: CGFloat = -30
    var bubbleEndY: CGFloat = 30
    var doubleClickEnabled: CGFloat = 0
    var doubleClickMs: CGFloat = 450
    var longPressMs: CGFloat = 450
    var deviceChoiceTimeoutMs: CGFloat = 10000
    var insertionPopupDelayMs: CGFloat = 200
    var audioSwitchTimeoutMs: CGFloat = 3000
    var hidConnectionNoticeMs: CGFloat = 5000
    var insertionMaskDurationMs: CGFloat = 800
    var insertionMaskAppearMs: CGFloat = 120
    var insertionMaskDisappearMs: CGFloat = 200
    var setupScreenMarginPt: CGFloat = 18
    var setupChoiceWidthPt: CGFloat = 380
    var setupOutputWidthPt: CGFloat = 480
    var setupTableHeightPt: CGFloat = 174
    var setupCornerRadiusPt: CGFloat = 22

    var setupTiming: DeviceSetupTiming {
        DeviceSetupTiming(choiceTimeout: Double(deviceChoiceTimeoutMs) / 1000,
                          popupDelay: Double(insertionPopupDelayMs) / 1000,
                          audioSwitchTimeout: Double(audioSwitchTimeoutMs) / 1000,
                          hidConnectionNotice: Double(hidConnectionNoticeMs) / 1000)
    }

    var insertionAnimation: InsertionAnimationTiming {
        let duration = Double(insertionMaskDurationMs) / 1000
        let appear = min(Double(insertionMaskAppearMs) / 1000, duration)
        let disappear = min(Double(insertionMaskDisappearMs) / 1000, duration - appear)
        return InsertionAnimationTiming(duration: duration, appear: appear, disappear: disappear)
    }

    /// Invalid/unknown entries are ignored. Removed keys return to documented defaults.
    static func parse(_ text: String) -> RuntimeSettings {
        var settings = RuntimeSettings()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let rule = rules[parts[0]],
                  let value = Double(parts[1]), value.isFinite,
                  rule.range.contains(value) else { continue }
            settings[keyPath: rule.keyPath] = CGFloat(value)
        }
        return settings
    }

    private struct Rule {
        let keyPath: WritableKeyPath<RuntimeSettings, CGFloat>
        let range: ClosedRange<Double>
    }
    private static let rules: [String: Rule] = [
        "sidePt": Rule(keyPath: \.sidePt, range: 0...10000),
        "bottomPt": Rule(keyPath: \.bottomPt, range: 0...10000),
        "cornerRadiusPt": Rule(keyPath: \.cornerRadiusPt, range: 0...10000),
        "sideLengthPt": Rule(keyPath: \.sideLengthPt, range: 0...10000),
        "bottomLengthPt": Rule(keyPath: \.bottomLengthPt, range: 0...10000),
        "positiveRadiusPt": Rule(keyPath: \.positiveRadiusPt, range: 0...10000),
        "negativeRadiusPt": Rule(keyPath: \.negativeRadiusPt, range: 0...10000),
        "taperLengthPt": Rule(keyPath: \.taperLengthPt, range: 0...10000),
        "shadowRadiusPt": Rule(keyPath: \.shadowRadiusPt, range: 0...1000),
        "shadowOpacity": Rule(keyPath: \.shadowOpacity, range: 0...1),
        "appearMs": Rule(keyPath: \.appearMs, range: 0...86400000),
        "disappearMs": Rule(keyPath: \.disappearMs, range: 0...86400000),
        "cornerSpeed": Rule(keyPath: \.cornerSpeed, range: 0.01...100),
        "bubbleHoldMs": Rule(keyPath: \.bubbleHoldMs, range: 0...86400000),
        "bubbleAppearMs": Rule(keyPath: \.bubbleAppearMs, range: 0...86400000),
        "bubbleDisappearMs": Rule(keyPath: \.bubbleDisappearMs, range: 0...86400000),
        "bubbleRetriggerMs": Rule(keyPath: \.bubbleRetriggerMs, range: 0...86400000),
        "bubbleEndX": Rule(keyPath: \.bubbleEndX, range: -10000...10000),
        "bubbleEndY": Rule(keyPath: \.bubbleEndY, range: -10000...10000),
        "doubleClickEnabled": Rule(keyPath: \.doubleClickEnabled, range: 0...1),
        "doubleClickMs": Rule(keyPath: \.doubleClickMs, range: 1...86400000),
        "longPressMs": Rule(keyPath: \.longPressMs, range: 1...86400000),
        "deviceChoiceTimeoutMs": Rule(keyPath: \.deviceChoiceTimeoutMs, range: 0...86400000),
        "insertionPopupDelayMs": Rule(keyPath: \.insertionPopupDelayMs, range: 0...86400000),
        "audioSwitchTimeoutMs": Rule(keyPath: \.audioSwitchTimeoutMs, range: 1...86400000),
        "hidConnectionNoticeMs": Rule(keyPath: \.hidConnectionNoticeMs, range: 1...86400000),
        "insertionMaskDurationMs": Rule(keyPath: \.insertionMaskDurationMs, range: 0...86400000),
        "insertionMaskAppearMs": Rule(keyPath: \.insertionMaskAppearMs, range: 0...86400000),
        "insertionMaskDisappearMs": Rule(keyPath: \.insertionMaskDisappearMs, range: 0...86400000),
        "setupScreenMarginPt": Rule(keyPath: \.setupScreenMarginPt, range: 0...1000),
        "setupChoiceWidthPt": Rule(keyPath: \.setupChoiceWidthPt, range: 320...1000),
        "setupOutputWidthPt": Rule(keyPath: \.setupOutputWidthPt, range: 440...1200),
        "setupTableHeightPt": Rule(keyPath: \.setupTableHeightPt, range: 60...800),
        "setupCornerRadiusPt": Rule(keyPath: \.setupCornerRadiusPt, range: 0...100),
    ]

    private static let orderedKeys: [String] = [
        "doubleClickEnabled", "doubleClickMs", "longPressMs",
        "insertionMaskDurationMs", "insertionMaskAppearMs", "insertionMaskDisappearMs",
        "insertionPopupDelayMs", "deviceChoiceTimeoutMs", "audioSwitchTimeoutMs",
        "hidConnectionNoticeMs",
        "sidePt", "bottomPt", "cornerRadiusPt", "sideLengthPt", "bottomLengthPt",
        "positiveRadiusPt", "negativeRadiusPt", "taperLengthPt",
        "shadowRadiusPt", "shadowOpacity", "appearMs", "disappearMs", "cornerSpeed",
        "bubbleHoldMs", "bubbleAppearMs", "bubbleDisappearMs", "bubbleRetriggerMs",
        "bubbleEndX", "bubbleEndY",
        "setupScreenMarginPt", "setupChoiceWidthPt", "setupOutputWidthPt",
        "setupTableHeightPt", "setupCornerRadiusPt",
    ]

    func serialized() -> String {
        let body = Self.orderedKeys.compactMap { key -> String? in
            guard let rule = Self.rules[key] else { return nil }
            return "\(key) = \(Self.format(self[keyPath: rule.keyPath]))"
        }.joined(separator: "\n")
        return """
        # smartKey.conf — 改完保存即热更新，不必重启。
        # 长度默认 pt，时间默认毫秒。

        \(body)

        """
    }

    private static func format(_ value: CGFloat) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%g", Double(value))
    }

    static func keys(in text: String) -> Set<String> {
        var found = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, rules[parts[0]] != nil { found.insert(parts[0]) }
        }
        return found
    }

    /// Keep values the user already set; take new keys and comments from the factory template.
    static func overlay(userText: String, ontoFactory factoryText: String) -> String {
        var merged = parse(factoryText)
        let user = parse(userText)
        for key in keys(in: userText) {
            guard let rule = rules[key] else { continue }
            merged[keyPath: rule.keyPath] = user[keyPath: rule.keyPath]
        }
        return merged.stamped(onto: factoryText)
    }

    func stamped(onto factoryText: String) -> String {
        let lines = factoryText.components(separatedBy: .newlines)
        let stamped = lines.map { raw -> String in
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let rule = Self.rules[parts[0]] else { return raw }
            return "\(parts[0]) = \(Self.format(self[keyPath: rule.keyPath]))"
        }
        return stamped.joined(separator: "\n")
    }
}

struct DeviceSetupTiming {
    var choiceTimeout: TimeInterval = 10
    /// 未传入 conf 时立即弹出，便于测试。App 会使用用户 `smartKey.conf` 的延迟。
    var popupDelay: TimeInterval = 0
    var audioSwitchTimeout: TimeInterval = 3
    var hidConnectionNotice: TimeInterval = 5
}

struct InsertionAnimationTiming {
    var duration: TimeInterval = 0.8
    var appear: TimeInterval = 0.12
    var disappear: TimeInterval = 0.2
    var releaseAfter: TimeInterval { duration - disappear }
}

/// Observe the containing directory so atomic editor saves do not detach the watcher.
@dynamicMemberLookup
final class RuntimeConfiguration: ObservableObject {
    @Published private(set) var values: RuntimeSettings
    private var source: DispatchSourceFileSystemObject?
    private var reloadWork: DispatchWorkItem?
    private(set) var sourceURL: URL?

    init(values: RuntimeSettings = RuntimeSettings()) { self.values = values }

    subscript<T>(dynamicMember keyPath: KeyPath<RuntimeSettings, T>) -> T { values[keyPath: keyPath] }

    var shadowPad: CGFloat { values.shadowRadiusPt * 2 + 8 }
    var shapeSize: CGSize {
        CGSize(width: max(values.bottomLengthPt, values.sidePt + values.cornerRadiusPt + 1),
               height: max(values.sideLengthPt, values.bottomPt + values.cornerRadiusPt + 1))
    }
    var overlaySize: CGSize {
        CGSize(width: shapeSize.width + shadowPad, height: shapeSize.height + shadowPad)
    }

    static let fileName = "smartKey.conf"
    static let supportFolderName = "smartKey"

    static func userFile(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(supportFolderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    static func load(url: URL? = nil) -> RuntimeConfiguration {
        let config = RuntimeConfiguration()
        let url = url ?? {
            let user = userFile()
            if FileManager.default.isReadableFile(atPath: user.path) {
                return ensureFile(at: user, factory: factoryTemplate())
            }
            return ensureFile(at: user, factory: legacyUserFile() ?? factoryTemplate())
        }()
        config.reload(url)
        config.sourceURL = url
        config.watch(url)
        return config
    }

    /// Patch only owned keys. Preserve comments, unknown fields and unrelated user values.
    func write(_ updates: [String: Double]) throws {
        guard let url = sourceURL else { throw NSError(domain: "smartKey", code: 1, userInfo: [NSLocalizedDescriptionKey: "配置文件未载入。"] ) }
        let original = try String(contentsOf: url, encoding: .utf8)
        let next = Self.replacing(updates, in: original)
        if original != next { try next.write(to: url, atomically: true, encoding: .utf8) }
        let parsed = RuntimeSettings.parse(next)
        if parsed != values { values = parsed }
    }

    static func replacing(_ updates: [String: Double], in text: String) -> String {
        var seen = Set<String>()
        var lines = text.components(separatedBy: "\n").map { line -> String in
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let parts = body[0].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = updates[parts[0]] else { return line }
            seen.insert(parts[0])
            let formatted = value.rounded() == value ? String(Int(value)) : String(value)
            return "\(parts[0]) = \(formatted)" + (body.count > 1 ? " #" + body[1] : "")
        }
        for key in updates.keys.sorted() where !seen.contains(key) {
            lines.append("\(key) = \(updates[key]!)")
        }
        return lines.joined(separator: "\n")
    }

    /// Missing file: copy factory (or write defaults). Existing file: merge new factory keys/comments, keep user values.
    static func ensureFile(at url: URL, factory: URL? = factoryTemplate(),
                           fileManager: FileManager = .default) -> URL {
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.isReadableFile(atPath: url.path) {
            if let factory, fileManager.isReadableFile(atPath: factory.path),
               let factoryText = try? String(contentsOf: factory, encoding: .utf8),
               let userText = try? String(contentsOf: url, encoding: .utf8) {
                let merged = RuntimeSettings.overlay(userText: userText, ontoFactory: factoryText)
                if merged != userText {
                    try? merged.write(to: url, atomically: true, encoding: .utf8)
                }
            }
            return url
        }
        if let factory, fileManager.isReadableFile(atPath: factory.path),
           let data = try? Data(contentsOf: factory) {
            try? data.write(to: url)
        } else {
            try? RuntimeSettings().serialized().write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Previous installs used Application Support/智键; copy once if the new path is empty.
    static func legacyUserFile(fileManager: FileManager = .default) -> URL? {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("智键", isDirectory: true)
            .appendingPathComponent(fileName)
        return fileManager.isReadableFile(atPath: url.path) ? url : nil
    }

    static func factoryTemplate() -> URL? {
        let name = fileName
        let candidates = [
            Bundle.main.url(forResource: "smartKey", withExtension: "conf"),
            Bundle.main.resourceURL?.appendingPathComponent(name),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(name),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func reload(_ url: URL) {
        if !FileManager.default.isReadableFile(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? values.serialized().write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let next = RuntimeSettings.parse(text)
        if next != values { values = next }
    }

    private func watch(_ url: URL) {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.reload(url) }
            self.reloadWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    deinit {
        reloadWork?.cancel()
        source?.cancel()
    }
}
