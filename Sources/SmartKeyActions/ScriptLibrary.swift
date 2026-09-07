import AppKit
import Combine
import Darwin
import Foundation
import UniformTypeIdentifiers

private let scriptMaximumBytes = 1_048_576
// JSON escaping can expand a valid 1 MiB source (for example, a source made
// mostly of quotes and backslashes), so the package envelope gets a separate
// bounded read limit.  The content itself is still checked against the 1 MiB
// source limit after decoding.
private let packageMaximumBytes = scriptMaximumBytes * 4 + 512 * 1024

/// The public, non-sensitive metadata stored in a `.smartkeyscript` package.
///
/// Environment variables intentionally do not have a representation in this
/// type.  A package can therefore be inspected or exported without copying a
/// script's private environment into a portable file.
public struct ScriptPackageMetadata: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let summary: String
    public let interpreter: String
    public let workingDirectory: String
    public let timeout: Double

    public init(record: ScriptRecord) {
        id = record.id
        name = record.name
        summary = record.summary
        interpreter = record.interpreter
        workingDirectory = record.workingDirectory
        timeout = record.timeout
    }

    public init(id: UUID, name: String, summary: String = "", interpreter: String = "/bin/zsh",
                workingDirectory: String = "", timeout: Double = 30) {
        self.id = id
        self.name = name
        self.summary = summary
        self.interpreter = interpreter
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public var record: ScriptRecord {
        ScriptRecord(id: id, name: name, summary: summary, interpreter: interpreter,
                     workingDirectory: workingDirectory, timeout: timeout)
    }
}

/// Versioned single-file representation used by `.smartkeyscript` exports.
public struct ScriptPackage: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let script: ScriptPackageMetadata
    public let content: String

    public init(schemaVersion: Int = 1, script: ScriptPackageMetadata, content: String) {
        self.schemaVersion = schemaVersion
        self.script = script
        self.content = content
    }
}

/// Owns the files belonging to script records.  Script contents are always
/// read from disk for an operation that needs the contents; this object only
/// keeps file-status metadata for presentation.
@MainActor
public final class ScriptLibrary: ObservableObject {
    public nonisolated static let maximumScriptBytes = scriptMaximumBytes

    @Published public private(set) var statuses: [UUID: String] = [:]

    public let directory: URL

    private let scriptsDirectory: URL
    private let fileManager: FileManager
    private var records: [UUID: ScriptRecord] = [:]
    private var directoryWatchers: [UUID: DirectoryWatcher] = [:]
    private var scriptsWatcher: DirectoryWatcher?
    private var refreshScheduled = false

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        scriptsDirectory = self.directory.appendingPathComponent("Scripts", isDirectory: true)
        fileManager = .default

