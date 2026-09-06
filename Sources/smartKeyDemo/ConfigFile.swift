import Foundation
import SmartKey

enum DemoConfig {
    static func load() -> SmartKeyConfiguration {
        let names = ["smartKey.conf"]
        var candidates: [URL] = []
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        if let exec = Bundle.main.executableURL {
            candidates.append(exec.deletingLastPathComponent())
        }

        var seen = Set<String>()
        for dir in candidates {
            for name in names {
                let url = dir.appendingPathComponent(name)
                let path = url.path
                guard seen.insert(path).inserted else { continue }
                guard FileManager.default.isReadableFile(atPath: path) else { continue }
                do {
                    return try parse(String(contentsOf: url, encoding: .utf8))
                } catch {
                    continue
                }
            }
        }
        return .default
    }

    private static func parse(_ text: String) throws -> SmartKeyConfiguration {
        var config = SmartKeyConfiguration.default
        for (lineNumber, raw) in text.components(separatedBy: .newlines).enumerated() {
            var line = raw
            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash])
            }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else {
                throw DemoConfigError.badLine(lineNumber + 1, raw)
            }
            guard let value = Int(parts[1]), value > 0 else {
                throw DemoConfigError.badValue(parts[0], parts[1])
            }
            switch parts[0] {
            case "doubleClickMs": config.doubleClickMs = value
            case "longPressMs": config.longPressMs = value
            default: throw DemoConfigError.unknownKey(parts[0])
            }
        }
        return config
    }
}

enum DemoConfigError: Error, CustomStringConvertible {
    case badLine(Int, String)
    case badValue(String, String)
    case unknownKey(String)

    var description: String {
        switch self {
        case let .badLine(n, line): return "第 \(n) 行无法解析: \(line)"
        case let .badValue(k, v): return "\(k) 的值无效: \(v)"
        case let .unknownKey(k): return "未知键: \(k)"
        }
    }
}
