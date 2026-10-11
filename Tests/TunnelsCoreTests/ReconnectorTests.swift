import XCTest

@testable import TunnelsCore

@MainActor
final class ReconnectorTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var reconnector: Reconnector!
    var socketDir: URL!
    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)

    override func setUp() async throws {
        runner = FakeRunner()
        socketDir = makeTemporaryDirectory("recon")
        controller = ForwardController(runner: runner, options: SSHOptions(socketDirectory: socketDir))
        controller.localPortProbe = { _ in false }
        controller.setFavourites([Favourite(name: "postgres", spec: postgres)])
        reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.05]
        reconnector.debounce = 0.05
        await controller.setForward(id: controller.forwards[0].id, on: true)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: socketDir)
    }

    func testMasterExitTriggersReconnect() async {
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .connected && self.runner.launches.count == 2 }

        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(controller.forwards[0].state, .active)
    }

    func testReportsBackAfterANoticeableDrop() async {
        reconnector.noticeAfter = 0
        var back: (String, TimeInterval)?
        reconnector.onReconnected = { back = ($0, $1) }

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { back != nil }

        XCTAssertEqual(back?.0, "prod-db-01")
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
    }

    func testShortDropIsNotReported() async {
        reconnector.noticeAfter = 60
        var reported = false
        reconnector.onReconnected = { _, _ in reported = true }

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .connected && self.runner.launches.count == 2 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(reported)
    }

    func testUserRetryIsNotReported() async {
        reconnector.noticeAfter = 0
        reconnector.budget = 1
        var reported = false
        reconnector.onReconnected = { _, _ in reported = true }
        runner.masterExitsImmediately = (255, "Connection refused")
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { if case .failed = self.controller.machineState("prod-db-01") { return true } else { return false } }

        runner.masterExitsImmediately = nil
        reconnector.retryNow("prod-db-01", userInitiated: true)
        await waitUntil { self.controller.machineState("prod-db-01") == .connected }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(reported)
    }

    func testGivesUpAfterBudget() async {
        reconnector.budget = 3
        var gaveUp: (String, String)?
        reconnector.onGaveUp = { gaveUp = ($0, $1) }
        runner.masterExitsImmediately = (255, "ssh: connect to host 10.0.0.9 port 22: Connection refused")

        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { if case .failed = self.controller.machineState("prod-db-01") { return true } else { return false } }

        XCTAssertEqual(controller.machineState("prod-db-01"), .failed(reason: "Host unreachable"))
        XCTAssertEqual(gaveUp?.0, "prod-db-01")
        XCTAssertEqual(gaveUp?.1, "Host unreachable")
        // 1 original launch + 3 attempts
        XCTAssertEqual(runner.launches.count, 4)
        XCTAssertEqual(controller.forwards[0].state, .dropped)
        XCTAssertTrue(controller.forwards[0].desiredOn)
    }

    func testRetryNowAfterFailureReconnects() async {
        reconnector.budget = 1
        runner.masterExitsImmediately = (255, "Connection refused")
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { if case .failed = self.controller.machineState("prod-db-01") { return true } else { return false } }

        runner.masterExitsImmediately = nil
        reconnector.retryNow("prod-db-01")
        await waitUntil { self.controller.machineState("prod-db-01") == .connected }

        XCTAssertEqual(controller.forwards[0].state, .active)
    }

    func testTurningOffStopsTheLoop() async {
        // A whole second before the first attempt, so the dropped state is
        // observable even on a slow, loaded runner.
        reconnector.delays = [1.0]
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .dropped(attempt: 1) }

        await controller.setForward(id: controller.forwards[0].id, on: false)
        // Longer than the delay: a loop that survived would have launched again.
        try? await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
    }

    func testSystemChangeDropsHungMasterAndReconnects() async {
        // The master process is "running" but -O check stops answering.
        runner.script = { args in
            if args.contains("check") && self.runner.launches.count == 1 {
                return ProcessResult(exitCode: 255, stderr: "Control socket connect: Connection refused")
            }
            return nil
        }
        reconnector.systemDidChange()
        await waitUntil { self.runner.launches.count == 2 && self.controller.machineState("prod-db-01") == .connected }

        XCTAssertEqual(controller.forwards[0].state, .active)
    }
}