        try fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        installScriptsWatcherIfPossible()
    }

    /// Returns the stable path used for a record's source file.
    public func fileURL(for record: ScriptRecord) -> URL {
        scriptsDirectory
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent("script.sh", isDirectory: false)
    }

    /// Creates or atomically replaces a managed shell source file.
    public func createFile(for record: ScriptRecord, content: Data) throws {
        try validateRecord(record)
        try Self.validateScriptData(content)

        let destination = fileURL(for: record)
        try ensureManagedDestination(destination)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(content, to: destination)
        refreshKnownRecord(record)
        installDirectoryWatcherIfPossible(for: record.id)
    }

    /// Imports shell text or the content of a `.smartkeyscript` package into
    /// the managed copy for `record`.  The source is only read; it is never
    /// moved, replaced, or removed.
    public func importFile(_ source: URL, for record: ScriptRecord) throws {
        try validateRecord(record)
        let sourceURL = source.standardizedFileURL
        let destination = fileURL(for: record)
        try validateImportSource(sourceURL, destination: destination)

        if sourceURL.pathExtension.lowercased() == "smartkeyscript" {
            let package = try Self.readPackage(at: sourceURL)
            let data = Data(package.content.utf8)
            try createFile(for: record, content: data)
        } else {
            let data = try Self.readSnapshot(at: sourceURL)
            try createFile(for: record, content: data)
        }
    }

    /// Removes only the selected record's `script.sh`.  Its UUID directory is
    /// removed only when it is empty, so unrelated files are never removed.
    public func removeFile(for record: ScriptRecord) throws {
        let destination = fileURL(for: record)
        try ensureManagedDestination(destination)

        if fileManager.fileExists(atPath: destination.path) {
            guard isRegularFile(destination) else {
                throw ActionError("脚本路径不是普通文件，未删除。")
            }
            try fileManager.removeItem(at: destination)
        }

        let recordDirectory = destination.deletingLastPathComponent()
        if isDirectory(recordDirectory),
           let children = try? fileManager.contentsOfDirectory(atPath: recordDirectory.path),
           children.isEmpty {
            try fileManager.removeItem(at: recordDirectory)
        }

        refreshKnownRecord(record)
        directoryWatchers[record.id] = nil
        // Keep observing an existing UUID directory so an external editor or
        // file restore can make a missing script visible immediately again.
        installDirectoryWatcherIfPossible(for: record.id)
    }

    /// Exports the current on-disk source.  A package contains schema version,
    /// non-sensitive script metadata, and UTF-8 source text.
    public func exportFile(for record: ScriptRecord, to destination: URL, package: Bool) throws {
        try validateRecord(record)
        let source = fileURL(for: record)
        let target = destination.standardizedFileURL
        try validateExportTarget(target, source: source)

        let content = try Self.readSnapshot(at: source)
        let output: Data
        if package {
            guard let text = String(data: content, encoding: .utf8) else {
                throw ActionError("脚本不是有效的 UTF-8 文本。")
            }
            let value = ScriptPackage(script: ScriptPackageMetadata(record: record), content: text)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            output = try encoder.encode(value)
        } else {
            output = content
        }

        try ensureExportParent(target)
        try writeAtomically(output, to: target)
    }

    /// Opens the managed file in a text editor.  `.sh` defaults often launch
    /// Terminal and would execute the script; plain-text editors do not.
    public func openExternally(_ record: ScriptRecord) throws {
        let source = fileURL(for: record)
        guard isRegularFile(source) else {
            throw ActionError("脚本文件不存在或不是普通文件。")
        }
        guard let editor = Self.textEditorURL() else {
            throw ActionError("没有找到可以打开脚本的文本编辑应用。")
        }
        NSWorkspace.shared.open([source], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Localized name of the text editor used by `openExternally`.
    public func defaultApplicationName(for record: ScriptRecord) -> String? {
        guard isRegularFile(fileURL(for: record)), let editor = Self.textEditorURL() else { return nil }
        return fileManager.displayName(atPath: editor.path)
    }

    public static func textEditorURL() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
    }

    /// Asks Finder to reveal the managed file.  NSWorkspace has no throwing
    /// variant for this operation, so callers can use the status/file checks
    /// when they need to present an error.
    public func reveal(_ record: ScriptRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL(for: record)])
    }

    /// Refreshes visible file status and updates directory listeners for the
    /// supplied records.  The Scripts directory and each existing UUID
    /// directory are watched, rather than the script inode itself, so an
    /// editor's atomic replacement remains observable.
    public func refresh(_ records: [ScriptRecord]) {
        self.records = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        installScriptsWatcherIfPossible()

        var nextStatuses: [UUID: String] = [:]
        var activeIDs = Set<UUID>()
        for record in records {
            activeIDs.insert(record.id)
            let source = fileURL(for: record)
            nextStatuses[record.id] = status(for: source)
            installDirectoryWatcherIfPossible(for: record.id)
        }

        for id in directoryWatchers.keys where !activeIDs.contains(id) {
            directoryWatchers[id] = nil
        }
        statuses = nextStatuses
    }

    /// Reads a stable UTF-8 script snapshot.  The file is checked before and
    /// after reading so a missing file or a common atomic replacement cannot
    /// silently yield a mixed version.  No shell parsing or execution occurs.
    public static nonisolated func readSnapshot(at url: URL) throws -> Data {
        let fileURL = url.standardizedFileURL
        let data = try readStableData(at: fileURL, maximumBytes: scriptMaximumBytes)
        try validateScriptData(data)
        return data
    }

    /// Reads and validates a versioned `.smartkeyscript` package without
    /// importing it.  Use `package.script.record` (with an empty environment)
    /// to obtain the package's metadata before choosing a destination record.
    public static nonisolated func readPackage(at url: URL) throws -> ScriptPackage {
        let data = try readStableData(at: url.standardizedFileURL,
                                      maximumBytes: packageMaximumBytes)
        let package: ScriptPackage
        do {
            package = try JSONDecoder().decode(ScriptPackage.self, from: data)
        } catch {
            throw ActionError("智键脚本包格式无效。")
        }

        guard package.schemaVersion == 1 else {
            throw ActionError("智键脚本包版本不受支持。")
        }
        do {
            try package.script.record.validate()
        } catch {
            throw ActionError("智键脚本包中的元信息无效。")
        }
        try validateScriptData(Data(package.content.utf8))
        return package
    }

    /// Convenience metadata-only package reader for import UIs.
    public static nonisolated func readPackageMetadata(at url: URL) throws -> ScriptRecord {
        try readPackage(at: url).script.record
    }

    // MARK: - Internal state and listeners

    private func refreshKnownRecord(_ record: ScriptRecord) {
        guard records[record.id] != nil else { return }
        records[record.id] = record
        statuses[record.id] = status(for: fileURL(for: record))
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh(Array(self.records.values))
        }
    }

    private func installScriptsWatcherIfPossible() {
        guard isDirectory(scriptsDirectory) else {
            scriptsWatcher = nil
            return
        }
        guard scriptsWatcher == nil else { return }
        scriptsWatcher = DirectoryWatcher(url: scriptsDirectory) { [weak self] in
            self?.scriptsDirectoryDidChange()
        }
    }

    private func installDirectoryWatcherIfPossible(for id: UUID) {
        guard directoryWatchers[id] == nil,
              let record = records[id] else { return }
        let recordDirectory = fileURL(for: record).deletingLastPathComponent()
        guard isDirectory(recordDirectory) else { return }
        directoryWatchers[id] = DirectoryWatcher(url: recordDirectory) { [weak self] in
            self?.recordDirectoryDidChange(id)
        }
    }

    private func scriptsDirectoryDidChange() {
        // Reopen after a directory rename/replacement.  Watching the old
        // descriptor alone would miss future events on the new directory.
        scriptsWatcher = nil
        scheduleRefresh()
    }

    private func recordDirectoryDidChange(_ id: UUID) {
        // Reopen on every event so an editor that swaps the UUID directory
        // itself cannot leave us attached to an obsolete inode.
        directoryWatchers[id] = nil
        scheduleRefresh()
    }

    // MARK: - Validation and file operations

    private func validateRecord(_ record: ScriptRecord) throws {
        do {
            try record.validate()
        } catch {
            throw error
        }
    }

    private static nonisolated func validateScriptData(_ data: Data) throws {
        guard data.count <= scriptMaximumBytes else {
            throw ActionError("脚本文件不能超过 1 MiB。")
        }
        guard !data.contains(0) else {
            throw ActionError("脚本不能包含 NUL 字符。")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ActionError("脚本必须是有效的 UTF-8 文本。")
        }
    }

    private func ensureManagedDestination(_ destination: URL) throws {
        let expectedRoot = scriptsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let actualPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isDescendantOrEqual(actualPath, of: expectedRoot), actualPath != expectedRoot else {
            throw ActionError("脚本路径不在脚本库内。")
        }
        guard destination.lastPathComponent == "script.sh" else {
            throw ActionError("脚本路径无效。")
        }
        guard isUUIDDirectory(destination.deletingLastPathComponent()) else {
            throw ActionError("脚本目录无效。")
        }
        if fileManager.fileExists(atPath: destination.path), !isRegularFile(destination) {
            throw ActionError("脚本路径不是普通文件。")
        }
    }

    private func validateImportSource(_ source: URL, destination: URL) throws {
        guard isRegularFile(source) else {
            throw ActionError("导入来源不存在或不是普通文件。")
        }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = destination.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourcePath != destinationPath else {
            throw ActionError("导入来源不能是脚本库中的目标文件。")
        }
        let scriptsPath = scriptsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard !Self.isDescendantOrEqual(sourcePath, of: scriptsPath) else {
            throw ActionError("不能把脚本库内的文件作为导入来源。")
        }
    }

    private func validateExportTarget(_ target: URL, source: URL) throws {
        guard target.path != "/" else {
            throw ActionError("导出目标无效。")
        }
        let targetPath = target.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let scriptsPath = scriptsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard targetPath != sourcePath,
              !Self.isDescendantOrEqual(targetPath, of: scriptsPath) else {
            throw ActionError("导出目标不能覆盖脚本库中的源文件。")
        }
        if fileManager.fileExists(atPath: target.path), isDirectory(target) {
            throw ActionError("导出目标必须是文件路径。")
        }
    }

    private func ensureExportParent(_ target: URL) throws {
        let parent = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard isDirectory(parent) else {
            throw ActionError("导出目标目录无效。")
        }
    }

    private func writeAtomically(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
    }

    private func status(for url: URL) -> String {
        guard isRegularFile(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date else {
            return "文件缺失"
        }
        return "已保存 · " + date.formatted(date: .abbreviated, time: .standard)
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeRegular
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else { return false }
        return type == .typeDirectory
    }

    private func isUUIDDirectory(_ url: URL) -> Bool {
        guard let uuid = UUID(uuidString: url.lastPathComponent),
              uuid.uuidString.caseInsensitiveCompare(url.lastPathComponent) == .orderedSame else {
            return false
        }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let expected = scriptsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == expected
    }

    private static func isDescendantOrEqual(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static nonisolated func readStableData(at url: URL, maximumBytes: Int) throws -> Data {
        guard let before = try? fileStamp(at: url) else {
            throw ActionError("文件不存在或无法读取。")
        }
        guard before.size <= UInt64(maximumBytes) else {
            throw ActionError("文件过大，无法读取。")
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            throw ActionError("文件不存在或无法读取。")
        }
        guard data.count <= maximumBytes else {
            throw ActionError("文件过大，无法读取。")
        }

        guard let after = try? fileStamp(at: url), before == after else {
            throw ActionError("文件正在变化，请稍后重试。")
        }
        return data
    }

    private struct FileStamp: Equatable {
        let device: UInt64?
        let inode: UInt64?
        let size: UInt64
        let modificationDate: Date?
        let resourceIdentifier: String?
    }

    private static nonisolated func fileStamp(at url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular,
              let number = attributes[.size] as? NSNumber else {
            throw ActionError("文件不存在或不是普通文件。")
        }

        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let modificationDate = attributes[.modificationDate] as? Date
        let resourceIdentifier: String?
        if let resourceValues = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
           let identifier = resourceValues.fileResourceIdentifier {
            resourceIdentifier = String(describing: identifier)
        } else {
            resourceIdentifier = nil
        }

        return FileStamp(device: device, inode: inode, size: number.uint64Value,
                         modificationDate: modificationDate,
                         resourceIdentifier: resourceIdentifier)
    }

    private final class DirectoryWatcher {
        private let descriptor: Int32
        private let source: DispatchSourceFileSystemObject

        init?(url: URL, onChange: @escaping () -> Void) {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            self.descriptor = descriptor
            source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
                queue: .main
            )
            source.setEventHandler(handler: onChange)
            source.setCancelHandler { close(descriptor) }
            source.resume()
        }

        deinit {
            source.cancel()
        }
    }
}
