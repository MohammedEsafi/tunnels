import XCTest

@testable import TunnelsCore

/// Behaviour pinned before the Phase 4 refactors: these describe what the
/// code does today, on paths the restructuring touches.
@MainActor
final class ControllerLifecycleTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var socketDir: URL!
    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)
    let redis = ForwardSpec(machine: "prod-db-01", localPort: 6379)

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = makeTemporaryDirectory("lifecycle")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.discoveryInterval = 3600
        controller.setFavourites([Favourite(name: "postgres", spec: postgres), Favourite(name: "redis", spec: redis)])
    }

    override func tearDown() async throws {
        await controller.shutdown()
        try? FileManager.default.removeItem(at: socketDir)
    }

    func testShutdownKeepsDesiredStateAndIgnoresLateExits() async {
        await controller.setForward(id: controller.forwards[0].id, on: true)
        await controller.setForward(id: controller.forwards[1].id, on: true)
        var dropped = false
        controller.onMasterDropped = { _, _ in dropped = true }
        let master = runner.runningMasters[0]

        await controller.shutdown()

        XCTAssertTrue(controller.forwards.allSatisfy { $0.desiredOn }, "desired state survives for persistence")
        XCTAssertTrue(controller.forwards.allSatisfy { $0.state == .off })
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
        XCTAssertEqual(runner.calls(containing: "exit").count, 1)
        XCTAssertTrue(runner.runningMasters.isEmpty)

        // An exit callback that lands after shutdown is not a drop.
        master.simulateExit(code: 255)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(dropped)
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
    }

    func testShutdownNowMarksEverythingOffAndKeepsDesiredState() async {
        // Two machines, so two masters have to be asked to exit. The exit
        // request bypasses the fake runner and runs the real ssh against a
        // socket that does not exist, which fails at once.
        let other = ForwardSpec(machine: "box-b", localPort: 8080)
        controller.setFavourites([Favourite(name: "postgres", spec: postgres), Favourite(name: "web", spec: other)])
        await controller.setForward(id: controller.forwards[0].id, on: true)
        await controller.setForward(id: controller.forwards[1].id, on: true)
        XCTAssertEqual(runner.runningMasters.count, 2)

        let started = Date()
        controller.shutdownNow()

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "well under the 2.5 s cap: the two exits run side by side")
        XCTAssertTrue(controller.forwards.allSatisfy { $0.desiredOn })
        XCTAssertTrue(controller.forwards.allSatisfy { $0.state == .off })
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
        XCTAssertEqual(controller.machineState("box-b"), .disconnected)
    }

    func testScanLeavesPinnedRemotePortsAlone() async {
        await controller.setForward(id: controller.forwards[0].id, on: true)
        runner.script = { args in
            args.contains("--")
                ? ProcessResult(exitCode: 0, stdout: "LISTEN 0 1 127.0.0.1:5432 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:3000 0.0.0.0:*") : nil
        }
        controller.enableAutoHost("prod-db-01")
        await waitUntil { self.controller.forwards(on: "prod-db-01").count == 3 }

        let discovered = controller.forwards(on: "prod-db-01").filter(\.isDiscovered)
        XCTAssertEqual(discovered.map(\.spec.remotePort), [3000], "5432 is pinned, so discovery does not add a second row for it")
        XCTAssertEqual(controller.lastDiscovered["prod-db-01"], [3000])
    }

    func testReopenAllRetriesOnlyMachinesWithSomethingToReopen() async {
        await controller.setForward(id: controller.forwards[0].id, on: true)
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.forwards[0].state == .dropped }

        await controller.reopenAll()

        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
        XCTAssertEqual(controller.forwards[0].state, .active)
        XCTAssertEqual(controller.forwards[1].state, .off, "a forward that was off stays off")
        XCTAssertEqual(runner.launches.count, 2)
    }

    func testRemoveKeepsAFavouriteRowButDropsAnAdHocOne() async {
        let adHoc = ForwardSpec(machine: "prod-db-01", localPort: 7777)
        await controller.addAdHoc(adHoc)
        XCTAssertEqual(controller.forwards.count, 3)

        await controller.remove(id: controller.forwards[0].id)
        await controller.remove(id: controller.forwards.last!.id)

        XCTAssertEqual(controller.forwards.map(\.spec), [postgres, redis], "favourites are switched off, not removed")
        XCTAssertTrue(controller.forwards.allSatisfy { !$0.desiredOn && $0.state == .off })
    }

    func testExclusionsUseTheRemoteNumberEvenWhenTheLocalOneIsOffset() async {
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: "LISTEN 0 1 127.0.0.1:8080 0.0.0.0:*") : nil }
        controller.enableAutoHost("gpu-box", offset: 10000)
        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }
        XCTAssertEqual(controller.forwards(on: "gpu-box").first?.spec, ForwardSpec(machine: "gpu-box", localPort: 18080, remotePort: 8080))

        await controller.excludePort(remotePort: 8080, on: "gpu-box")

        XCTAssertEqual(controller.forwards(on: "gpu-box"), [])
        XCTAssertEqual(controller.autoExcluded["gpu-box"], [8080])
        XCTAssertEqual(runner.calls(containing: "cancel").count, 1)
    }

    func testADiscoveredPortServedLocallyIsMovedToTheOffset() async {
        runner.script = { args in
            args.contains("--")
                ? ProcessResult(exitCode: 0, stdout: "LISTEN 0 1 127.0.0.1:5432 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:3000 0.0.0.0:*") : nil
        }
        controller.localPortProbe = { $0 == 5432 }  // a local database already answers on 5432
        controller.enableAutoHost("gpu-box")
        await waitUntil {
            self.controller.forwards(on: "gpu-box").count == 2 && self.controller.forwards(on: "gpu-box").allSatisfy { $0.state == .active }
        }

        let specs = controller.forwards(on: "gpu-box").map(\.spec).sorted { $0.remotePort < $1.remotePort }
        XCTAssertEqual(
            specs,
            [
                ForwardSpec(machine: "gpu-box", localPort: 13000, remotePort: 3000),
                ForwardSpec(machine: "gpu-box", localPort: 15432, remotePort: 5432),
            ], "the whole machine moves to the offset; 5432 is never bound beside the local service")
        XCTAssertFalse(runner.calls(containing: "forward").contains { $0.arguments.contains("127.0.0.1:5432:localhost:5432") })
    }

    func testPersistedStateCaptureSkipsDiscoveredRows() async {
        await controller.setForward(id: controller.forwards[0].id, on: true)
        await controller.addAdHoc(ForwardSpec(machine: "box-b", localPort: 8080), name: "web")
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: "LISTEN 0 1 127.0.0.1:3000 0.0.0.0:*") : nil }
        controller.enableAutoHost("gpu-box")
        await waitUntil { self.controller.forwards(on: "gpu-box").count == 1 }

        let state = PersistedState.capture(from: controller)

        XCTAssertEqual(state.onForwards.map(\.spec), [postgres, ForwardSpec(machine: "box-b", localPort: 8080)])
        XCTAssertEqual(state.autoHostsOn, ["gpu-box"])
    }
}

