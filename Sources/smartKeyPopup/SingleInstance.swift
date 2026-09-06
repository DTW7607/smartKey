import Darwin
import Foundation

enum SingleInstance {
    /// Exclusive lock until process exit. A second copy prints and should exit 0.
    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smartKey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        if fcntl(fd, F_SETLK, &lock) == 0 { return true }
        close(fd)
        return false
    }
}
