import Testing
import AppKit
import SwiftUI
@testable import SmartKeyActions
@testable import smartKeyPopup

@Suite
struct ExecutionOutputPreviewTests {
    @Test func largeSingleLineAndCombiningSequencesHaveBoundedLayout() {
        for source in [String(repeating: "a", count: 256 * 1024), "a" + String(repeating: "\u{0301}", count: 256 * 1024)] {
            let preview = ExecutionOutputPreview.text(source)
            #expect(preview.contains("预览已截断"))
            #expect(preview.unicodeScalars.count < 4300)
            #expect(preview.split(separator: "\n").allSatisfy { $0.unicodeScalars.count <= 160 })
        }
    }

    @Test func regularTextIsPreservedAndControlCharactersAreNotRendered() {
        #expect(ExecutionOutputPreview.text("第一行\n第二行") == "第一行\n第二行")
        #expect(ExecutionOutputPreview.text("a\0b\tend") == "ab    end")
        #expect(ExecutionOutputPreview.text("").isEmpty)
    }

    @Test @MainActor func expandedOutputRendersWithBoundedSize() throws {
        _ = NSApplication.shared
        let binary = ProcessOutput.describe(Data([0x89, 0x50, 0x4e, 0x47]) + Data(repeating: 0, count: 256 * 1024), truncated: true)
        let samples = [binary, String(repeating: "a", count: 256 * 1024), "a" + String(repeating: "\u{0301}", count: 256 * 1024)]
        for (index, output) in samples.enumerated() {
            let view = NSHostingView(rootView:
                ExecutionOutputView(stdout: output, stderr: "测试诊断", isExpanded: true)
                    .padding(20).frame(width: 560, height: 260).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 560, height: 260),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/smartkey-output-preview-\(index).png"))
            #expect(view.bounds.width == 560 && view.bounds.height == 260)
        }
    }
}
