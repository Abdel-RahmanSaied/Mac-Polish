import Foundation

private final class Latency: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = .infinity
    func set(_ newValue: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = newValue }
    var seconds: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
}

/// Scans, `du`, Docker and `ps` block a thread while they wait for a child process.
/// That waiting must not occupy Swift concurrency's fixed-size thread pool.
@main
enum BackgroundWorkCheck {
    static func main() async {
        let jobs = ProcessInfo.processInfo.activeProcessorCount * 2
        let probe = Latency()
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<jobs {
                group.addTask { _ = await BackgroundWork.run { Thread.sleep(forTimeInterval: 1); return 0 } }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                let probeStart = Date()
                await Task.detached { }.value
                probe.set(Date().timeIntervalSince(probeStart))
            }
        }
        let total = Date().timeIntervalSince(started)
        // Break caught: blocking jobs queue behind each other on the pool (≥ 2 s here) and starve other tasks.
        precondition(total < 1.6, "\(jobs) one-second blocking jobs took \(total) s; they must not queue on the pool")
        precondition(probe.seconds < 0.3, "Other async work waited \(probe.seconds) s behind blocking jobs")

        // Break caught: fanning scan sections out with concurrentPerform, which never runs more than one
        // thread per core, so stalled sections hold every thread and the rest wait in waves.
        let fanStart = Date()
        let order = DiskScanService.concurrentMap(Array(0..<jobs)) { index in Thread.sleep(forTimeInterval: 1); return index }
        let fanTotal = Date().timeIntervalSince(fanStart)
        precondition(order == Array(0..<jobs), "Results keep their input order")
        precondition(fanTotal < 1.6, "\(jobs) one-second blocking sections took \(fanTotal) s; they must all overlap")
        print("PASS: \(jobs) blocking jobs ran together in \(String(format: "%.2f", total)) s and \(String(format: "%.2f", fanTotal)) s; other tasks kept running")
    }
}
