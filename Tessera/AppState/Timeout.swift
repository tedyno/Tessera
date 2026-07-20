import Foundation

/// Thrown when an operation outlives its deadline.
struct OperationTimeout: Error {}

/// Races `work` against a timer and returns whichever finishes first, so a network
/// call that never answers fails cleanly instead of hanging.
///
/// The losing task is cancelled, but a library that ignores cancellation may keep
/// running; callers that hold a resource (an SSH tunnel, a driver) must still tear
/// it down themselves.
func withTimeout<T: Sendable>(
    _ limit: Duration,
    _ work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw OperationTimeout()
        }
        guard let result = try await group.next() else { throw OperationTimeout() }
        group.cancelAll()
        return result
    }
}
