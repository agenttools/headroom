// Basic HeadroomChrome tests.
import Foundation
import Testing
import HeadroomContracts
@testable import HeadroomChrome

@Suite struct ChromeSkeleton {
    @Test func constructs() async {
        let src = ChromeSource(env: HeadroomEnv(environment: ["HOME": "/nonexistent"]))
        #expect(await src.hosts().isEmpty)
    }
}
