import Foundation
import SwiftUI

enum ExecutionOutputPreview {
    static let scalarLimit = 4096
    static let lineLimit = 160

    /// Bound text layout independently of the larger capture limit. Use scalars rather
    /// than Characters so a single enormous combining sequence cannot bypass the cap.
    static func text(_ source: String) -> String {
        var preview = ""
        var column = 0
        var count = 0
        for scalar in source.unicodeScalars {
            guard count < scalarLimit else {
                preview += "\n[预览已截断，仅显示前 \(scalarLimit) 个 Unicode 码点]"
                break
            }
            count += 1
            if column >= lineLimit { preview += "\n"; column = 0 }
            if scalar == "\n" || scalar == "\r" {
                preview += "\n"; column = 0
            } else if scalar == "\t" {
                preview += "    "; column += 4
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                preview.unicodeScalars.append(scalar); column += 1
            }
        }
        return preview
    }
}


@MainActor
struct ExecutionOutputView: View {
    let stdout: String
    let stderr: String
    @State var isExpanded = false

    var body: some View {
        DisclosureGroup("查看输出", isExpanded: $isExpanded) {
            if isExpanded {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !stdout.isEmpty { Text(verbatim: ExecutionOutputPreview.text(stdout)).textSelection(.enabled) }
                        if !stderr.isEmpty {
                            Text(verbatim: "标准错误\n" + ExecutionOutputPreview.text(stderr))
                                .foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 180)
            }
        }
    }
}
