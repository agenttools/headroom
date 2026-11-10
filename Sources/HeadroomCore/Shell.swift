// Subprocesses: always off the main thread, always with a timeout (SPEC §9).
//
// - No shell: `exe` + `args` are passed to posix_spawn by Foundation.Process.
// - stdout/stderr are drained concurrently (a chatty child can never block on a full pipe), and stdin is written
//   on its own queue with SIGPIPE ignored, so a child that exits early cannot kill us.
// - On timeout (or Task cancellation) the child WE started gets SIGTERM, and we stop waiting for it.
//   Nothing else is ever signalled; SIGKILL is never sent.
// - Output is capped (`maxOutput`, default 8 MB per stream) so a runaway child cannot balloon the app.

import Foundation
import HeadroomContracts

public enum Shell {
    public struct Result: Sendable, Hashable {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public let timedOut: Bool
        public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
            self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
        }
        public var ok: Bool { status == 0 && !timedOut }
    }

    public static let defaultMaxOutput = 8 << 20

    /// Runs `exe args` (no shell), returns when it exits or after `timeout` (then SIGTERMs the child it started).
    /// Cancelling the calling Task also terminates the child.
    public static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 3,
                           environment: [String: String]? = nil, stdin: Data? = nil,
                           cwd: String? = nil) async -> Result {
        let handle = CancelHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    cont.resume(returning: runSync(exe, args, timeout: timeout, environment: environment,
                                                   stdin: stdin, cwd: cwd, cancel: handle))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Lets an async caller stop a running child early.
    public final class CancelHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var onCancel: (() -> Void)?
        public init() {}
        public func cancel() {
            lock.lock(); cancelled = true; let f = onCancel; onCancel = nil; lock.unlock()
            f?()
        }
        /// Registers `f`; runs it at once if already cancelled.
        func whenCancelled(_ f: @escaping () -> Void) {
            lock.lock()
            if cancelled { lock.unlock(); f(); return }
            onCancel = f; lock.unlock()
        }
        func clear() { lock.lock(); onCancel = nil; lock.unlock() }
    }

    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN); return () }()

    public static func runSync(_ exe: String, _ args: [String], timeout: TimeInterval = 3,
                               environment: [String: String]? = nil, stdin: Data? = nil,
                               cwd: String? = nil, cancel: CancelHandle? = nil,
                               maxOutput: Int = defaultMaxOutput) -> Result {
        _ = ignoreSigpipe
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let environment { p.environment = environment }
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inp
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }
        // Parent copies of the child's ends are no longer needed.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        final class Box: @unchecked Sendable {
            let lock = NSLock(); var data = Data()
            func take() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let o = Box(), e = Box(), g = DispatchGroup()
        for (pipe, box) in [(out, o), (err, e)] {
            g.enter()
            DispatchQueue.global(qos: .utility).async {
                let h = pipe.fileHandleForReading
                while true {
                    let chunk = h.availableData          // blocks; empty = EOF
                    if chunk.isEmpty { break }
                    box.lock.lock()
                    if box.data.count < maxOutput { box.data.append(chunk.prefix(maxOutput - box.data.count)) }
                    box.lock.unlock()
                }
                g.leave()
            }
        }
        if let stdin {
            try? inp.fileHandleForReading.close()
            DispatchQueue.global(qos: .utility).async {
                try? inp.fileHandleForWriting.write(contentsOf: stdin)
                try? inp.fileHandleForWriting.close()
            }
        }
        var stopped = false
        final class Flag: @unchecked Sendable { var set = false }
        let cancelled = Flag()
        cancel?.whenCancelled { cancelled.set = true; if p.isRunning { p.terminate() } }
        if done.wait(timeout: .now() + max(timeout, 0)) == .timedOut {
            stopped = true
            if p.isRunning { p.terminate() }   // SIGTERM, only ever our own child
            _ = done.wait(timeout: .now() + 1)
        }
        cancel?.clear()
        // A grandchild that inherited the pipe can keep it open; do not wait for it forever.
        _ = g.wait(timeout: .now() + (stopped ? 0.2 : 1))
        let status: Int32 = (stopped || p.isRunning) ? -1 : p.terminationStatus
        return Result(status: status,
                      stdout: String(decoding: o.take(), as: UTF8.self),
                      stderr: String(decoding: e.take(), as: UTF8.self), timedOut: stopped || cancelled.set)
    }
}
