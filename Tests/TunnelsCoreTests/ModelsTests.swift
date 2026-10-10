import XCTest
@testable import TunnelsCore

final class ModelsTests: XCTestCase {
    func testSSHArgumentBindsLoopback() {
        let spec = ForwardSpec(machine: "prod-db-01", localPort: 5432)
        XCTAssertEqual(spec.sshArgument, "127.0.0.1:5432:localhost:5432")
        XCTAssertEqual(spec.portLabel, "5432")
    }

    func testDifferentRemotePort() {
        let spec = ForwardSpec(machine: "staging", localPort: 15432, remotePort: 5432)
        XCTAssertEqual(spec.sshArgument, "127.0.0.1:15432:localhost:5432")
        XCTAssertEqual(spec.portLabel, "15432 → 5432")
    }
}
