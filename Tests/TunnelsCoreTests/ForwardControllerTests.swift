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
        controller = ForwardController(runner: runner, socketDirectory: socketDir)
        controller.setFavourites([(postgres, "postgres"), (redis, "redis")])
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
        XCTAssertEqual(controller.activeCount, 1)
    }

    func testSecondForwardReusesMaster() async {
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(runner.calls(containing: "forward").count, 2)
        XCTAssertEqual(controller.activeCount, 2)
    }

    func testForwardFailureMarksOnlyThatForward() async {
        runner.script = { args in
            if args.contains("forward") && args.contains("127.0.0.1:6379:localhost:6379") {
                return ProcessResult(exitCode: 255, stderr: "bind [127.0.0.1]:6379: Address already in use")
            }
            return ProcessResult(exitCode: 0)
        }
        await controller.setForward(id: id(postgres), on: true)
        await controller.setForward(id: id(redis), on: true)

        XCTAssertEqual(controller.forwards.first { $0.spec == postgres }?.state, .active)
        XCTAssertEqual(controller.forwards.first { $0.spec == redis }?.state, .error("Local port in use"))
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
        // Exit is delivered through the actor and the main actor; give it a moment.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(droppedAlias, "prod-db-01")
        XCTAssertEqual(controller.machineState("prod-db-01"), .dropped(attempt: 1))
        XCTAssertEqual(controller.droppedCount, 2)
        XCTAssertTrue(controller.forwards.allSatisfy { $0.desiredOn })

        await controller.retry(alias: "prod-db-01")

        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
        XCTAssertEqual(controller.activeCount, 2)
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
        controller.setFavourites([(redis, "redis")])

        let kept = controller.forwards.first { $0.spec == postgres }
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept?.isFavourite, false)
        XCTAssertEqual(kept?.state, .active)

        controller.setFavourites([(redis, "redis"), (postgres, "pg")])
        let again = controller.forwards.first { $0.spec == postgres }
        XCTAssertEqual(again?.isFavourite, true)
        XCTAssertEqual(again?.name, "pg")
        XCTAssertEqual(again?.state, .active)
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
