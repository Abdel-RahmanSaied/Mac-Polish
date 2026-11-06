import Darwin
import Foundation

/// Stops one group of scan work. Worker processes started for the group are ended within a poll interval,
/// and work that has not started yet never starts. Safe to use from any thread.
final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    init() {}

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// A token that is never cancelled, for callers without a cancel button.
    static let none = ScanCancellation()
}

/// Every child process the app starts for scanning, so quitting the app ends them instead of leaving them to run
/// out their time limits. (Workers also exit by themselves if the app disappears; see `ScanWorker`.)
final class WorkerProcesses: @unchecked Sendable {
    static let shared = WorkerProcesses()
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    func track(_ process: Process) {
        lock.lock(); running[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func untrack(_ process: Process) {
        lock.lock(); running[ObjectIdentifier(process)] = nil; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return running.count
    }

    /// Ends every tracked process: a polite terminate, then SIGKILL for any still running shortly after.
    func terminateAll(grace: TimeInterval = 0.5) {
        lock.lock(); let processes = Array(running.values); lock.unlock()
        for process in processes where process.isRunning { process.terminate() }
        let deadline = DispatchTime.now() + grace
        while processes.contains(where: \.isRunning) && DispatchTime.now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}

/// One module's current run: starting a run cancels the previous one, and results from a run that is no longer
/// current are dropped, so a slow cancelled scan can never overwrite a newer one.
@MainActor
struct ScanRunTracker {
    private(set) var current: (id: UUID, cancellation: ScanCancellation)?

    var isRunning: Bool { current != nil }

    mutating func begin() -> (id: UUID, cancellation: ScanCancellation) {
        current?.cancellation.cancel()
        let run = (id: UUID(), cancellation: ScanCancellation())
        current = run
        return run
    }

    func isCurrent(_ id: UUID) -> Bool { current?.id == id }

    /// Ends the run if it is still current; returns false when the result belongs to an older run.
    mutating func finish(_ id: UUID) -> Bool {
        guard isCurrent(id) else { return false }
        current = nil
        return true
    }

    /// Cancels the current run; returns true when one was running.
    @discardableResult
    mutating func cancel() -> Bool {
        guard let run = current else { return false }
        run.cancellation.cancel()
        current = nil
        return true
    }
}
