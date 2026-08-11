import Foundation

/// Coalescing, ordered background writer for snapshot files.
///
/// Each store used to spawn an independent detached task per save; two rapid
/// saves of the same file then raced, and an older snapshot could atomically
/// replace a newer one. `submit` instead remembers only the newest snapshot and
/// a single drain task writes until nothing newer is pending — so the file
/// always ends at the latest submitted state, and bursts collapse into at most
/// one write per snapshot generation.
public final class SnapshotWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Data?
    private var draining = false
    private let write: @Sendable (Data) -> Void

    /// `write` performs the actual (synchronous, atomic-replace) file write; it
    /// is called serially, off the caller's executor.
    public init(write: @escaping @Sendable (Data) -> Void) {
        self.write = write
    }

    /// Queues `data` as the newest snapshot, dropping any not-yet-written one.
    public func submit(_ data: Data) {
        let startDrain: Bool = lock.withLock {
            pending = data
            if draining { return false }
            draining = true
            return true
        }
        guard startDrain else { return }
        Task.detached(priority: .utility) { [self] in
            while true {
                let next: Data? = lock.withLock {
                    let data = pending
                    pending = nil
                    if data == nil { draining = false }
                    return data
                }
                guard let next else { return }
                write(next)
            }
        }
    }
}
