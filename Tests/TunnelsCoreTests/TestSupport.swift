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
    private(set) var arrivals = 0

    func wait() async {
        lock.lock()
        arrivals += 1
        if opened { lock.unlock(); return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }
}
