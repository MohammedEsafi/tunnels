import XCTest
@testable import TunnelsCore

final class SSHConfigTests: XCTestCase {
    func testHostAliasesSkipPatternsAndNegations() {
        let text = """
        # comment
        Host prod-db-01 prod-db-02
          HostName 10.0.0.5
          User deploy

        Host *.internal
          ProxyJump bastion

        Host !nope staging
        host=dev-box
        Match host something
        """
        var aliases: [String] = []
        SSHConfig.parse(text, baseDirectory: "/tmp", into: &aliases, depth: 0)
        XCTAssertEqual(aliases, ["prod-db-01", "prod-db-02", "staging", "dev-box"])
    }

    func testIncludeIsFollowed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshconfig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let included = dir.appendingPathComponent("work.conf")
        try "Host work-1\nHost work-2\n".write(to: included, atomically: true, encoding: .utf8)
        let main = dir.appendingPathComponent("config")
        try "Host home\nInclude \(included.path)\n".write(to: main, atomically: true, encoding: .utf8)

        XCTAssertEqual(SSHConfig.hostAliases(configPath: main.path), ["home", "work-1", "work-2"])
    }

    func testMissingFileGivesEmptyList() {
        XCTAssertEqual(SSHConfig.hostAliases(configPath: "/nonexistent/config"), [])
    }
}
