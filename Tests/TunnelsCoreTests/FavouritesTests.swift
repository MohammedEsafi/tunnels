import XCTest
@testable import TunnelsCore

final class MiniTOMLTests: XCTestCase {
    func testArrayOfTablesAndScalars() throws {
        let text = """
        title = "Tunnels" # trailing comment
        count = 1_000
        ratio = 0.5
        on = true
        ports = [1, 2, 3]

        [settings]
        login = false

        [[favourite]]
        name = "postgres"
        port = 5432

        [[favourite]]
        name = 'mail # not a comment'
        port = 1025
        """
        let root = try MiniTOML.parse(text)
        XCTAssertEqual(root["title"], .string("Tunnels"))
        XCTAssertEqual(root["count"], .integer(1000))
        XCTAssertEqual(root["ratio"], .double(0.5))
        XCTAssertEqual(root["on"], .boolean(true))
        XCTAssertEqual(root["ports"], .array([.integer(1), .integer(2), .integer(3)]))
        XCTAssertEqual(root["settings"], .table(["login": .boolean(false)]))
        let favourites = try XCTUnwrap(root["favourite"]?.tables)
        XCTAssertEqual(favourites.count, 2)
        XCTAssertEqual(favourites[0]["name"], .string("postgres"))
        XCTAssertEqual(favourites[1]["name"], .string("mail # not a comment"))
        XCTAssertEqual(favourites[1]["port"], .integer(1025))
    }

    func testErrorsCarryLineNumbers() {
        XCTAssertThrowsError(try MiniTOML.parse("ok = 1\nbroken\n")) { error in
            XCTAssertEqual(error as? TOMLError, TOMLError(line: 2, message: "expected key = value"))
        }
        XCTAssertThrowsError(try MiniTOML.parse("name = \"open\n")) { error in
            XCTAssertEqual((error as? TOMLError)?.line, 1)
        }
    }
}

final class FavouritesTests: XCTestCase {
    func testParsesFavouritesWithDefaults() throws {
        let text = """
        [[favourite]]
        name = "postgres"
        host = "prod-db-01"
        port = 5432

        [[favourite]]
        host = "staging"
        port = 15432
        remote_port = 5432
        remote_host = "db.internal"
        """
        let favourites = try Favourites.parse(text)
        XCTAssertEqual(favourites.count, 2)
        XCTAssertEqual(favourites[0].name, "postgres")
        XCTAssertEqual(favourites[0].spec, ForwardSpec(machine: "prod-db-01", localPort: 5432))
        XCTAssertEqual(favourites[1].name, "5432")
        XCTAssertEqual(favourites[1].spec, ForwardSpec(machine: "staging", localPort: 15432, remoteHost: "db.internal", remotePort: 5432))
    }

    func testValidationCollectsEveryProblem() {
        let text = """
        [[favourite]]
        name = "no host"
        port = 1

        [[favourite]]
        host = "a"
        port = 70000

        [[favourite]]
        host = "b"
        port = 80

        [[favourite]]
        host = "b"
        port = 80
        """
        XCTAssertThrowsError(try Favourites.parse(text)) { error in
            let problems = (error as? FavouritesError)?.problems ?? []
            XCTAssertEqual(problems.count, 3)
            XCTAssertTrue(problems[0].contains("host is required"))
            XCTAssertTrue(problems[1].contains("out of range"))
            XCTAssertTrue(problems[2].contains("listed twice"))
        }
    }

    func testEmptyAndTemplateFilesGiveNoFavourites() throws {
        XCTAssertEqual(try Favourites.parse(""), [])
        XCTAssertEqual(try Favourites.parse(Favourites.template), [])
    }

    func testAddAndRemoveRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("favourites.toml")
        try """
        # my favourites

        [[favourite]]
        name = "postgres"   # keep this comment
        host = "prod"
        port = 5432

        [settings]
        x = 1
        """.write(to: url, atomically: true, encoding: .utf8)

        let web = Favourite(name: "web", spec: ForwardSpec(machine: "staging", localPort: 28080, remoteHost: "db.internal", remotePort: 8080))
        try Favourites.add(web, to: url)
        var loaded = try Favourites.load(from: url)
        XCTAssertEqual(loaded.map(\.name), ["postgres", "web"])
        XCTAssertEqual(loaded[1].spec, web.spec)

