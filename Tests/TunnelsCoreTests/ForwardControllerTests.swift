import XCTest

@testable import TunnelsCore

@MainActor
final class ForwardControllerTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var socketDir: URL!

    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)
    let redis = ForwardSpec(machine: "prod-db-01", localPort: 6379)

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = FileManager.default.temporaryDirectory.appendingPathComponent("tunnels-tests-\(UUID().uuidString)")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.setFavourites([Favourite(name: "postgres", spec: postgres), Favourite(name: "redis", spec: redis)])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: socketDir)
    }

    func id(_ spec: ForwardSpec) -> Forward.ID {
        controller.forwards.first { $0.spec == spec }!.id
    }

    func testTurningOnStartsMasterAndAddsForward() async {
        await controller.setForward(id: id(postgres), on: true)

        XCTAssertEqual(runner.runningMasters.count, 1)
        let launch = runner.calls.first { $0.arguments.contains("-M") }
        XCTAssertNotNil(launch)
        XCTAssertEqual(launch?.executable, "/usr/bin/ssh")
        XCTAssertEqual(launch?.arguments.first, "-N")
        XCTAssertEqual(launch?.arguments.last, "prod-db-01")
        XCTAssertTrue(launch!.arguments.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(launch!.arguments.contains("BatchMode=yes"))

        let forward = runner.calls(containing: "forward").first
        XCTAssertEqual(forward?.arguments.suffix(4), ["forward", "-L", "127.0.0.1:5432:localhost:5432", "prod-db-01"])

        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
        XCTAssertEqual(controller.forwards.first { $0.spec == postgres }?.state, .active)
        XCTAssertEqual(controller.forwards.filter { $0.state == .active || $0.state == .noService }.count, 1)
    }

    func testSecondForwardReusesMaster() async {
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(runner.calls(containing: "forward").count, 2)
        XCTAssertEqual(controller.forwards.filter { $0.state == .active || $0.state == .noService }.count, 2)
    }

    func testForwardFailureMarksOnlyThatForward() async {
        runner.script = { args in
            if args.contains("forward") && args.contains("127.0.0.1:6379:localhost:6379") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:6379: Address already in use")
            }
            return nil
        }
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        XCTAssertEqual(controller.forwards.first { $0.spec == postgres }?.state, .active)
        // A taken port no longer stays red: the forward moves by the machine's offset.
        let movedRedis = controller.forwards.first { $0.name == "redis" }
        XCTAssertEqual(movedRedis?.spec, ForwardSpec(machine: "prod-db-01", localPort: 16379, remotePort: 6379))
        XCTAssertEqual(movedRedis?.state, .active)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
    }

    func testTurningOffLastForwardStopsMaster() async {
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)
        await controller.setForward(id: id(postgres), on: false)

        XCTAssertEqual(runner.calls(containing: "cancel").count, 1)
        XCTAssertEqual(runner.calls(containing: "exit").count, 0)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)

        await controller.setForward(id: id(redis), on: false)

        XCTAssertEqual(runner.calls(containing: "exit").count, 1)
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
        XCTAssertTrue(controller.forwards.allSatisfy { $0.state == .off })
    }

    func testMasterExitMarksForwardsDroppedAndRetryReopens() async {
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        var droppedAlias: String?
        controller.onMasterDropped = { alias, _ in droppedAlias = alias }

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { droppedAlias != nil }

        XCTAssertEqual(droppedAlias, "prod-db-01")
        XCTAssertEqual(controller.machineState("prod-db-01"), .dropped(attempt: 1))
        XCTAssertEqual(controller.forwards.filter { $0.state == .dropped }.count, 2)
        XCTAssertTrue(controller.forwards.allSatisfy { $0.desiredOn })

        await controller.retry(alias: "prod-db-01")

        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
        XCTAssertEqual(controller.forwards.filter { $0.state == .active || $0.state == .noService }.count, 2)
    }

    func testMasterStartFailureMarksMachineFailed() async {
        runner.masterExitsImmediately = (255, "user@prod-db-01: Permission denied (publickey).")
        await controller.setForward(id: id(postgres), on: true)

        XCTAssertEqual(controller.machineState("prod-db-01"), .failed(reason: "No usable key in the agent. Run ssh-add."))
        XCTAssertEqual(controller.forwards.first { $0.spec == postgres }?.state, .dropped)
        XCTAssertTrue(controller.forwards.first { $0.spec == postgres }!.desiredOn)
    }

    func testMachineSwitchOffClosesEverything() async {
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)
        await controller.setMachine(alias: "prod-db-01", on: false)

        XCTAssertEqual(runner.calls(containing: "exit").count, 1)
        XCTAssertFalse(runner.runningMasters.contains { $0.isRunning })
        XCTAssertTrue(controller.forwards.allSatisfy { !$0.desiredOn && $0.state == .off })
    }

    func testAdHocForwardIsAddedAndRemoved() async {
        let spec = ForwardSpec(machine: "dev-box", localPort: 3000)
        let id = await controller.addAdHoc(spec)

        XCTAssertEqual(controller.forwards.count, 3)
        XCTAssertEqual(controller.forwards.first { $0.id == id }?.state, .active)
        XCTAssertEqual(controller.forwards.first { $0.id == id }?.name, "3000")

        await controller.remove(id: id)
        XCTAssertEqual(controller.forwards.count, 2)
        XCTAssertEqual(controller.machineState("dev-box"), .disconnected)
        XCTAssertFalse(controller.machines.contains("dev-box"))
    }

    func testRunningForwardSurvivesLosingFavouriteStatus() async {
        await controller.setForward(id: id(postgres), on: true)
        controller.setFavourites([Favourite(name: "redis", spec: redis)])

        let kept = controller.forwards.first { $0.spec == postgres }
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.isFavourite, false)
        XCTAssertEqual(kept?.state, .active)

        controller.setFavourites([Favourite(name: "redis", spec: redis), Favourite(name: "pg", spec: postgres)])
        let again = controller.forwards.first { $0.spec == postgres }
        XCTAssertEqual(again?.isFavourite, true)
        XCTAssertEqual(again?.name, "pg")
        XCTAssertEqual(again?.state, .active)
    }

    func testProbeMarksForwardsWithNothingBehindThem() async {
        var listeners = "LISTEN 0 1 127.0.0.1:5432 0.0.0.0:*"
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: listeners) }
            return nil
        }
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        XCTAssertEqual(controller.forwards.first { $0.spec == postgres }?.state, .active)
        XCTAssertEqual(controller.forwards.first { $0.spec == redis }?.state, .noService)
        XCTAssertEqual(controller.forwards.filter { $0.state == .active || $0.state == .noService }.count, 2)

        listeners = "LISTEN 0 1 127.0.0.1:5432 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:6379 0.0.0.0:*"
        await controller.healthCheck()
        XCTAssertEqual(controller.forwards.first { $0.spec == redis }?.state, .active)

        // No tool answered on the remote: leave states alone.
        listeners = ""
        await controller.healthCheck()
        XCTAssertEqual(controller.forwards.first { $0.spec == redis }?.state, .active)
    }

    func testCloseAllStopsWatchingAndMasters() async {
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: "LISTEN 0 1 127.0.0.1:3000 0.0.0.0:*") }
            return nil
        }
        controller.discoveryInterval = 3600
        await controller.setForward(id: id(postgres), on: true)
        controller.enableAutoHost("gpu-box")
        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }
        XCTAssertTrue(controller.anyDesired)

        await controller.closeAll()

        XCTAssertFalse(controller.anyDesired)
        XCTAssertFalse(controller.forwards.contains { $0.desiredOn })
        XCTAssertTrue(controller.autoHosts.isEmpty, "Close All also stops all-ports watching")
        XCTAssertEqual(controller.machineState("gpu-box"), .disconnected)
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
        XCTAssertTrue(runner.runningMasters.isEmpty)
    }

    func testAllPortsDiscoversAddsAndRemoves() async {
        var listeners = "LISTEN 0 1 127.0.0.1:3000 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:5173 0.0.0.0:*\nLISTEN 0 1 0.0.0.0:22 0.0.0.0:*"
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: listeners) }
            return nil
        }
        controller.discoveryInterval = 3600
        controller.enableAutoHost("gpu-box", excluded: [5173])
        // The loop scans once right away; wait for it rather than racing it.
        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }

        XCTAssertEqual(controller.machineState("gpu-box"), .connected)
        let discovered = controller.forwards(on: "gpu-box")
        XCTAssertEqual(discovered.map(\.spec.localPort), [3000])
        XCTAssertTrue(discovered.allSatisfy { $0.isDiscovered && $0.state == .active })
        XCTAssertTrue(controller.machines.contains("gpu-box"))

        listeners = "LISTEN 0 1 127.0.0.1:8080 0.0.0.0:*"
        await controller.scan("gpu-box")
        XCTAssertEqual(controller.forwards(on: "gpu-box").map(\.spec.localPort), [8080])
        XCTAssertEqual(runner.calls(containing: "cancel").count, 1)

        await controller.excludePort(remotePort: 8080, on: "gpu-box")
        XCTAssertEqual(controller.forwards(on: "gpu-box"), [])
        await controller.scan("gpu-box")
        XCTAssertEqual(controller.forwards(on: "gpu-box"), [])

        XCTAssertEqual(controller.lastDiscovered["gpu-box"], [])
        listeners = "LISTEN 0 1 127.0.0.1:3000 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:4000 0.0.0.0:*"
        await controller.scan("gpu-box")
        XCTAssertEqual(controller.lastDiscovered["gpu-box"], [3000, 4000])
        await controller.excludePort(remotePort: 4000, on: "gpu-box")
        XCTAssertEqual(controller.lastDiscovered["gpu-box"], [3000])

        await controller.disableAutoHost("gpu-box")
        XCTAssertEqual(controller.lastDiscovered["gpu-box"], [3000], "kept after switching off, for Pinned only")
        XCTAssertFalse(controller.autoHosts.contains("gpu-box"))
        XCTAssertEqual(controller.machineState("gpu-box"), .disconnected)
        XCTAssertEqual(runner.calls(containing: "exit").count, 1)
    }

    func testOnlyClashingDiscoveredPortsMoveAndEachMachineGetsItsOwnOffset() async {
        // box-a already holds 8080 and 7777 locally; box-b offers the same plus 9999.
        let listeners = "LISTEN 0 1 127.0.0.1:7777 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:8080 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:9999 0.0.0.0:*"
        let takenLocally: Set<String> = ["127.0.0.1:7777:localhost:7777", "127.0.0.1:8080:localhost:8080"]
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: listeners) }
            if args.contains("forward"), let spec = args.last(where: { $0.contains(":") }), takenLocally.contains(spec) {
                return ProcessResult(exitCode: 255, stderr: "mux_client_forward: forwarding request failed: Port forwarding failed")
            }
            return nil
        }
        var moved: [(String, Set<Int>, Int)] = []
        controller.onPortsMoved = { moved.append(($0, $1, $2)) }
        controller.discoveryInterval = 3600
        controller.enableAutoHost("box-b")
        await waitUntil {
            self.controller.forwards(on: "box-b").count >= 3 && self.controller.forwards(on: "box-b").allSatisfy { $0.state == .active }
        }

        let rows = controller.forwards(on: "box-b").sorted { $0.spec.remotePort < $1.spec.remotePort }
        // The two taken ports move; 9999 keeps its own number.
        XCTAssertEqual(rows.map(\.spec.localPort), [17777, 18080, 9999])
        XCTAssertEqual(rows.map(\.spec.remotePort), [7777, 8080, 9999])
        XCTAssertEqual(controller.offsets["box-b"], 10000)
        XCTAssertEqual(controller.movedPorts["box-b"], [7777, 8080])
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved.first?.1, [7777, 8080])
        XCTAssertEqual(moved.first?.2, 10000)

        // A second scan changes nothing and reports nothing.
        await controller.scan("box-b")
        XCTAssertEqual(controller.forwards(on: "box-b").map(\.spec.localPort).sorted(), [9999, 17777, 18080])
        XCTAssertEqual(moved.count, 1)

        // Another machine with the same clashes gets the next offset for its moved ports only.
        controller.enableAutoHost("box-c")
        await waitUntil {
            self.controller.forwards(on: "box-c").count >= 3 && self.controller.forwards(on: "box-c").allSatisfy { $0.state == .active }
        }
        XCTAssertEqual(controller.offsets["box-c"], 20000)
        // 9999 is taken by box-b's plain forward now, so on box-c all three move.
        XCTAssertEqual(controller.forwards(on: "box-c").map(\.spec.localPort).sorted(), [27777, 28080, 29999])
    }

    func testPinnedForwardMovesWhenItsPortIsTaken() async {
        runner.script = { args in
            if args.contains("forward"), args.contains("127.0.0.1:5432:localhost:5432") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:5432: Address already in use")
            }
            return nil
        }
        var moved: (ForwardSpec, ForwardSpec)?
        controller.onForwardMoved = { moved = ($0, $1) }
        await controller.setForward(id: id(postgres), on: true)

        let row = controller.forwards.first { $0.name == "postgres" }
        XCTAssertEqual(row?.spec, ForwardSpec(machine: "prod-db-01", localPort: 15432, remotePort: 5432))
        XCTAssertEqual(row?.state, .active)
        XCTAssertEqual(controller.offsets["prod-db-01"], 10000)
        XCTAssertEqual(moved?.0, postgres)
        XCTAssertEqual(moved?.1.localPort, 15432)
    }

    func testManualSwitchOnTriesPlainNumberForMovedPins() async {
        var taken: Set<String> = ["127.0.0.1:5432:localhost:5432"]
        runner.script = { args in
            if args.contains("forward"), let spec = args.last(where: { $0.contains(":") }), taken.contains(spec) {
                return ProcessResult(exitCode: 255, stderr: "bind: Address already in use")
            }
            return nil
        }
        var moves: [(ForwardSpec, ForwardSpec)] = []
        controller.onForwardMoved = { moves.append(($0, $1)) }
        await controller.setForward(id: id(postgres), on: true)
        XCTAssertEqual(controller.forwards.first { $0.name == "postgres" }?.spec.localPort, 15432)
        XCTAssertTrue(controller.forwards.first { $0.name == "postgres" }!.movedByApp)

        // Still taken: switching the machine off and on keeps the moved number.
        await controller.setMachine(alias: "prod-db-01", on: false)
        await controller.setMachine(alias: "prod-db-01", on: true)
        XCTAssertEqual(controller.forwards.first { $0.name == "postgres" }?.spec.localPort, 15432)
        XCTAssertEqual(controller.forwards.first { $0.name == "postgres" }?.state, .active)

        // Freed: a manual switch-on goes back to plain and reports the move.
        taken = []
        await controller.setMachine(alias: "prod-db-01", on: false)
        await controller.setMachine(alias: "prod-db-01", on: true)
        let row = controller.forwards.first { $0.name == "postgres" }
        XCTAssertEqual(row?.spec, postgres)
        XCTAssertEqual(row?.state, .active)
        XCTAssertFalse(row!.movedByApp)
        XCTAssertEqual(moves.last?.1, postgres)
    }

    func testScanPutsRowsOnTheOffsetExactlyWhenTheyAreInTheMovedSet() async {
        let listeners = "LISTEN 0 1 127.0.0.1:8080 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:8081 0.0.0.0:*"
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: listeners) }
            return nil
        }
        controller.discoveryInterval = 3600
        // Started plain, no clashes.
        controller.enableAutoHost("box-a")
        await waitUntil { self.controller.forwards(on: "box-a").count >= 2 }
        XCTAssertEqual(controller.forwards(on: "box-a").map(\.spec.localPort).sorted(), [8080, 8081])

        // A restart from file says 8081 had moved: only that one lands on the offset.
        await controller.disableAutoHost("box-a")
        let plainAttemptsBefore = runner.calls(containing: "forward").filter { $0.arguments.contains("127.0.0.1:8081:localhost:8081") }
            .count
        controller.enableAutoHost("box-a", offset: 10000, moved: [8081])
        await waitUntil {
            self.controller.forwards(on: "box-a").count >= 2 && self.controller.forwards(on: "box-a").allSatisfy { $0.state == .active }
        }
        XCTAssertEqual(controller.forwards(on: "box-a").map(\.spec.localPort).sorted(), [8080, 18081])
        let plainAttemptsAfter = runner.calls(containing: "forward").filter { $0.arguments.contains("127.0.0.1:8081:localhost:8081") }.count
        XCTAssertEqual(plainAttemptsAfter, plainAttemptsBefore, "a remembered move never tries the plain number")

        // Forgetting the moves puts 8081 back on its own number at the next scan.
        controller.forgetMoves("box-a")
        await controller.scan("box-a")
        XCTAssertEqual(controller.forwards(on: "box-a").map(\.spec.localPort).sorted(), [8080, 8081])
        XCTAssertTrue(runner.calls(containing: "cancel").contains { $0.arguments.contains("127.0.0.1:18081:localhost:8081") })
    }

    func testAllPortsRemoveEachThenDisableAndEnableAgain() async {
        let listeners = "LISTEN 0 1 127.0.0.1:7777 0.0.0.0:*\nLISTEN 0 1 127.0.0.1:8080 0.0.0.0:*"
        runner.script = { args in
            if args.contains("--") { return ProcessResult(exitCode: 0, stdout: listeners) }
            return nil
        }
        controller.discoveryInterval = 3600
        controller.enableAutoHost("box-b")
        await waitUntil { self.controller.forwards(on: "box-b").count >= 2 }
        XCTAssertEqual(controller.forwards(on: "box-b").map(\.spec.localPort), [7777, 8080])

        // × on each discovered row
        await controller.excludePort(remotePort: 7777, on: "box-b")
        await controller.excludePort(remotePort: 8080, on: "box-b")
        XCTAssertEqual(controller.forwards(on: "box-b"), [])
        XCTAssertEqual(controller.autoExcluded["box-b"], [7777, 8080])

        // host switch off, then on again choosing all ports (the app passes the
        // exclusions it has on file, here none)
        await controller.setMachine(alias: "box-b", on: false)
        XCTAssertFalse(controller.autoHosts.contains("box-b"))
        controller.enableAutoHost("box-b", excluded: [])
        let deadline2 = Date().addingTimeInterval(5)
        while Date() < deadline2, controller.forwards(on: "box-b").count < 2 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.forwards(on: "box-b").map(\.spec.localPort), [7777, 8080], "ports should come back after re-enabling")
    }

    func testSocketPathIsShortAndStable() {
        let dir = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Tunnels/sockets")
        let a = SSHMaster.socketPath(for: "a-very-long-host-alias.example.internal", in: dir)
        let b = SSHMaster.socketPath(for: "a-very-long-host-alias.example.internal", in: dir)
        XCTAssertEqual(a, b)
        XCTAssertLessThan(a.utf8.count, 104)
        XCTAssertEqual(URL(fileURLWithPath: a).lastPathComponent.count, 12)
    }
}

