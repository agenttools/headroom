// swift-tools-version: 6.4
//
// Headroom — dependency direction (enforced by the target graph below):
//
//   HeadroomContracts  <-  HeadroomCore  <-  { HeadroomClaude, HeadroomChrome }  <-  HeadroomActions  <-  { HeadroomApp, HeadroomCLI }
//   headroom-host depends only on HeadroomContracts (Foundation-only wire types).
//
// Product names:
//   HeadroomApp  -> binary "HeadroomApp"; scripts/build.sh copies it to Headroom.app/Contents/MacOS/Headroom.
//                   (It cannot be a product called "Headroom": APFS is case-insensitive, so it would collide
//                   with the CLI binary "headroom" in the same .build/<config>/ directory.)
//   headroom     -> the CLI (target HeadroomCLI), symlinked to ~/bin/headroom by install.sh.
//   headroom-host-> native-messaging host, bundled at Headroom.app/Contents/Helpers/headroom-host.
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
        .executable(name: "headroom", targets: ["HeadroomCLI"]),
        .executable(name: "headroom-host", targets: ["headroom-host"]),
        .library(name: "HeadroomContracts", targets: ["HeadroomContracts"]),
        .library(name: "HeadroomActions", targets: ["HeadroomActions"]),
    ],
    targets: [
        // Shared types and protocols every other module builds on (SPEC §11).
        .target(name: "HeadroomContracts"),
        // SysKit, Ownership, Shell, Tmux, Git.
        .target(name: "HeadroomCore", dependencies: ["HeadroomContracts"]),
        // Sessions, transcript tails, ClaudeSource.
        .target(name: "HeadroomClaude", dependencies: ["HeadroomContracts", "HeadroomCore"]),
        // ChromeBridge, Attribution, JXAFallback, ChromeSource.
        .target(name: "HeadroomChrome", dependencies: ["HeadroomContracts", "HeadroomCore"]),
        // Planner, CloseCoordinator, Signaller, Journal, Undo, composition (Headroom.live()/mock()).
        .target(name: "HeadroomActions",
                dependencies: ["HeadroomContracts", "HeadroomCore", "HeadroomClaude", "HeadroomChrome"]),
        // The AppKit app.
        .executableTarget(name: "HeadroomApp",
                          dependencies: ["HeadroomContracts", "HeadroomCore", "HeadroomChrome", "HeadroomActions"]),
        // The `headroom` CLI.
        .executableTarget(name: "HeadroomCLI",
                          dependencies: ["HeadroomContracts", "HeadroomCore", "HeadroomActions"]),
        // Native-messaging host (Foundation + Contracts wire types only).
        .executableTarget(name: "headroom-host", dependencies: ["HeadroomContracts"]),

        .testTarget(name: "HeadroomContractsTests", dependencies: ["HeadroomContracts"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore", "HeadroomContracts"]),
        .testTarget(name: "HeadroomClaudeTests", dependencies: ["HeadroomClaude", "HeadroomContracts"]),
        .testTarget(name: "HeadroomChromeTests", dependencies: ["HeadroomChrome", "HeadroomCore", "HeadroomContracts"]),
        .testTarget(name: "HeadroomActionsTests", dependencies: ["HeadroomActions", "HeadroomContracts"]),
        .testTarget(name: "HeadroomCLITests", dependencies: ["HeadroomCLI", "HeadroomActions", "HeadroomContracts"]),
        .testTarget(name: "HeadroomHostTests", dependencies: ["headroom-host", "HeadroomContracts"]),
    ]
)
