// headroom-host: the Chrome native-messaging host for the Headroom helper extension.
//
// SPEC §2 and §4.2, docs/protocol.md:
//   - stdin/stdout: Chrome's native-messaging frames (4-byte native-endian length + JSON);
//   - client of app.sock (the app is the server), with uid checks; first line is the `host` line;
//   - ping/pong with the extension every 20 s (not forwarded); exits on stdin EOF;
//   - persistent / on-demand modes (from the extension's hello, or setMode from the app).
//
// Modes of this binary:
//   headroom-host [chrome-extension://<id>/]    relay (what Chrome starts; Chrome passes the origin)
//   headroom-host --probe [--log <file>] …      Spike S: reads data from the extension, logs to a scratch
//                                               file only, never connects to the app (docs/spike-s.md)
//   headroom-host --version

import Foundation
import HeadroomContracts

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> String {
    """
    usage: headroom-host [chrome-extension://<id>/]       (started by Chrome)
           headroom-host --probe [--log FILE] [--snapshots N] [--interval SEC] [--duration SEC]
                                [--ping SEC] [--mark-mb MB]
           headroom-host --version
    """
}

if args.contains("--version") {
    print("headroom-host \(HeadroomIDs.version) (wire v\(Wire.version))")
    exit(0)
}
if args.contains("--help") || args.contains("-h") {
    print(usage())
    exit(0)
}

if args.contains("--probe") || ProcessInfo.processInfo.environment["HEADROOM_HOST_PROBE"] == "1" {
    switch ProbeOptions.parse(args) {
    case .success(let o):
        ProbeRuntime(options: o).run()
    case .failure(let e):
        FileHandle.standardError.write(Data("headroom-host: \(e.message)\n\(usage())\n".utf8))
        exit(1)
    }
}

HostRuntime(env: .current).run()
