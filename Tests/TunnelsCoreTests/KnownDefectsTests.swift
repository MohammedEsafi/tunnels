import XCTest

@testable import TunnelsCore

/// Regression tests for the defects found in the Phase 1 audit and the Phase 5
/// review, one per defect. Each was written to fail on the code of the time
/// and passed once the fix landed. Numbers refer to the audit report.
@MainActor
final class KnownDefectsTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var socketDir: URL!
    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = makeTemporaryDirectory("defects")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.discoveryInterval = 3600
    }

    override func tearDown() async throws {
        await controller.shutdown()
        try? FileManager.default.removeItem(at: socketDir)
    }

    private func listing(_ ports: [Int]) -> String {
        ports.map { "LISTEN 0 1 127.0.0.1:\($0) 0.0.0.0:*" }.joined(separator: "\n")
    }

    // P0-5
    func testSwitchingOffDuringAScanStaysOff() async {
        let gate = Gate()
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: self.listing([3000])) : nil }
        runner.gate = { args in if args.contains("--") { await gate.wait() } }
        controller.enableAutoHost("gpu-box")
        await waitUntil { gate.arrivals == 1 }

        await controller.setMachine(alias: "gpu-box", on: false)
        gate.open()
        await waitUntil { self.runner.completed(containing: "--").count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(controller.forwards(on: "gpu-box"), [])
        XCTAssertEqual(controller.machineState("gpu-box"), .disconnected)
        XCTAssertTrue(runner.runningMasters.isEmpty)
    }

    // P0-6, first half
    func testSwitchingOffANoServiceForwardCancelsIt() async {
        controller.setFavourites([Favourite(name: "postgres", spec: postgres)])
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: self.listing([9])) : nil }
        await controller.setForward(id: controller.forwards[0].id, on: true)
        XCTAssertEqual(controller.forwards[0].state, .noService)

        await controller.setForward(id: controller.forwards[0].id, on: false)

        XCTAssertEqual(controller.forwards[0].state, .off)
        XCTAssertEqual(runner.calls(containing: "cancel").count, 1)
    }

    // P0-6, second half
    func testSwitchingOffWhileTheForwardIsBeingAddedLeavesItOff() async {
        controller.setFavourites([Favourite(name: "postgres", spec: postgres)])
        let gate = Gate()
        runner.gate = { args in if args.contains("forward") { await gate.wait() } }
        let id = controller.forwards[0].id
        Task { await self.controller.setForward(id: id, on: true) }
        await waitUntil { gate.arrivals == 1 }

        await controller.setForward(id: id, on: false)
        gate.open()
        await waitUntil { self.runner.completed(containing: "forward").count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(controller.forwards[0].desiredOn)
        XCTAssertEqual(controller.forwards[0].state, .off)
        XCTAssertTrue(runner.runningMasters.isEmpty, "nothing is wanted, so the master and its forward are gone")
    }

    // P0-7
    func testMasterStillStartingWhenSwitchedOffIsNotKept() async {
        controller.setFavourites([Favourite(name: "postgres", spec: postgres)])
        runner.masterConnects = false
        let id = controller.forwards[0].id
        Task { await self.controller.setForward(id: id, on: true) }
        await waitUntil { self.runner.launches.count == 1 }

        await controller.setForward(id: id, on: false)
        runner.masterConnects = true
        await waitUntil { self.runner.calls(containing: "exit").count == 1 }

        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
        XCTAssertTrue(runner.runningMasters.isEmpty)
    }

    // P0-8
    func testPlainRetryDoesNotWriteIntoAnotherRow() async {
        let moved = ForwardSpec(machine: "prod-db-01", localPort: 15432, remotePort: 5432)
        controller.setFavourites([Favourite(name: "pg", spec: moved, movedByApp: true)])
        await controller.setForward(id: controller.forwards[0].id, on: true)
        // The pin becomes an ad-hoc row behind a new favourite, so it can be removed mid-flight.
        controller.setFavourites([Favourite(name: "other", spec: ForwardSpec(machine: "prod-db-01", localPort: 1111))])
        let pinID = controller.forwards[1].id
        let gate = Gate()
        runner.gate = { args in if args.contains("127.0.0.1:5432:localhost:5432") { await gate.wait() } }
        Task { await self.controller.setMachine(alias: "prod-db-01", on: true) }
        await waitUntil { gate.arrivals == 1 }

        await controller.remove(id: pinID)
        let third = ForwardSpec(machine: "prod-db-01", localPort: 7777)
        await controller.addAdHoc(third)
        gate.open()
        await waitUntil { self.runner.completed(containing: "127.0.0.1:5432:localhost:5432").count >= 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(controller.forwards.contains { $0.spec == third }, "\(controller.forwards.map(\.spec))")
    }

    // P1-1 and P1-2: after a drop the reconnector brings a watched machine back; scans wait for it.
    func testDiscoveredRowsComeBackThroughTheReconnectorAndScansDoNotRace() async {
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: self.listing([3000])) : nil }
        controller.enableAutoHost("gpu-box")
        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.2]

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .dropped }
        await controller.scan("gpu-box")
        XCTAssertEqual(runner.launches.count, 1, "a scan while dropped does not reconnect on its own")

        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }
        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(controller.machineState("gpu-box"), .connected)
    }

    func testAWatchedMachineThatCannotConnectGoesThroughTheBackoffAndGivesUp() async {
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.02]
        reconnector.budget = 2
        var gaveUp: String?
        reconnector.onGaveUp = { alias, _ in gaveUp = alias }
        runner.masterExitsImmediately = (255, "ssh: connect to host gpu-box port 22: Connection refused")

        controller.enableAutoHost("gpu-box")
        await waitUntil { gaveUp != nil }

        XCTAssertEqual(controller.machineState("gpu-box"), .failed(reason: "Host unreachable"))
        XCTAssertEqual(runner.launches.count, 3, "the first try plus two attempts, then nothing")
        await controller.scan("gpu-box")
        XCTAssertEqual(runner.launches.count, 3, "a failed machine is left to a manual retry")
    }

    // Review finding 1: a scan tick during a reconnector attempt joined the same
    // start, saw the same error and rescheduled the loop at attempt 1 forever.
    func testAWatchedUnreachableMachineGivesUpEvenWhileScansKeepTicking() async {
        controller.discoveryInterval = 0.05
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.02]
        reconnector.budget = 2
        var gaveUp: String?
        reconnector.onGaveUp = { alias, _ in gaveUp = alias }
        runner.masterExitsImmediately = (255, "ssh: connect to host gpu-box port 22: Connection refused")

        controller.enableAutoHost("gpu-box")
        await waitUntil(timeout: 3) { gaveUp != nil }

        XCTAssertEqual(runner.launches.count, 3, "the first try plus two attempts; scans must not restart the count")
        XCTAssertEqual(controller.machineState("gpu-box"), .failed(reason: "Host unreachable"))
    }

    // Review finding 3: after the reconnector gave up, All Ports again did nothing
    // because the machine stayed .failed and scans skip failed machines.
    func testAllPortsAgainAfterGivingUpReconnects() async {
        let reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.02]
        reconnector.budget = 1
        runner.masterExitsImmediately = (255, "Connection refused")
        controller.enableAutoHost("gpu-box")
        await waitUntil { if case .failed = self.controller.machineState("gpu-box") { return true } else { return false } }

        runner.masterExitsImmediately = nil
        runner.script = { args in args.contains("--") ? ProcessResult(exitCode: 0, stdout: self.listing([3000])) : nil }
        // What "All Ports" from the machine's menu does.
        await controller.disableAutoHost("gpu-box")
        controller.enableAutoHost("gpu-box")

        await waitUntil { self.controller.forwards(on: "gpu-box").first?.state == .active }
        XCTAssertEqual(controller.machineState("gpu-box"), .connected)
    }

    // Review finding 2: tryPlain rewrote the row and marked it active after the
    // user had switched it off while the plain add was in flight.
    func testPlainRetrySwitchedOffMidAddStaysOff() async {
        let moved = ForwardSpec(machine: "prod-db-01", localPort: 15432, remotePort: 5432)
        controller.setFavourites([Favourite(name: "pg", spec: moved, movedByApp: true)])
        let id = controller.forwards[0].id
        let gate = Gate()
        runner.gate = { args in if args.contains("127.0.0.1:5432:localhost:5432") { await gate.wait() } }
        Task { await self.controller.setMachine(alias: "prod-db-01", on: true) }
        await waitUntil { gate.arrivals == 1 }

        await controller.setForward(id: id, on: false)
        gate.open()
        await waitUntil { self.runner.completed(containing: "forward").count == 1 }
        try? await Task.sleep(nanoseconds: 50_000_000)

        let row = controller.forwards[0]
        XCTAssertFalse(row.desiredOn)
        XCTAssertEqual(row.state, .off)
        XCTAssertEqual(row.spec, moved, "a cancelled retry does not change the row's number")
        XCTAssertTrue(runner.runningMasters.isEmpty)
    }

    // P1-5
    func testRemoteRefusalIsNotReportedAsLocalPortInUse() {
        XCTAssertEqual(SSHErrorText.humanize("remote port forwarding failed for listen port 80"), "Remote end refused the forward")
    }

    // P1-6
    func testNetstatFallbackIgnoresUDPAndNonListeningSockets() {
        let netstat = """
            Active Internet connections (including servers)
            Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
            tcp4       0      0  127.0.0.1.5432         *.*                    LISTEN
            tcp4       0      0  10.0.0.5.3000          10.0.0.9.51234         SYN_SENT
            udp4       0      0  *.5353                 *.*
            """
        XCTAssertEqual(PortDiscovery.parse(netstat), [5432])
    }
}
