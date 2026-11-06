import Foundation

/// What a scanner page shows, derived from its state alone so every page treats the same situation the same way.
/// Earlier results are never hidden by a later failure or cancellation: the page keeps them and adds a notice.
enum ModulePresentation: Equatable {
    /// Never scanned (for example, waiting for the permission review).
    case notScanned
    /// First scan running; nothing to show yet.
    case loading
    /// Scanning again; the earlier results stay visible.
    case refreshing
    /// Finished and found nothing.
    case empty
    /// Finished with results.
    case results
    /// Finished with results, but some locations were not read; `notice` says which.
    case partial(String)
    /// Failed with nothing to show.
    case failed(String)
    /// Failed; the earlier results are shown with this notice.
    case failedWithResults(String)
    /// Cancelled with nothing to show.
    case cancelled
    /// Cancelled; the earlier results are shown and marked as not refreshed.
    case cancelledWithResults

    static func of(_ state: ModuleState, hasResults: Bool, warning: String? = nil) -> Self {
        switch state {
        case .idle: return hasResults ? .results : .notScanned
        case .loading: return hasResults ? .refreshing : .loading
        case .ready:
            if !hasResults { return .empty }
            return warning.map { .partial($0) } ?? .results
        case .failed(let message): return hasResults ? .failedWithResults(message) : .failed(message)
        case .cancelled: return hasResults ? .cancelledWithResults : .cancelled
        }
    }

    /// The same mapping for the basic scan, which has its own state type.
    static func of(_ state: ScanState, hasResults: Bool, warning: String? = nil) -> Self {
        switch state {
        case .idle: return hasResults ? .results : .notScanned
        case .scanning: return hasResults ? .refreshing : .loading
        case .cleaning, .finished:
            if !hasResults { return .empty }
            return warning.map { .partial($0) } ?? .results
        case .failed(let message): return hasResults ? .failedWithResults(message) : .failed(message)
        case .cancelled: return hasResults ? .cancelledWithResults : .cancelled
        }
    }

    /// The rows are on screen (possibly with a notice above them).
    var showsResults: Bool {
        switch self {
        case .refreshing, .results, .partial, .failedWithResults, .cancelledWithResults: true
        default: false
        }
    }

    /// A one-line notice to show above the results, or nil.
    var notice: String? {
        switch self {
        case .refreshing: "Scanning again. The results below are from the previous scan."
        case .partial(let warning): warning
        case .failedWithResults(let message): "The latest scan did not finish: \(message) The results below are from the previous scan."
        case .cancelledWithResults: "The latest scan was cancelled. The results below are from the previous scan."
        default: nil
        }
    }
}
