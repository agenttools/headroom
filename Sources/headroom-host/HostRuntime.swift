// The relay process: Chrome's stdio on one side, app.sock on the other (SPEC §2, §4.2).
//
// Threads: one blocking reader for stdin, one per app connection for the socket. All state and
// all writes happen on `q`, so the Router needs no locks.

import Darwin
import Foundation
import HeadroomContracts

final class HostRuntime: @unchecked Sendable {
    static let pingInterval: TimeInterval = 20
    static let pollInterval: TimeInterval = 2

    let env: HeadroomEnv
    let browserPid: pid_t
    private let q = DispatchQueue(label: "dev.adder.headroom.host")
    private var router = Router()          // q only
    private var sock: Int32 = -1           // q only
    private var generation = 0             // q only
    private var lastRefusal: String?       // q only, to log each distinct refusal once
    private var timers: [DispatchSourceTimer] = []

    init(env: HeadroomEnv, browserPid: pid_t = getppid()) {
        self.env = env
        self.browserPid = browserPid
    }

    func hostLine() -> Data {
        let hello = Wire.HostHello(hostPid: getpid(), browserPid: browserPid, hostVersion: HeadroomIDs.version)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        var d = (try? enc.encode(hello)) ?? Data()
        d.append(0x0A)
        return d
    }

    func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Log.line("started; browserPid \(browserPid); run dir \(env.runDir)")
        startStdinReader()
        q.async {
            self.perform(self.router.startup())
            self.tryConnect()
        }
        timers.append(repeating(Self.pingInterval) { self.perform(self.router.keepalive()) })
        timers.append(repeating(Self.pollInterval) { self.tryConnect() })
        dispatchMain()
    }

    private func repeating(_ every: TimeInterval, _ body: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + every, repeating: every, leeway: .milliseconds(200))
        t.setEventHandler(handler: body)
        t.resume()
        return t
    }

    // MARK: stdin (Chrome → host)

    private func startStdinReader() {
        let t = Thread { [self] in
            var dec = NativeFraming.Decoder()
            while true {
                let chunk = FD.readSome(STDIN_FILENO)
                if chunk.isEmpty {
                    q.sync { self.finish("stdin closed (Chrome closed the port or quit)", code: 0) }
                }
                dec.push(chunk)
                do {
                    while let msg = try dec.next() {
                        q.async { self.perform(self.router.fromExt(msg)) }
                    }
                } catch {
                    q.sync { self.finish("bad frame from Chrome: \(error)", code: 1) }
                }
            }
        }
        t.name = "stdin"
        t.start()
    }

    // MARK: actions (q only)

    private func perform(_ actions: [Router.Action]) {
        for a in actions {
            switch a {
            case .toExt(let d):
                if d.count > NativeFraming.maxToChrome { Log.line("dropped oversize message to Chrome"); continue }
                if !FD.writeAll(STDOUT_FILENO, NativeFraming.encode(d)) { finish("stdout closed", code: 0) }
            case .toApp(let line):
                sendToApp(line)
            case .exit(let why):
                finish(why, code: 0)
            case .log(let s):
                Log.line(s)
            case .connectNow:
                tryConnect()
            }
        }
    }

    private func finish(_ why: String, code: Int32) -> Never {
        Log.line("exiting: \(why)")
        if sock >= 0 { close(sock) }
        exit(code)
    }

    // MARK: app.sock (host ↔ app)

    private func tryConnect() {
        guard sock < 0 else { return }
        switch AppSocket.connect(runDir: env.runDir) {
        case .failure(let f):
            if case .unsafe(let why) = f, why != lastRefusal { Log.line("not connecting: \(why)"); lastRefusal = why }
            perform(router.appSocketAbsent())
        case .success(let fd):
            lastRefusal = nil
            sock = fd
            generation += 1
            startSocketReader(fd: fd, gen: generation)
            Log.line("connected to the app")
            perform(router.appDidConnect(hostLine: hostLine()))
        }
    }

    private func sendToApp(_ line: Data) {
        guard sock >= 0 else { return }
        if !FD.writeAll(sock, line) { dropSocket(gen: generation, why: "write to app failed") }
    }

    private func dropSocket(gen: Int, why: String) {
        guard gen == generation, sock >= 0 else { return }
        close(sock)
        sock = -1
        Log.line(why)
        perform(router.appDidDisconnect())
    }

    private func startSocketReader(fd: Int32, gen: Int) {
        let t = Thread { [self] in
            var lines = LineSplitter()
            while true {
                let chunk = FD.readSome(fd)
                if chunk.isEmpty { break }
                guard let got = try? lines.push(chunk) else { break }
                for l in got { q.async { if gen == self.generation { self.perform(self.router.fromApp(l)) } } }
            }
            q.async { self.dropSocket(gen: gen, why: "app closed the connection") }
        }
        t.name = "app.sock"
        t.start()
    }
}