@MainActor
final class ReconnectorScheduleTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var reconnector: Reconnector!
    var socketDir: URL!
    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = makeTemporaryDirectory("schedule")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.setFavourites([Favourite(name: "postgres", spec: postgres)])
        reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.05]
        reconnector.debounce = 0.05
        await controller.setForward(id: controller.forwards[0].id, on: true)
    }

    override func tearDown() async throws {
        await controller.shutdown()
        try? FileManager.default.removeItem(at: socketDir)
    }

    func testAttemptsCountUpToTheBudgetWithTheLastDelayRepeated() async {
        reconnector.delays = [0.02, 0.04]
        reconnector.budget = 4
        runner.masterExitsImmediately = (255, "Connection refused")
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil {
            if case .failed = self.controller.machineState("prod-db-01") { return true }
            return false
        }

        // The attempt numbers are transient and a poll can miss one; the launch
        // count proves the budget was used up, and no more.
        XCTAssertEqual(runner.launches.count, 5, "one original launch plus four attempts")
    }

    func testSystemChangeIsDebouncedToOneHealthCheck() async {
        let before = runner.calls(containing: "check").count
        reconnector.systemDidChange()
        reconnector.systemDidChange()
        reconnector.systemDidChange()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(runner.calls(containing: "check").count, before + 1)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
    }

    func testCancelForgetsTheDropSoALaterReconnectIsNotReported() async {
        reconnector.noticeAfter = 0
        var reported = false
        reconnector.onReconnected = { _, _ in reported = true }
        runner.masterConnects = false
        // A long first delay keeps the dropped state observable on a slow runner.
        reconnector.delays = [1.0]
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .dropped(attempt: 1) }

        reconnector.cancel("prod-db-01")
        runner.masterConnects = true
        await controller.retry(alias: "prod-db-01")
        await waitUntil { self.controller.machineState("prod-db-01") == .connected }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(reported)
    }
}

final class FavouritesEdgeCaseTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for url in directories { try? FileManager.default.removeItem(at: url) }
    }

    private func file(_ text: String) -> URL {
        let directory = makeTemporaryDirectory("fav-edge")
        directories.append(directory)
        let url = directory.appendingPathComponent("favourites.toml")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testAddToAFileWithoutTrailingNewlineKeepsBlocksApart() throws {
        let url = file("[[favourite]]\nname = \"a\"\nhost = \"h\"\nport = 1")
        try Favourites.add(Favourite(name: "b", spec: ForwardSpec(machine: "h", localPort: 2)), to: url)
        XCTAssertEqual(try Favourites.load(from: url).map(\.name), ["a", "b"])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("port = 1\n\n[[favourite]]"))
    }

    func testRemovingTheOnlyBlockKeepsTheHeaderComment() throws {
        let url = file("# mine\n\n[[favourite]]\nname = \"a\"\nhost = \"h\"\nport = 1\n")
        XCTAssertTrue(try Favourites.remove(ForwardSpec(machine: "h", localPort: 1), from: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# mine\n")
        XCTAssertEqual(try Favourites.load(from: url), [])
    }

    func testEditingTheLastBlockWithTrailingBlankLines() throws {
        let url = file("[[favourite]]\nname = \"a\"\nhost = \"h\"\nport = 1\n\n\n")
        XCTAssertTrue(try Favourites.rename(ForwardSpec(machine: "h", localPort: 1), to: "renamed", in: url))
        XCTAssertTrue(try Favourites.changePorts(ForwardSpec(machine: "h", localPort: 1), local: 11, remote: 1, in: url))
        let loaded = try Favourites.load(from: url)
        XCTAssertEqual(loaded.map(\.name), ["renamed"])
        XCTAssertEqual(loaded[0].spec, ForwardSpec(machine: "h", localPort: 11, remotePort: 1))
    }

    func testNamesWithQuotesAndBackslashesRoundTrip() throws {
        let url = file("")
        let name = "say \"hi\" \\ back"
        try Favourites.add(Favourite(name: name, spec: ForwardSpec(machine: "h", localPort: 1)), to: url)
        XCTAssertEqual(try Favourites.load(from: url).map(\.name), [name])
        XCTAssertTrue(try Favourites.rename(ForwardSpec(machine: "h", localPort: 1), to: "plain", in: url))
        XCTAssertEqual(try Favourites.load(from: url).map(\.name), ["plain"])
    }

    func testHostAndFavouriteBlocksWithTheSameNameAreEditedIndependently() throws {
        let url = file(
            """
            [[host]]
            name = "box"
            all_ports = true

            [[favourite]]
            name = "box"
            host = "box"
            port = 80

            """)
        XCTAssertTrue(try Favourites.setExcluded([1, 2], forHost: "box", in: url))
        XCTAssertTrue(try Favourites.setOffset(10000, forHost: "box", in: url))
        XCTAssertTrue(try Favourites.remove(ForwardSpec(machine: "box", localPort: 80), from: url))
        let hosts = Favourites.loadHosts(from: url)
        XCTAssertEqual(hosts, [AutoHost(name: "box", excluded: [1, 2], offset: 10000)])
        XCTAssertEqual(try Favourites.load(from: url), [])
        XCTAssertTrue(try Favourites.removeHost("box", from: url))
        XCTAssertEqual(Favourites.loadHosts(from: url), [])
    }

    func testParseHostsEdgeCases() throws {
        let hosts = try Favourites.parseHosts(
            """
            [[host]]
            name = "on"
            exclude = [8080, "x", 9090]

            [[host]]
            name = "off"
            all_ports = false

            [[host]]
            name = "  "
            """)
        XCTAssertEqual(hosts, [AutoHost(name: "on", excluded: [8080, 9090], offset: nil)])
    }

    func testASyntaxErrorHidesEveryHostButLoadStillThrows() {
        let url = file("[[host]]\nname = \"box\"\nall_ports = true\n\n[[favourite]]\nname = \"bad\nhost = \"h\"\nport = 1\n")
        XCTAssertEqual(Favourites.loadHosts(from: url), [], "today: a parse error empties the host list silently")
        XCTAssertThrowsError(try Favourites.load(from: url))
    }
}

final class MiniTOMLEdgeCaseTests: XCTestCase {
    func testEscapesNegativeNumbersAndDuplicateKeys() throws {
        let root = try MiniTOML.parse(
            """
            s = "tab\\there \\"q\\" back\\\\slash"
            n = -5
            dup = 1
            dup = 2
            arr = ["a # not a comment", 'b']   # real comment
            """)
        XCTAssertEqual(root["s"]?.string, "tab\there \"q\" back\\slash")
        XCTAssertEqual(root["n"]?.integer, -5)
        XCTAssertEqual(root["dup"]?.integer, 2, "last value wins")
        XCTAssertEqual(root["arr"], .array([.string("a # not a comment"), .string("b")]))
    }

    func testUnsupportedEscapeIsAnError() {
        XCTAssertThrowsError(try MiniTOML.parse("s = \"bad \\q\""))
    }

    func testCRLFInputParses() throws {
        let root = try MiniTOML.parse("a = 1\r\n[[favourite]]\r\nname = \"x\"\r\n")
        XCTAssertEqual(root["a"]?.integer, 1)
        XCTAssertEqual(root["favourite"]?.tables?.first?["name"]?.string, "x")
    }
}

final class SSHConfigEdgeCaseTests: XCTestCase {
    func testIncludeCyclesStopAtTheDepthLimitAndGlobsExpand() throws {
        let dir = makeTemporaryDirectory("sshconfig-edge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let main = dir.appendingPathComponent("config")
        let confd = dir.appendingPathComponent("conf.d")
        try FileManager.default.createDirectory(at: confd, withIntermediateDirectories: true)
        try "Host one\n".write(to: confd.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "Host two\nInclude \(main.path)\n".write(to: confd.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)
        try "Host home\nInclude \(confd.path)/*.conf\n".write(to: main, atomically: true, encoding: .utf8)

        XCTAssertEqual(SSHConfig.hostAliases(configPath: main.path), ["home", "one", "two"])
    }
}

final class ExternalScannerEdgeCaseTests: XCTestCase {
    func testAttachedOptionValuesAndSchemeTargets() {
        let ps = """
              1   501 ssh -p2222 -L 8080:localhost:80 ssh://user@box:2222
              2   501 ssh -L 9090:localhost:90 10.0.0.5
              3   501 ssh -L [::1]:7070:localhost:70 box
            """
        let found = ExternalScanner.parse(ps, currentUID: 501)
        XCTAssertEqual(found.map(\.pid), [1, 2])
        XCTAssertEqual(
            found[0].spec, ForwardSpec(machine: "box:2222", localPort: 8080, remotePort: 80), "today the port stays glued to the alias")
        XCTAssertEqual(found[1].spec.machine, "?", "today an IP target is not recognised as a host")
    }
}

final class SSHErrorTextMoreTests: XCTestCase {
    func testRemainingMappings() {
        XCTAssertEqual(SSHErrorText.humanize("ssh: connect to host x port 22: Operation timed out"), "Connection timed out")
        XCTAssertEqual(SSHErrorText.humanize("Host key verification failed."), "Host key verification failed")
        XCTAssertEqual(SSHErrorText.humanize("Control socket connect(/x): No such file or directory"), "Connection is gone")
        XCTAssertEqual(SSHErrorText.humanize(""), "ssh failed")
        XCTAssertEqual(SSHErrorText.humanize("line one\nssh: something odd"), "something odd")
        XCTAssertEqual(SSHErrorText.short("Host key verification failed"), "Host key failed")
        XCTAssertEqual(SSHErrorText.short("Connection is gone"), "Disconnected")
        XCTAssertEqual(SSHErrorText.short("ssh exited with status 255"), "ssh exited")
    }
}

final class LocalPortsTests: XCTestCase {
    func testDetectsAListenerOnAnyAddress() throws {
        for host in ["0.0.0.0", "127.0.0.1"] {
            let listener = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(listener) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = inet_addr(host)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0
                }
            }
            XCTAssertTrue(bound)
            XCTAssertEqual(listen(listener, 1), 0)
            let port = Int(UInt16(bigEndian: address.sin_port))

            XCTAssertTrue(LocalPorts.isTaken(port), "listener on \(host):\(port)")
            close(listener)
            XCTAssertFalse(LocalPorts.isTaken(port), "after closing \(host):\(port)")
        }
    }

    func testOutOfRangeIsNotTaken() {
        XCTAssertFalse(LocalPorts.isTaken(0))
        XCTAssertFalse(LocalPorts.isTaken(70000))
    }
}
