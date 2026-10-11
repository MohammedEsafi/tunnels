import XCTest

@testable import TunnelsCore

final class TailscaleHostsTests: XCTestCase {
    func testParsesPeersOnlineFirst() {
        let json = """
            {"BackendState":"Running","Self":{"HostName":"nucleus","Online":true},
             "Peer":{
               "a":{"HostName":"Echo","DNSName":"echo.tail.ts.net.","Online":false,"OS":"macOS"},
               "b":{"HostName":"zeta","Online":true},
               "c":{"HostName":"alpha","Online":true},
               "d":{"HostName":""}
             }}
            """
        let hosts = TailscaleHosts.parse(json)
        XCTAssertEqual(hosts.map(\.name), ["alpha", "zeta", "echo"])
        XCTAssertEqual(hosts.map(\.online), [true, true, false])
        XCTAssertTrue(hosts.allSatisfy { $0.source == .tailscale })
    }

    func testGarbageGivesNothing() {
        XCTAssertEqual(TailscaleHosts.parse(""), [])
        XCTAssertEqual(TailscaleHosts.parse("Tailscale is stopped."), [])
        XCTAssertEqual(TailscaleHosts.parse("{}"), [])
    }
}
