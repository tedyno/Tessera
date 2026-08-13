import Foundation
import Observation
import DBKit

/// The app's register of long-running side work — exports, dumps, restores — behind
/// the status bar's task indicator. The list itself (ordering, which job to show,
/// overall progress, when a finished one disappears) is `BackgroundJobList` in Core;
/// this owns the running side of it: the cancel handlers and the timers.
@MainActor
@Observable
final class BackgroundJobsModel {
    private(set) var list = BackgroundJobList()

    /// How each job is stopped. Kept out of the value model so that stays testable
    /// and `Sendable`.
    @ObservationIgnored private var cancellers: [UUID: @MainActor () -> Void] = [:]
    /// Pending prune timers, so a finished job's row disappears on its own rather
    /// than waiting for the next unrelated update.
    @ObservationIgnored private var pruneTasks: [UUID: Task<Void, Never>] = [:]

    /// How long a job that ended well stays on screen. Long enough to read, short
    /// enough that the indicator isn't permanently occupied by old news.
    private static let settledLinger: TimeInterval = 5

    /// Registers a started job. `onCancel` makes it stoppable; without one the row
    /// shows no Stop, because offering one that does nothing is worse than none.
    @discardableResult
    func start(title: String, detail: String? = nil, progress: Double? = nil,
               fileURL: URL? = nil, onCancel: (@MainActor () -> Void)? = nil) -> UUID {
        let job = BackgroundJob(title: title, detail: detail, progress: progress,
                                startedAt: Date(), isCancellable: onCancel != nil,
                                fileURL: fileURL)
        cancellers[job.id] = onCancel
        list.upsert(job)
        return job.id
    }

    /// Updates a running job. Fields left nil keep their current value, so a caller
    /// can report just the detail line without knowing the fraction.
    func update(_ id: UUID, detail: String? = nil, progress: Double? = nil) {
        guard var job = list.jobs.first(where: { $0.id == id }), job.state.isRunning else { return }
        if let detail { job.detail = detail }
        if let progress { job.progress = min(max(progress, 0), 1) }
        list.upsert(job)
    }

    func finish(_ id: UUID, state: BackgroundJob.State, detail: String? = nil) {
        guard var job = list.jobs.first(where: { $0.id == id }) else { return }
        job.state = state
        job.finishedAt = Date()
        job.progress = state == .succeeded ? 1 : job.progress
        if let detail { job.detail = detail }
        list.upsert(job)
        cancellers[id] = nil
        schedulePrune(id)
    }

    /// Stops a job. The job itself reports the outcome when it unwinds — marking it
    /// cancelled here would race with work that is still finishing.
    func cancel(_ id: UUID) {
        cancellers[id]?()
    }

    /// Removes a row the user dismissed (a failure they have read).
    func dismiss(_ id: UUID) {
        pruneTasks[id]?.cancel()
        pruneTasks[id] = nil
        cancellers[id] = nil
        list.remove(id: id)
    }

    func dismissFinished() {
        for job in list.jobs where !job.state.isRunning { dismiss(job.id) }
    }

    private func schedulePrune(_ id: UUID) {
        pruneTasks[id]?.cancel()
        pruneTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settledLinger))
            guard !Task.isCancelled, let self else { return }
            list.prune(now: Date(), succeededFor: Self.settledLinger)
            pruneTasks[id] = nil
        }
    }
}
