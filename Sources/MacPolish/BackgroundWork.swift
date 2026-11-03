import Foundation

/// Runs blocking work (child processes, filesystem walks, deadline polling) on GCD.
/// Swift concurrency's thread pool has one thread per core; blocking it with `Thread.sleep` or
/// `waitUntilExit` delays every other task. GCD adds threads when its workers block.
enum BackgroundWork {
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async { continuation.resume(returning: work()) }
        }
    }
}
