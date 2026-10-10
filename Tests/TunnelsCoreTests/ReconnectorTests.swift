import XCTest
@testable import TunnelsCore

@MainActor
final class ReconnectorTests: XCTestCase {
    var runner: FakeRunner!
    var controller: ForwardController!
    var reconnector: Reconnector!
    let postgres = ForwardSpec(machine: "prod-db-01", localPort: 5432)

    override func setUp() async throws {
        runner = FakeRunner()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recon-\(UUID().uuidString)")
        controller = ForwardController(runner: runner, socketDirectory: dir)
        controller.setFavourites([(postgres, "postgres")])
        reconnector = Reconnector(controller: controller)
        reconnector.delays = [0.05]
        reconnector.debounce = 0.05
        await controller.setForward(id: controller.forwards[0].id, on: true)
        XCTAssertEqual(controller.machineState("prod-db-01"), .connected)
    }

    func testMasterExitTriggersReconnect() async {
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .connected && self.runner.launches.count == 2 }

        XCTAssertEqual(runner.launches.count, 2)
        XCTAssertEqual(controller.forwards[0].state, .active)
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
        reconnector.delays = [0.3]
        runner.runningMasters.first?.simulateExit(code: 255)
        await waitUntil { self.controller.machineState("prod-db-01") == .dropped(attempt: 1) }

        await controller.setForward(id: controller.forwards[0].id, on: false)
        try? await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(runner.launches.count, 1)
        XCTAssertEqual(controller.machineState("prod-db-01"), .disconnected)
    }

    func testSystemChangeDropsHungMasterAndReconnects() async {
        // The master process is "running" but -O check stops answering.
        runner.script = { args in
            if args.contains("check") && self.runner.launches.count == 1 {
                return ProcessResult(exitCode: 255, stderr: "Control socket connect: Connection refused")
            }
            return ProcessResult(exitCode: 0)
        }
        reconnector.systemDidChange()
        await waitUntil { self.runner.launches.count == 2 && self.controller.machineState("prod-db-01") == .connected }

        XCTAssertEqual(controller.forwards[0].state, .active)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met within \(timeout)s")
    }
}
