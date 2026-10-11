import XCTest
@testable import TunnelsCore

final class PortDiscoveryTests: XCTestCase {
    func testParsesSsOutput() {
        let ss = """
        LISTEN 0      4096       127.0.0.1:3000        0.0.0.0:*
        LISTEN 0      511          0.0.0.0:8080        0.0.0.0:*
        LISTEN 0      128          0.0.0.0:22          0.0.0.0:*
        LISTEN 0      4096           [::1]:11434          [::]:*
        LISTEN 0      4096               *:5173              *:*
        LISTEN 0      50     127.0.0.53%lo:53          0.0.0.0:*
        """
        XCTAssertEqual(PortDiscovery.parse(ss), [3000, 8080, 11434, 5173])
    }

    func testParsesNetstatOutput() {
        let netstat = """
        Active Internet connections (only servers)
        Proto Recv-Q Send-Q Local Address           Foreign Address         State
        tcp        0      0 127.0.0.1:5432          0.0.0.0:*               LISTEN
        tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN
        tcp6       0      0 :::8081                 :::*                    LISTEN
        tcp        0      0 10.0.0.5:3000           10.0.0.9:51234          ESTABLISHED
        """
        XCTAssertEqual(PortDiscovery.parse(netstat), [5432, 8081])
    }

    func testParsesProcNetTcp() {
        let proc = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0000000000000000 100 0 0 10 0
           1: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 11111 1 0000000000000000 100 0 0 10 0
           2: 0100007F:1F91 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 22222 1 0000000000000000 20 4 30 10 -1
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 00000000000000000000000001000000:2CAA 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 33333 1 0000000000000000 100 0 0 10 0
        """
        XCTAssertEqual(PortDiscovery.parse(proc), [8080, 11434])
    }

    func testEmptyAndGarbage() {
        XCTAssertEqual(PortDiscovery.parse(""), [])
        XCTAssertEqual(PortDiscovery.parse("bash: ss: command not found"), [])
    }
}
