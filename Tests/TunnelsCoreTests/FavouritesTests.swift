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

    func testLoadCreatesTemplateOnFirstRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tunnels/favourites.toml")
        XCTAssertEqual(try Favourites.load(from: url), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
