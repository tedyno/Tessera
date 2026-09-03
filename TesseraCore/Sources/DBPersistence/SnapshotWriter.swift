import Foundation

/// Serializes file writes off the caller's executor, keeping only the newest
/// snapshot: a burst of saves collapses to one write, and an older snapshot can
/// never land after a newer one.
///
/// The caller encodes on its own isolation and submits flat `Data`, so the value
/// graph behind a snapshot never crosses a thread boundary.
public final class SnapshotWriter: @unchecked Sendable {
    /// What is queued. A removal supersedes any snapshot still waiting: once the
    /// file is meant to be gone, writing the bytes that were on their way to it
    /// would only bring it back.
    private enum Pending {
        case snapshot(Data)
        case removal
    }

    private let lock = NSLock()
    private var pending: Pending?
    private var draining = false
    private let write: @Sendable (Data) -> Void
    private let remove: (@Sendable () -> Void)?

    /// `write` performs the actual (synchronous, atomic-replace) file write, and
    /// `remove` deletes what it writes to; both are called serially, off the
    /// caller's executor. Pass `remove` for a file that can also be deleted, so
    /// the deletion queues behind the writes instead of racing them.
    public init(write: @escaping @Sendable (Data) -> Void,
                remove: (@Sendable () -> Void)? = nil) {
        self.write = write
        self.remove = remove
    }

    /// Queues `data` as the newest snapshot, dropping any not-yet-written one.
    public func submit(_ data: Data) {
        enqueue(.snapshot(data))
    }

    /// Queues deletion of the file behind the writes, after everything already
    /// queued. Without this a delete issued alongside the writer would be free to
    /// run first and let a pending write recreate the file.
    public func submitRemoval() {
        guard remove != nil else { return }
        enqueue(.removal)
    }

    private func enqueue(_ next: Pending) {
        let startDrain: Bool = lock.withLock {
            pending = next
            if draining { return false }
            draining = true
            return true
        }
        guard startDrain else { return }
        Task.detached(priority: .utility) { [self] in
            while true {
                let next: Pending? = lock.withLock {
                    let queued = pending
                    pending = nil
                    if queued == nil { draining = false }
                    return queued
                }
                switch next {
                case .snapshot(let data): write(data)
                case .removal: remove?()
                case nil: return
                }
            }
        }
    }
}
