import Darwin
import Foundation

/// Runs build_app.py in a process group of its own, so Cancel reaches its tools too (hactool, clang, codesign): SIGTERM to
/// the group, which build_app.py --json-progress ends like Ctrl-C (exit 130, the work folder is reused by the next build).
final class BuildRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelRequested = false

    /// Blocks until the program ends and returns its exit status (128 + signal when a signal ended it). stdout and stderr
    /// come line by line on background threads.
    func run(_ executable: String, _ arguments: [String], stdout: @escaping (String) -> Void,
             stderr: @escaping (String) -> Void) throws -> Int32 {
        var out: [Int32] = [0, 0], err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&err) == 0 else {
            close(out[0]); close(out[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, out[1], 1)
        posix_spawn_file_actions_adddup2(&actions, err[1], 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        // CLOEXEC_DEFAULT: the child gets only 0, 1 and 2, never another descriptor of this app
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        lock.lock()
        var child: pid_t = 0
        let rc = cancelRequested ? ECANCELED : posix_spawn(&child, executable, &actions, &attr, argv, environ)
        pid = rc == 0 ? child : 0
        lock.unlock()
        close(out[1]); close(err[1])
        guard rc == 0 else {
            close(out[0]); close(err[0])
            throw POSIXError(.init(rawValue: rc) ?? .EIO)
        }

        let readers = DispatchGroup()
        for (fd, handler) in [(out[0], stdout), (err[0], stderr)] {
            readers.enter()
            Thread.detachNewThread {
                Self.readLines(fd, handler)
                close(fd)
                readers.leave()
            }
        }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        readers.wait()
        lock.lock()
        pid = 0
        lock.unlock()
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Ends the running build (and a build that is about to start).
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested = true
        if pid > 0 { kill(-pid, SIGTERM) }
    }

    private static func readLines(_ fd: Int32, _ handler: (String) -> Void) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            pending.append(buffer, count: n)
            while let newline = pending.firstIndex(of: 0x0A) {
                handler(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        if !pending.isEmpty { handler(String(decoding: pending, as: UTF8.self)) }
    }
}
