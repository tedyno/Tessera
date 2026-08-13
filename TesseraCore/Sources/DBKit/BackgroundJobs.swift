import Foundation

/// One long-running piece of work the app is doing off to the side — an export, a
/// dump, a restore. Purely a description of state: what runs it, and how it is
/// cancelled, stays in the app layer.
public struct BackgroundJob: Identifiable, Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        case succeeded
        case failed(String)
        case cancelled

        public var isRunning: Bool { self == .running }
    }

    public let id: UUID
    /// One line naming the work, e.g. "Export orders.csv".
    public var title: String
    /// Running detail under the title, e.g. "1 240 000 rows · 84 MB". Already
    /// formatted by the caller, which owns the localization.
    public var detail: String?
    /// 0…1 when the total is known, nil while it isn't — plenty of work here can
    /// only say how much it has done, not how much is left.
    public var progress: Double?
    public var state: State
    public var startedAt: Date
    public var finishedAt: Date?
    /// Whether the app can actually stop this one; a job that can't must not offer.
    public var isCancellable: Bool
    /// The file this job reads or writes, so the list can show it in Finder — the
    /// question right after "is it done?" is nearly always "where did it go?".
    public var fileURL: URL?

    public init(id: UUID = UUID(), title: String, detail: String? = nil,
                progress: Double? = nil, state: State = .running,
                startedAt: Date, finishedAt: Date? = nil, isCancellable: Bool = false,
                fileURL: URL? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.progress = progress.map { min(max($0, 0), 1) }
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.isCancellable = isCancellable
        self.fileURL = fileURL
    }
}

/// The set of background jobs, ordered oldest first, with the decisions the status
/// bar needs: which single job the collapsed indicator stands for, how much of the
/// whole is done, and when a finished entry has outstayed its welcome.
public struct BackgroundJobList: Sendable, Equatable {
    public private(set) var jobs: [BackgroundJob] = []

    public init(jobs: [BackgroundJob] = []) {
        self.jobs = jobs.sorted { $0.startedAt < $1.startedAt }
    }

    public var isEmpty: Bool { jobs.isEmpty }
    public var running: [BackgroundJob] { jobs.filter { $0.state.isRunning } }
    public var runningCount: Int { running.count }
    public var hasFailure: Bool { jobs.contains { if case .failed = $0.state { true } else { false } } }

    /// The job the collapsed indicator represents: the longest-running one, so it
    /// doesn't hop to a different job every time another starts. With nothing
    /// running it falls back to the most recently finished, which is what the user
    /// just watched and may want the outcome of.
    public var headline: BackgroundJob? {
        running.first ?? jobs.max { lhs, rhs in
            (lhs.finishedAt ?? lhs.startedAt) < (rhs.finishedAt ?? rhs.startedAt)
        }
    }

    /// Mean progress across running jobs, or nil if any of them can't say — one
    /// unknown makes the total unknown, and a bar that pretends otherwise lies.
    public var overallProgress: Double? {
        let active = running
        guard !active.isEmpty else { return nil }
        var total = 0.0
        for job in active {
            guard let progress = job.progress else { return nil }
            total += progress
        }
        return total / Double(active.count)
    }

    /// Adds a job, or replaces the one with the same id in place — the list stays in
    /// start order, so a progress update never reshuffles what the user is reading.
    public mutating func upsert(_ job: BackgroundJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
            jobs.sort { $0.startedAt < $1.startedAt }
        }
    }

    public mutating func remove(id: UUID) {
        jobs.removeAll { $0.id == id }
    }

    /// Drops finished jobs that have been sitting there for `succeededFor`. Failures
    /// are kept: they carry a message nobody has read yet, and they go away when the
    /// user dismisses them.
    public mutating func prune(now: Date, succeededFor: TimeInterval = 5) {
        jobs.removeAll { job in
            switch job.state {
            case .running, .failed: false
            case .succeeded, .cancelled:
                now.timeIntervalSince(job.finishedAt ?? job.startedAt) >= succeededFor
            }
        }
    }
}
