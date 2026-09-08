import Foundation

enum ProcessOutput {
    /// Binary output (for example PNG bytes from Shortcuts) must never reach a text renderer.
    static func describe(_ data: Data, truncated: Bool) -> String {
        guard !data.isEmpty else { return "" }
        let binaryMessage = "[收到图片或其他二进制输出，未作为文本展示。请在快捷指令中保存或查看文件。]"
        // PDF can consist entirely of printable ASCII and still isn't a text log.
        if data.starts(with: Data("%PDF-".utf8)) { return binaryMessage }
        var text = String(data: data, encoding: .utf8)
        if text == nil && truncated {
            // A retained UTF-8 prefix can end partway through its final code point.
            for tail in 1...min(3, data.count) {
                if let prefix = String(data: data.dropLast(tail), encoding: .utf8) {
                    text = prefix
                    break
                }
            }
        }
        guard let text, !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t"
        }) else { return binaryMessage }
        return text + (truncated ? "\n[输出已截断]" : "")
    }
}
