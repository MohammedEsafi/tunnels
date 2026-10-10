import XCTest
@testable import TunnelsCore

final class ExternalScannerTests: XCTestCase {
    func testParsesTerminalForwards() {
        let ps = """
          48122   501 ssh -N -L 3000:localhost:3000 dev-box
          48123   501 ssh -L 8080:localhost:80 -L 127.0.0.1:9000:db.internal:5432 -i ~/.ssh/id_ed25519 -p 2222 user@staging.internal
          48124   501 /usr/bin/ssh -N -M -S /Users/me/Library/Application Support/Tunnels/sockets/abc -o ControlPersist=no prod-db-01
          48125   501 ssh -S /tmp/sock -O forward -L 127.0.0.1:5432:localhost:5432 prod-db-01
          48126   502 ssh -L 1:localhost:1 someone-elses
          48127   501 ssh -L3306:localhost:3306 -fN db
          48128   501 /bin/zsh -l
          48129   501 ssh -N -L 3999:localhost:3999 -o ProxyCommand=sleep 600 dev-box
          48130   501 ssh -o ProxyCommand=nc %h %p -L 4000:localhost:4000 me@jump.example.com
        """
        let found = ExternalScanner.parse(ps, currentUID: 501)
        XCTAssertEqual(found.count, 6)
        XCTAssertEqual(found[4].spec, ForwardSpec(machine: "dev-box", localPort: 3999))
        XCTAssertEqual(found[5].spec, ForwardSpec(machine: "jump.example.com", localPort: 4000))

        XCTAssertEqual(found[0].pid, 48122)
        XCTAssertEqual(found[0].spec, ForwardSpec(machine: "dev-box", localPort: 3000))

        XCTAssertEqual(found[1].pid, 48123)
        XCTAssertEqual(found[1].spec, ForwardSpec(machine: "staging.internal", localPort: 8080, remotePort: 80))
        XCTAssertEqual(found[2].spec, ForwardSpec(machine: "staging.internal", localPort: 9000, remoteHost: "db.internal", remotePort: 5432))

        XCTAssertEqual(found[3].pid, 48127)
        XCTAssertEqual(found[3].spec, ForwardSpec(machine: "db", localPort: 3306))
    }

    func testTokenizerHonoursQuotes() {
        XCTAssertEqual(ExternalScanner.tokenize("ssh -o 'ProxyCommand nc %h %p' host"), ["ssh", "-o", "ProxyCommand nc %h %p", "host"])
    }
}

final class PersistedStateTests: XCTestCase {
    func testRoundTrip() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        let state = PersistedState(onForwards: [
            .init(spec: ForwardSpec(machine: "a", localPort: 1), name: "one", isFavourite: true),
            .init(spec: ForwardSpec(machine: "b", localPort: 2, remotePort: 3), name: "3", isFavourite: false),
        ])
        state.save(to: url)
        XCTAssertEqual(PersistedState.load(from: url), state)
        XCTAssertEqual(PersistedState.load(from: dir.appendingPathComponent("missing.json")), PersistedState())
    }
}
