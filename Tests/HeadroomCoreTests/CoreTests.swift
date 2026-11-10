// Fixtures (ps.txt, psargs.txt) live in Tests/Fixtures (see Fixtures.url).
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomCore

enum Fixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
}

@Suite struct CoreSkeleton {
    @Test func procStartParsesAsUTC() {
        let d = Ownership.parseProcStart("Tue Sep 29 16:28:53 2026")
        #expect(d != nil)
        #expect(Int(d!.timeIntervalSince1970) == 1_790_699_333)
    }

    @Test func fixturesPresent() {
        #expect(FileManager.default.fileExists(atPath: Fixtures.url("ps.txt").path))
        #expect(FileManager.default.fileExists(atPath: Fixtures.url("psargs.txt").path))
    }

    @Test func shellRunsAndTimesOut() async {
        let ok = await Shell.run("/bin/echo", ["hi"])
        #expect(ok.ok && ok.stdout == "hi\n")
        let slow = await Shell.run("/bin/sleep", ["5"], timeout: 0.2)
        #expect(slow.timedOut)
    }
}
