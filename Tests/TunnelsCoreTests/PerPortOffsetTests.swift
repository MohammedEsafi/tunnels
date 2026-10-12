import XCTest

@testable import TunnelsCore

/// The offset rule in all-ports mode: a port whose plain local number is
/// taken moves to the machine's offset and is remembered; every other port
/// keeps its own number.
@MainActor
final class PerPortOffsetTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var socketDir: URL!
    var moves: [(alias: String, ports: Set<Int>, offset: Int)] = []

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = makeTemporaryDirectory("offsets")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.discoveryInterval = 3600
        moves = []
        controller.onPortsMoved = { [self] alias, ports, offset in moves.append((alias, ports, offset)) }
    }

    override func tearDown() async throws {
        await controller.shutdown()
        try? FileManager.default.removeItem(at: socketDir)
    }

    private func listing(_ ports: [Int]) -> String {
        ports.map { "LISTEN 0 1 127.0.0.1:\($0) 0.0.0.0:*" }.joined(separator: "\n")
    }

    private func serve(_ ports: [Int], on alias: String = "gpu-box") {
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: self.listing(ports)) : nil }
    }

    private func localPorts(_ alias: String = "gpu-box") -> [Int] {
        controller.forwards(on: alias).map(\.spec.localPort).sorted()
    }

    private func plainForwardWasTried(_ port: Int) -> Bool {
        runner.calls(containing: "forward").contains { $0.arguments.contains("127.0.0.1:\(port):localhost:\(port)") }
    }

    private func waitForRows(_ count: Int, on alias: String = "gpu-box") async {
        await waitUntil {
            self.controller.forwards(on: alias).count == count && self.controller.forwards(on: alias).allSatisfy { $0.state == .active }
        }
    }

    // MARK: Which ports move

    func testAPortTakenByALocalProgramMovesAloneWithoutTryingThePlainNumber() async {
        serve([3302, 5000, 7000])
        controller.localPortProbe = { $0 == 5000 || $0 == 7000 }  // AirPlay on a Mac
        controller.enableAutoHost("gpu-box")
        await waitForRows(3)

        XCTAssertEqual(localPorts(), [3302, 15000, 17000])
        XCTAssertFalse(plainForwardWasTried(5000))
        XCTAssertFalse(plainForwardWasTried(7000))
        XCTAssertTrue(plainForwardWasTried(3302))
        XCTAssertEqual(controller.movedPorts["gpu-box"], [5000, 7000])
        XCTAssertEqual(controller.offsets["gpu-box"], 10000)
    }

    func testAPortSshCannotBindMovesAlone() async {
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: self.listing([8080, 8081])) }
            if args.contains("forward"), args.contains("127.0.0.1:8080:localhost:8080") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:8080: Address already in use")
            }
            return nil
        }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)

        XCTAssertEqual(localPorts(), [8081, 18080])
        XCTAssertTrue(plainForwardWasTried(8080), "the plain number is tried first; the bind failure is what moves it")
        XCTAssertEqual(controller.movedPorts["gpu-box"], [8080])
    }

    func testTwoMachinesSharingPortsOnlyMoveTheSharedOnes() async {
        var listings = ["box-a": [8080, 8081], "box-b": [8080, 8081, 9999]]
        runner.script = { args in
            guard args.contains("--"), let alias = args.first(where: { listings[$0] != nil }) else { return nil }
            return ProcessResult(exitCode: 0, stdout: self.listing(listings[alias]!))
        }
        controller.enableAutoHost("box-a")
        await waitForRows(2, on: "box-a")
        controller.enableAutoHost("box-b")
        await waitForRows(3, on: "box-b")

        XCTAssertEqual(localPorts("box-a"), [8080, 8081], "the first machine keeps its numbers")
        XCTAssertEqual(localPorts("box-b"), [9999, 18080, 18081], "only the shared ports move on the second")
        XCTAssertNil(controller.offsets["box-a"])
        XCTAssertEqual(controller.offsets["box-b"], 10000)
        listings["box-b"] = [8080, 8081, 9999, 3000]
        await controller.scan("box-b")
        XCTAssertEqual(localPorts("box-b"), [3000, 9999, 18080, 18081], "a port that appears later and is free stays plain")
    }

    func testEachMachineGetsItsOwnOffset() async {
        serve([5000])
        controller.localPortProbe = { $0 == 5000 }
        controller.enableAutoHost("box-a")
        await waitForRows(1, on: "box-a")
        controller.enableAutoHost("box-b")
        await waitForRows(1, on: "box-b")

        XCTAssertEqual(localPorts("box-a"), [15000])
        XCTAssertEqual(localPorts("box-b"), [25000])
        XCTAssertEqual(controller.offsets["box-a"], 10000)
        XCTAssertEqual(controller.offsets["box-b"], 20000)
    }

    // MARK: Remembering

    func testRememberedMovesAreUsedDirectlyAndNeverRetried() async {
        serve([8080, 8081])
        controller.enableAutoHost("gpu-box", offset: 10000, moved: [8081])
        await waitForRows(2)

        XCTAssertEqual(localPorts(), [8080, 18081])
        XCTAssertFalse(plainForwardWasTried(8081))
        XCTAssertTrue(moves.isEmpty, "nothing new moved, so nothing is reported")
    }

    func testAMovedPortStaysMovedWhenItsPlainNumberBecomesFree() async {
        serve([5000, 5001])
        var taken: Set<Int> = [5000]
        controller.localPortProbe = { taken.contains($0) }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)
        XCTAssertEqual(localPorts(), [5001, 15000])

        taken = []
        await controller.scan("gpu-box")
        await controller.scan("gpu-box")

        XCTAssertEqual(localPorts(), [5001, 15000], "a free plain number does not pull a moved port back on its own")
        XCTAssertEqual(moves.count, 1)
    }

    func testAMovedPortSurvivesAReconnect() async {
        serve([5000, 5001])
        controller.localPortProbe = { $0 == 5000 }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.05]

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.runner.launches.count == 2 && self.controller.forwards(on: "gpu-box").allSatisfy { $0.state == .active } }

        XCTAssertEqual(localPorts(), [5001, 15000])
        XCTAssertEqual(controller.movedPorts["gpu-box"], [5000])
        XCTAssertEqual(moves.count, 1, "a reconnect re-adds the same forwards; it is not a new move")
    }

    // MARK: Starting afresh

    func testManualSwitchOnRetriesPlainNumbersAndMovesOnlyWhatIsStillTaken() async {
        serve([5000, 7000])
        var taken: Set<Int> = [5000, 7000]
        controller.localPortProbe = { taken.contains($0) }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)
        XCTAssertEqual(localPorts(), [15000, 17000])

        taken = [7000]
        await controller.setMachine(alias: "gpu-box", on: true)
        await controller.scan("gpu-box")

        XCTAssertEqual(localPorts(), [5000, 17000])
        XCTAssertEqual(controller.movedPorts["gpu-box"], [7000])
        XCTAssertEqual(moves.last?.ports, [7000])
    }

    func testForgetMovesClearsTheOffsetAndTheSet() async {
        serve([5000])
        controller.localPortProbe = { $0 == 5000 }
        controller.enableAutoHost("gpu-box")
        await waitForRows(1)

        controller.forgetMoves("gpu-box")

        XCTAssertNil(controller.offsets["gpu-box"])
        XCTAssertNil(controller.movedPorts["gpu-box"])
    }

    // MARK: Reporting

    func testOnePassReportsItsMovesOnceWithTheOffset() async {
        serve([5000, 7000, 3302])
        controller.localPortProbe = { $0 == 5000 || $0 == 7000 }
        controller.enableAutoHost("gpu-box")
        await waitForRows(3)

        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves.first?.alias, "gpu-box")
        XCTAssertEqual(moves.first?.ports, [5000, 7000])
        XCTAssertEqual(moves.first?.offset, 10000)

        await controller.scan("gpu-box")
        XCTAssertEqual(moves.count, 1, "later scans do not report moves that already happened")
    }

    func testAPortTakenDuringADropMovesAfterTheReconnectAndIsReportedAlone() async {
        serve([5000, 3302])
        var taken: Set<Int> = [5000]
        controller.localPortProbe = { taken.contains($0) }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)
        XCTAssertEqual(moves.map(\.ports), [[5000]])

        // While the connection is down a local program grabs 3302, so the
        // reconnect cannot bind the plain number again.
        taken = [5000, 3302]
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: self.listing([5000, 3302])) }
            if args.contains("forward"), args.contains("127.0.0.1:3302:localhost:3302") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:3302: Address already in use")
            }
            return nil
        }
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.05]
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.runner.launches.count == 2 && self.controller.machineState("gpu-box") == .connected }
        await controller.scan("gpu-box")

        XCTAssertEqual(localPorts(), [13302, 15000])
        XCTAssertEqual(controller.movedPorts["gpu-box"], [3302, 5000])
        XCTAssertEqual(moves.map(\.ports), [[5000], [3302]], "only the newly moved port is reported")
        XCTAssertEqual(moves.last?.offset, 10000, "the machine's offset is reused")
    }

    // MARK: Pinned forwards share the offset

    func testAPinnedMoveAndADiscoveredMoveShareTheMachineOffset() async {
        controller.setFavourites([Favourite(name: "postgres", spec: ForwardSpec(machine: "gpu-box", localPort: 5432))])
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: self.listing([5432, 5000, 3302])) }
            if args.contains("forward"), args.contains("127.0.0.1:5432:localhost:5432") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:5432: Address already in use")
            }
            return nil
        }
        controller.localPortProbe = { $0 == 5000 }
        await controller.setForward(id: controller.forwards[0].id, on: true)
        XCTAssertEqual(controller.forwards[0].spec.localPort, 15432)
        XCTAssertEqual(moves.map(\.ports), [[5432]])

        controller.enableAutoHost("gpu-box")
        await waitUntil {
            self.controller.forwards(on: "gpu-box").count == 3 && self.controller.forwards(on: "gpu-box").allSatisfy { $0.state == .active }
        }

        XCTAssertEqual(localPorts(), [3302, 15000, 15432], "5432 is pinned so discovery skips it; 5000 moves on the same +10000")
        XCTAssertEqual(moves.map(\.ports), [[5432], [5000]])
        XCTAssertTrue(moves.allSatisfy { $0.offset == 10000 })
    }

    // MARK: Exclusions and the moved set

    func testExcludingAMovedPortClosesItAndKeepsTheRestInPlace() async {
        serve([5000, 3302])
        controller.localPortProbe = { $0 == 5000 }
        controller.enableAutoHost("gpu-box")
        await waitForRows(2)

        await controller.excludePort(remotePort: 5000, on: "gpu-box")
        await controller.scan("gpu-box")

        XCTAssertEqual(localPorts(), [3302])
        XCTAssertEqual(controller.autoExcluded["gpu-box"], [5000])
        XCTAssertTrue(runner.calls(containing: "cancel").contains { $0.arguments.contains("127.0.0.1:15000:localhost:5000") })
    }

    // MARK: The file

    func testTheHostEntryRemembersMovedPorts() throws {
        let dir = makeTemporaryDirectory("moved-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("favourites.toml")
        try Favourites.addHost(AutoHost(name: "gpu-box"), to: url)

        XCTAssertTrue(try Favourites.setOffset(10000, forHost: "gpu-box", in: url))
        XCTAssertTrue(try Favourites.setMoved([7000, 5000], forHost: "gpu-box", in: url))
        XCTAssertEqual(Favourites.loadHosts(from: url), [AutoHost(name: "gpu-box", excluded: [], offset: 10000, moved: [5000, 7000])])
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("moved = [5000, 7000]"))

        XCTAssertTrue(try Favourites.setExcluded([9999], forHost: "gpu-box", in: url))
        XCTAssertEqual(Favourites.loadHosts(from: url).first?.moved, [5000, 7000], "other keys leave the moved list alone")

        XCTAssertTrue(try Favourites.setMoved([], forHost: "gpu-box", in: url))
        XCTAssertEqual(Favourites.loadHosts(from: url).first?.moved, [])
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("moved"))
        XCTAssertEqual(try Favourites.parseHosts("[[host]]\nname = \"x\"\nmoved = [1, \"two\", 3]\n").first?.moved, [1, 3])
    }
}
