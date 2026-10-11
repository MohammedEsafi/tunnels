import Foundation

/// Brings dropped machines back with backoff, and reacts to wake and network
/// changes. Owns no ssh state; it only drives `ForwardController`.
@MainActor
public final class Reconnector {
    public var budget = 5
    public var delays: [TimeInterval] = [2, 4, 8, 16, 30]
    public var debounce: TimeInterval = 3
    /// Alias and reason, fired once per exhausted budget.
    public var onGaveUp: ((String, String) -> Void)?
    /// Alias and how long it was down, fired when a machine comes back on its
    /// own after being down at least `noticeAfter` seconds. Not fired for a
    /// retry the user asked for.
    public var onReconnected: ((String, TimeInterval) -> Void)?
    public var noticeAfter: TimeInterval = 10

    private var droppedSince: [String: Date] = [:]

    private let controller: ForwardController
    private var loops: [String: Task<Void, Never>] = [:]
    private var systemChangeTask: Task<Void, Never>?

    public init(controller: ForwardController) {
        self.controller = controller
        controller.onMasterDropped = { [weak self] alias, _ in
            self?.schedule(alias)
        }
    }

    /// Start (or restart) the backoff loop for a machine.
    public func schedule(_ alias: String) {
        if droppedSince[alias] == nil { droppedSince[alias] = Date() }
        loops[alias]?.cancel()
        loops[alias] = Task { [weak self] in
            await self?.loop(alias)
        }
    }

    /// Skip the wait and try now. If that fails the loop starts over.
    public func retryNow(_ alias: String, userInitiated: Bool = false) {
        loops[alias]?.cancel()
        if userInitiated { droppedSince[alias] = nil }
        loops[alias] = Task { [weak self] in
            guard let self else { return }
            await controller.retry(alias: alias)
            if Task.isCancelled { return }
            if controller.machineState(alias) == .connected {
                loops[alias] = nil
                reportBack(alias)
            } else if controller.isWanted(alias) {
                schedule(alias)
            } else {
                loops[alias] = nil
                droppedSince[alias] = nil
            }
        }
    }

    private func reportBack(_ alias: String) {
        guard let since = droppedSince.removeValue(forKey: alias) else { return }
        let elapsed = Date().timeIntervalSince(since)
        if elapsed >= noticeAfter {
            onReconnected?(alias, elapsed)
        }
    }

    /// Wake from sleep or a network path change. Debounced so a flapping
    /// network does not stack reconnects.
    public func systemDidChange() {
        systemChangeTask?.cancel()
        systemChangeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
            if Task.isCancelled { return }
            // Masters that look connected may be hung after sleep: this drops them,
            // which in turn schedules a loop.
            await controller.healthCheck()
            for alias in controller.machines {
                switch controller.machineState(alias) {
                case .dropped, .failed:
                    retryNow(alias)
                default:
                    continue
                }
            }
        }
    }

    public func cancel(_ alias: String) {
        loops[alias]?.cancel()
        loops[alias] = nil
        droppedSince[alias] = nil
    }

    private func loop(_ alias: String) async {
        var lastReason = "Connection dropped"
        for attempt in 1...max(budget, 1) {
            guard controller.isWanted(alias) else { return }
            controller.markDropped(alias: alias, attempt: attempt)
            let delay = delays.isEmpty ? 0 : delays[min(attempt - 1, delays.count - 1)]
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            await controller.retry(alias: alias)
            if Task.isCancelled { return }
            if controller.machineState(alias) == .connected {
                loops[alias] = nil
                reportBack(alias)
                return
            }
            if case .failed(let reason) = controller.machineState(alias) {
                lastReason = reason
            }
        }
        controller.markFailed(alias: alias, reason: lastReason)
        loops[alias] = nil
        droppedSince[alias] = nil
        onGaveUp?(alias, lastReason)
    }
}
