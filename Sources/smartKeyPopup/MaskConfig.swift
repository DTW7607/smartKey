import AppKit
import Combine
import Foundation

final class MaskConfig: ObservableObject {
    @Published var sidePt: CGFloat = 36
    @Published var bottomPt: CGFloat = 36
    @Published var cornerRadiusPt: CGFloat = 56
    @Published var sideLengthPt: CGFloat = 240
    @Published var bottomLengthPt: CGFloat = 240
    @Published var positiveRadiusPt: CGFloat = 3
    @Published var negativeRadiusPt: CGFloat = 3
    @Published var taperLengthPt: CGFloat = 24
    @Published var shadowRadiusPt: CGFloat = 3
    @Published var shadowOpacity: CGFloat = 0.4
    @Published var appearMs: CGFloat = 90
    @Published var disappearMs: CGFloat = 220
    @Published var cornerSpeed: CGFloat = 2.2

    var shadowPad: CGFloat { shadowRadiusPt * 2 + 8 }

    var shapeSize: CGSize {
        CGSize(
            width: max(bottomLengthPt, sidePt + cornerRadiusPt + 1),
            height: max(sideLengthPt, bottomPt + cornerRadiusPt + 1)
        )
    }

    var overlaySize: CGSize {
        CGSize(width: shapeSize.width + shadowPad, height: shapeSize.height + shadowPad)
    }

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    static func load() -> MaskConfig {
        let config = MaskConfig()
        if let url = Self.findFile() {
            config.apply(url)
            config.watch(url)
        }
        return config
    }

    private static func findFile() -> URL? {
        let names = ["popup.conf"]
        var dirs: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
        ]
        if let exec = Bundle.main.executableURL {
            dirs.append(exec.deletingLastPathComponent())
        }
        var seen = Set<String>()
        for dir in dirs {
            for name in names {
                let url = dir.appendingPathComponent(name)
                guard seen.insert(url.path).inserted else { continue }
                if FileManager.default.isReadableFile(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private func apply(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var side = sidePt, bottom = bottomPt, radius = cornerRadiusPt
        var sideLen = sideLengthPt, bottomLen = bottomLengthPt
        var positive = positiveRadiusPt, negative = negativeRadiusPt, taper = taperLengthPt
        var shadowR = shadowRadiusPt, shadowA = shadowOpacity
        var appear = appearMs, disappear = disappearMs, corner = cornerSpeed
        for raw in text.components(separatedBy: .newlines) {
            var line = raw
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let value = Double(parts[1]), value >= 0 else { continue }
            switch parts[0] {
            case "sidePt": side = CGFloat(value)
            case "bottomPt": bottom = CGFloat(value)
            case "cornerRadiusPt": radius = CGFloat(value)
            case "sideLengthPt": sideLen = CGFloat(value)
            case "bottomLengthPt": bottomLen = CGFloat(value)
            case "positiveRadiusPt": positive = CGFloat(value)
            case "negativeRadiusPt": negative = CGFloat(value)
            case "taperLengthPt": taper = CGFloat(value)
            case "shadowRadiusPt": shadowR = CGFloat(value)
            case "shadowOpacity": shadowA = CGFloat(value)
            case "appearMs": appear = CGFloat(value)
            case "disappearMs": disappear = CGFloat(value)
            case "cornerSpeed": corner = CGFloat(value)
            default: break
            }
        }
        sidePt = side
        bottomPt = bottom
        cornerRadiusPt = radius
        sideLengthPt = sideLen
        bottomLengthPt = bottomLen
        positiveRadiusPt = positive
        negativeRadiusPt = negative
        taperLengthPt = taper
        shadowRadiusPt = shadowR
        shadowOpacity = shadowA
        appearMs = appear
        disappearMs = disappear
        if corner > 0 { cornerSpeed = corner }
    }

    private func watch(_ url: URL) {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        src.setEventHandler { [weak self] in
            self?.apply(url)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    deinit {
        source?.cancel()
    }
}