final class SSHErrorTextTests: XCTestCase {
    func testCommonMessages() {
        XCTAssertEqual(SSHErrorText.humanize("x@y: Permission denied (publickey,password)."), "No usable key in the agent. Run ssh-add.")
        XCTAssertEqual(SSHErrorText.humanize("ssh: Could not resolve hostname nope: nodename nor servname provided"), "Unknown host")
        XCTAssertEqual(SSHErrorText.humanize("bind [127.0.0.1]:5432: Address already in use"), "Local port in use")
        XCTAssertEqual(
            SSHErrorText.humanize(
                "mux_client_forward: forwarding request failed: Port forwarding failed\nmuxclient: master forward request failed"),
            "Local port in use")
        XCTAssertEqual(SSHErrorText.humanize("ssh: connect to host 10.0.0.9 port 22: Connection refused"), "Host unreachable")
        XCTAssertEqual(SSHErrorText.humanize("something odd\nssh: last line here"), "last line here")
    }

    func testShortForms() {
        XCTAssertEqual(SSHErrorText.short("Timed out waiting for the connection"), "Timed out")
        XCTAssertEqual(SSHErrorText.short("No usable key in the agent. Run ssh-add."), "No key in agent")
        XCTAssertEqual(SSHErrorText.short("Local port in use"), "Port in use")
        XCTAssertEqual(SSHErrorText.short("Host unreachable"), "Unreachable")
        XCTAssertEqual(SSHErrorText.short("some very long unexpected ssh message here"), "some very long…")
        XCTAssertEqual(SSHErrorText.short("odd thing"), "odd thing")
    }
}
