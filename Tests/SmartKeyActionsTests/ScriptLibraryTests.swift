import Foundation
import XCTest
@testable import SmartKeyActions

@MainActor
final class ScriptLibraryTests: XCTestCase {
    func testCreateReadRefreshAndRemoveLeavesUnrelatedFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try ScriptLibrary(directory: root)
        let record = ScriptRecord(name: "测试", environment: ["SECRET": "do-not-export"])
        library.refresh([record])
        XCTAssertEqual(library.statuses[record.id], "文件缺失")

        let content = Data("#!/bin/zsh\nprintf 'ok\\n'\n".utf8)
        try library.createFile(for: record, content: content)
        XCTAssertEqual(try ScriptLibrary.readSnapshot(at: library.fileURL(for: record)), content)
        XCTAssertTrue(library.statuses[record.id]?.hasPrefix("已保存") == true)

        let sibling = library.fileURL(for: record).deletingLastPathComponent().appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sibling)
        try library.removeFile(for: record)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.fileURL(for: record).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.deletingLastPathComponent().path))
    }

    func testImportAndExportPackageDoNotExposeEnvironment() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source.sh")
        let sourceContent = Data("echo imported\n".utf8)
        try sourceContent.write(to: source)

        let library = try ScriptLibrary(directory: root.appendingPathComponent("Library"))
        let record = ScriptRecord(name: "导入", summary: "说明", interpreter: "/bin/bash",
                                  workingDirectory: "/tmp", timeout: 45,
                                  environment: ["TOKEN": "private-value"])
        try library.importFile(source, for: record)
        XCTAssertEqual(try Data(contentsOf: source), sourceContent)
        XCTAssertEqual(try ScriptLibrary.readSnapshot(at: library.fileURL(for: record)), sourceContent)

        let packageURL = root.appendingPathComponent("export.smartkeyscript")
        try library.exportFile(for: record, to: packageURL, package: true)
        let package = try ScriptLibrary.readPackage(at: packageURL)
        XCTAssertEqual(package.schemaVersion, 1)
        XCTAssertEqual(package.script.record, ScriptRecord(id: record.id, name: record.name,
                                                           summary: record.summary,
                                                           interpreter: record.interpreter,
                                                           workingDirectory: record.workingDirectory,
                                                           timeout: record.timeout))
        XCTAssertEqual(package.content, String(decoding: sourceContent, as: UTF8.self))
        XCTAssertEqual(try ScriptLibrary.readPackageMetadata(at: packageURL), package.script.record)
        XCTAssertFalse(String(decoding: try Data(contentsOf: packageURL), as: UTF8.self).contains("private-value"))

        let importedRecord = ScriptRecord(name: "新脚本")
        try library.importFile(packageURL, for: importedRecord)
        XCTAssertEqual(try ScriptLibrary.readSnapshot(at: library.fileURL(for: importedRecord)), sourceContent)
    }

    func testSnapshotAndWritesRejectNULInvalidUTF8AndOversizeData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let invalid = root.appendingPathComponent("invalid.sh")
        try Data([0xff, 0xfe]).write(to: invalid)
        XCTAssertThrowsError(try ScriptLibrary.readSnapshot(at: invalid))

        let nul = root.appendingPathComponent("nul.sh")
        try Data([0x65, 0x00, 0x66]).write(to: nul)
        XCTAssertThrowsError(try ScriptLibrary.readSnapshot(at: nul))

        let library = try ScriptLibrary(directory: root.appendingPathComponent("Library"))
        let record = ScriptRecord(name: "超大")
        let oversize = Data(repeating: 0x78, count: ScriptLibrary.maximumScriptBytes + 1)
        XCTAssertThrowsError(try library.createFile(for: record, content: oversize))
    }

    func testLibrarySourceCannotBeUsedAsImportOrExportTarget() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let library = try ScriptLibrary(directory: root)
        let record = ScriptRecord(name: "安全")
        try library.createFile(for: record, content: Data("echo safe\n".utf8))
        let managed = library.fileURL(for: record)

        XCTAssertThrowsError(try library.importFile(managed, for: record))
        XCTAssertThrowsError(try library.exportFile(for: record, to: managed, package: false))
    }

    func testDirectoryWatcherSurvivesAtomicReplacement() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScriptLibrary(directory: root)
        let record = ScriptRecord(name: "外部保存")
        try library.createFile(for: record, content: Data("printf old\n".utf8))
        library.refresh([record])
        let file = library.fileURL(for: record)
        for index in 1...2 {
            let previous = library.statuses[record.id]
            try Data("printf new\(index)\n".utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index * 5))], ofItemAtPath: file.path)
            for _ in 0..<100 {
                if library.statuses[record.id] != previous { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotEqual(library.statuses[record.id], previous)
            XCTAssertEqual(try ScriptLibrary.readSnapshot(at: file), Data("printf new\(index)\n".utf8))
        }
    }

    func testDefaultOpenApplicationIsATextEditor() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try ScriptLibrary(directory: root)
        let record = ScriptRecord(name: "编辑")
        try library.createFile(for: record, content: Data("#!/bin/zsh\n".utf8))
        let name = try XCTUnwrap(library.defaultApplicationName(for: record))
        XCTAssertFalse(name.localizedCaseInsensitiveContains("Terminal"))
        XCTAssertFalse(name.contains("终端"))
        XCTAssertEqual(
            library.defaultApplicationName(for: record),
            FileManager.default.displayName(atPath: try XCTUnwrap(ScriptLibrary.textEditorURL()).path)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("smartkey-script-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