        XCTAssertTrue(try Favourites.remove(ForwardSpec(machine: "prod", localPort: 5432), from: url))
        loaded = try Favourites.load(from: url)
        XCTAssertEqual(loaded.map(\.name), ["web"])
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("# my favourites"))
        XCTAssertTrue(text.contains("[settings]"))
        XCTAssertFalse(text.contains("keep this comment"))

        XCTAssertFalse(try Favourites.remove(ForwardSpec(machine: "nope", localPort: 1), from: url))
    }

    func testRenameKeepsEverythingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("favourites.toml")
        try """
        [[favourite]]
        host = "echo"   # no name yet
        port = 4040

        [[favourite]]
        name = "postgres"
        host = "prod"
        port = 5432
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try Favourites.rename(ForwardSpec(machine: "echo", localPort: 4040), to: "echo api", in: url))
        XCTAssertTrue(try Favourites.rename(ForwardSpec(machine: "prod", localPort: 5432), to: "pg \"main\"", in: url))
        let loaded = try Favourites.load(from: url)
        XCTAssertEqual(loaded.map(\.name), ["echo api", "pg \"main\""])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("# no name yet"))
        XCTAssertFalse(try Favourites.rename(ForwardSpec(machine: "nope", localPort: 1), to: "x", in: url))
    }

    func testHostBlocksRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("favourites.toml")
        try """
        [[favourite]]
        name = "postgres"
        host = "prod"
        port = 5432
        """.write(to: url, atomically: true, encoding: .utf8)

        try Favourites.addHost(AutoHost(name: "echo"), to: url)
        try Favourites.addHost(AutoHost(name: "gpu", excluded: [5432, 22]), to: url)
        XCTAssertEqual(Favourites.loadHosts(from: url), [AutoHost(name: "echo"), AutoHost(name: "gpu", excluded: [5432, 22])])
        XCTAssertEqual(try Favourites.load(from: url).count, 1)

        XCTAssertTrue(try Favourites.setExcluded([3000], forHost: "echo", in: url))
        XCTAssertTrue(try Favourites.setExcluded([], forHost: "gpu", in: url))
        XCTAssertEqual(Favourites.loadHosts(from: url), [AutoHost(name: "echo", excluded: [3000]), AutoHost(name: "gpu")])
        // Repeated edits must not grow the file with blank lines.
        for port in [3001, 3002, 3003] {
            XCTAssertTrue(try Favourites.setExcluded([3000, port], forHost: "echo", in: url))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("\n\n\n"), "blank lines accumulated:\n\(text)")
        XCTAssertTrue(text.contains("all_ports = true\nexclude = [3000, 3003]\n"))

        XCTAssertTrue(try Favourites.setOffset(10000, forHost: "echo", in: url))
        XCTAssertEqual(Favourites.loadHosts(from: url).first?.offset, 10000)
        XCTAssertTrue(try Favourites.setOffset(nil, forHost: "echo", in: url))
        XCTAssertNil(Favourites.loadHosts(from: url).first?.offset)

        XCTAssertTrue(try Favourites.removeHost("echo", from: url))
        XCTAssertFalse(try Favourites.removeHost("nope", from: url))
        XCTAssertEqual(Favourites.loadHosts(from: url), [AutoHost(name: "gpu")])
        XCTAssertEqual(try Favourites.load(from: url).map(\.name), ["postgres"])
    }

    func testChangeLocalPortKeepsRemote() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("favourites.toml")
        try """
        [[favourite]]
        name = "web"
        host = "box-b"
        port = 8080

        [[favourite]]
        name = "api"
        host = "box-b"
        port = 18081
        remote_port = 8081
        """.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(try Favourites.changeLocalPort(ForwardSpec(machine: "box-b", localPort: 8080), to: 18080, in: url))
        XCTAssertTrue(try Favourites.changeLocalPort(ForwardSpec(machine: "box-b", localPort: 18081, remotePort: 8081), to: 28081, in: url))
        let loaded = try Favourites.load(from: url)
        XCTAssertEqual(loaded[0].spec, ForwardSpec(machine: "box-b", localPort: 18080, remotePort: 8080))
        XCTAssertEqual(loaded[1].spec, ForwardSpec(machine: "box-b", localPort: 28081, remotePort: 8081))
        XCTAssertFalse(try Favourites.changeLocalPort(ForwardSpec(machine: "nope", localPort: 1), to: 2, in: url))

        // The app's own moves are flagged, and the flag goes away when it moves back.
        XCTAssertTrue(try Favourites.changeLocalPort(ForwardSpec(machine: "box-b", localPort: 18080, remotePort: 8080), to: 28080, movedByApp: true, in: url))
        XCTAssertTrue(try Favourites.load(from: url)[0].movedByApp)
        XCTAssertTrue(try Favourites.changeLocalPort(ForwardSpec(machine: "box-b", localPort: 28080, remotePort: 8080), to: 8080, movedByApp: false, in: url))
        let back = try Favourites.load(from: url)[0]
        XCTAssertFalse(back.movedByApp)
        XCTAssertEqual(back.spec, ForwardSpec(machine: "box-b", localPort: 8080))
    }

    func testChangePortsWritesRemoteOnlyWhenDifferent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("favourites.toml")
        try """
        [[favourite]]
        name = "web"
        host = "box-b"
        port = 8080
        """.write(to: url, atomically: true, encoding: .utf8)

        // Both ports change; remote_port appears.
        XCTAssertTrue(try Favourites.changePorts(ForwardSpec(machine: "box-b", localPort: 8080), local: 18080, remote: 8081, in: url))
        XCTAssertEqual(try Favourites.load(from: url)[0].spec, ForwardSpec(machine: "box-b", localPort: 18080, remotePort: 8081))
        // Back to equal ports; remote_port goes away again.
        XCTAssertTrue(try Favourites.changePorts(ForwardSpec(machine: "box-b", localPort: 18080, remotePort: 8081), local: 9090, remote: 9090, in: url))
        XCTAssertEqual(try Favourites.load(from: url)[0].spec, ForwardSpec(machine: "box-b", localPort: 9090))
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("remote_port"))
    }

    func testAddCreatesFileWithTemplate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tunnels/favourites.toml")
        try Favourites.add(Favourite(name: "4040", spec: ForwardSpec(machine: "echo", localPort: 4040)), to: url)
        XCTAssertEqual(try Favourites.load(from: url), [Favourite(name: "4040", spec: ForwardSpec(machine: "echo", localPort: 4040))])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("# Tunnels favourites"))
    }

    func testLoadCreatesTemplateOnFirstRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tunnels/favourites.toml")
        XCTAssertEqual(try Favourites.load(from: url), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
