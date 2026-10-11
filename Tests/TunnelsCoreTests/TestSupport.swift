import Foundation
import XCTest

/// Poll until `condition` holds; fail the test if it never does.
@MainActor
func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping @MainActor () -> Bool)
    async
{
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("condition not met within \(timeout)s", file: file, line: line)
}

/// A fresh directory under the temporary directory, named for the caller.
func makeTemporaryDirectory(_ prefix: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Holds callers until opened. Used with `FakeRunner.gate` to freeze an ssh
/// control command mid-flight while the test changes something else.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalCount = 0
    var arrivals: Int { lock.withLock { arrivalCount } }

    func wait() async {
        let alreadyOpen: Bool = lock.withLock {
            arrivalCount += 1
            return opened
        }
        if alreadyOpen { return }
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if opened { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func open() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            opened = true
            let waiting = waiters
            waiters = []
            return waiting
        }
        for waiter in pending { waiter.resume() }
    }
}
