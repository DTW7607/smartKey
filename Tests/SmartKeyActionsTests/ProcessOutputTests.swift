import Foundation
import Testing
@testable import SmartKeyActions

@Suite
struct ProcessOutputTests {
    @Test func imageAndOtherBinaryOutputNeverBecomesText() {
        let samples: [Data] = [
            Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 0xff, count: 256 * 1024),
            Data([0xff, 0xd8, 0xff, 0xe0]),
            Data("II\0*\0binary".utf8),
            Data("%PDF-1.7\nprintable but not a log".utf8),
            Data("abc\0def".utf8)
        ]
        for sample in samples {
            let output = ProcessOutput.describe(sample, truncated: true)
            #expect(output.contains("二进制输出"))
            #expect(output.utf8.count < 256)
            #expect(!output.contains("�"))
        }
    }

    @Test func textLogsRemainReadableIncludingCutMultibyteSuffix() {
        let text = "中文输出\nnext\tline\r\n"
        #expect(ProcessOutput.describe(Data(text.utf8), truncated: false) == text)
        #expect(ProcessOutput.describe(Data(), truncated: false).isEmpty)
        let cut = Data("内容".utf8) + Data([0xe4, 0xb8])
        #expect(ProcessOutput.describe(cut, truncated: true) == "内容\n[输出已截断]")
        #expect(ProcessOutput.describe(cut, truncated: false).contains("二进制输出"))
    }

    @Test func binaryPipeIsDrainedAndErrorsRemainAvailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = directory.appendingPathComponent("image.bin")
        try (Data([0x89, 0x50, 0x4e, 0x47]) + Data(repeating: 0, count: 1024 * 1024)).write(to: fixture)
        let result = try await ManagedProcess().run {
            ManagedCommand(executable: "/bin/sh", arguments: ["-c", "cat \"$1\"; printf 'diagnostic' >&2", "test", fixture.path],
                           timeout: 5, label: "测试")
        }
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("二进制输出"))
        #expect(result.stdout.utf8.count < 256)
        #expect(result.stderr == "diagnostic")
    }
}
