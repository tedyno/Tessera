import XCTest
@testable import DBKit

/// The status bar shows one job out of possibly several and a single progress bar,
/// so which job that is — and what the bar reads — is the logic worth pinning down.
final class BackgroundJobsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func job(_ name: String, startedAfter seconds: TimeInterval,
                     progress: Double? = nil,
                     state: BackgroundJob.State = .running,
                     finishedAfter: TimeInterval? = nil) -> BackgroundJob {
        BackgroundJob(title: name, progress: progress, state: state,
                      startedAt: epoch.addingTimeInterval(seconds),
                      finishedAt: finishedAfter.map { epoch.addingTimeInterval($0) })
    }

    // MARK: Ordering and headline

    func testJobsAreOrderedOldestFirstHoweverTheyArrive() {
        var list = BackgroundJobList()
        list.upsert(job("second", startedAfter: 20))
        list.upsert(job("first", startedAfter: 10))
        list.upsert(job("third", startedAfter: 30))
        XCTAssertEqual(list.jobs.map(\.title), ["first", "second", "third"])
    }

    func testHeadlineIsTheLongestRunningJob() {
        var list = BackgroundJobList()
        list.upsert(job("older", startedAfter: 10))
        list.upsert(job("newer", startedAfter: 20))
        XCTAssertEqual(list.headline?.title, "older")
    }

    /// A job starting must not yank the indicator onto it — that is the whole point
    /// of picking the oldest.
    func testHeadlineDoesNotMoveWhenAnotherJobStarts() {
        var list = BackgroundJobList()
        list.upsert(job("running", startedAfter: 10))
        let before = list.headline?.title
        list.upsert(job("just started", startedAfter: 50))
        XCTAssertEqual(list.headline?.title, before)
    }

    func testHeadlineFallsBackToTheMostRecentlyFinishedWhenNothingRuns() {
        var list = BackgroundJobList()
        list.upsert(job("early", startedAfter: 10, state: .succeeded, finishedAfter: 15))
        list.upsert(job("late", startedAfter: 12, state: .failed("boom"), finishedAfter: 40))
        XCTAssertEqual(list.headline?.title, "late")
    }

    func testHeadlineIsNilForAnEmptyList() {
        XCTAssertNil(BackgroundJobList().headline)
    }

    // MARK: Progress

    func testOverallProgressAveragesTheRunningJobs() {
        var list = BackgroundJobList()
        list.upsert(job("a", startedAfter: 10, progress: 0.25))
        list.upsert(job("b", startedAfter: 20, progress: 0.75))
        XCTAssertEqual(list.overallProgress ?? -1, 0.5, accuracy: 0.0001)
    }

    /// One job that can't report makes the total unknowable; the bar has to go
    /// indeterminate rather than average over a guess.
    func testOverallProgressIsUnknownIfAnyRunningJobIsIndeterminate() {
        var list = BackgroundJobList()
        list.upsert(job("known", startedAfter: 10, progress: 0.5))
        list.upsert(job("unknown", startedAfter: 20))
        XCTAssertNil(list.overallProgress)
    }

    /// Finished jobs are still listed, but they must not drag the bar backwards.
    func testOverallProgressIgnoresFinishedJobs() {
        var list = BackgroundJobList()
        list.upsert(job("done", startedAfter: 10, progress: 0.1, state: .succeeded, finishedAfter: 12))
        list.upsert(job("live", startedAfter: 20, progress: 0.8))
        XCTAssertEqual(list.overallProgress ?? -1, 0.8, accuracy: 0.0001)
    }

    func testOverallProgressIsNilWithNothingRunning() {
        var list = BackgroundJobList()
        list.upsert(job("done", startedAfter: 10, progress: 1, state: .succeeded, finishedAfter: 12))
        XCTAssertNil(list.overallProgress)
    }

    func testProgressIsClampedToTheUnitRange() {
        XCTAssertEqual(BackgroundJob(title: "a", progress: 4.2, startedAt: epoch).progress, 1)
        XCTAssertEqual(BackgroundJob(title: "b", progress: -1, startedAt: epoch).progress, 0)
    }

    // MARK: Updating

    func testUpsertReplacesInPlaceWithoutReordering() {
        var list = BackgroundJobList()
        let first = job("first", startedAfter: 10)
        list.upsert(first)
        list.upsert(job("second", startedAfter: 20))

        var updated = first
        updated.detail = "half way"
        list.upsert(updated)

        XCTAssertEqual(list.jobs.map(\.title), ["first", "second"])
        XCTAssertEqual(list.jobs.first?.detail, "half way")
        XCTAssertEqual(list.jobs.count, 2)
    }

    func testRunningCountAndFailureFlag() {
        var list = BackgroundJobList()
        list.upsert(job("a", startedAfter: 10))
        list.upsert(job("b", startedAfter: 20, state: .succeeded, finishedAfter: 25))
        XCTAssertEqual(list.runningCount, 1)
        XCTAssertFalse(list.hasFailure)

        list.upsert(job("c", startedAfter: 30, state: .failed("nope"), finishedAfter: 31))
        XCTAssertTrue(list.hasFailure)
        XCTAssertEqual(list.runningCount, 1)
    }

    // MARK: Pruning

    func testPruneDropsSettledJobsPastTheirWelcomeButKeepsFailures() {
        var list = BackgroundJobList()
        list.upsert(job("running", startedAfter: 10))
        list.upsert(job("just done", startedAfter: 10, state: .succeeded, finishedAfter: 98))
        list.upsert(job("long done", startedAfter: 10, state: .succeeded, finishedAfter: 50))
        list.upsert(job("stopped", startedAfter: 10, state: .cancelled, finishedAfter: 50))
        list.upsert(job("broken", startedAfter: 10, state: .failed("boom"), finishedAfter: 50))

        list.prune(now: epoch.addingTimeInterval(100), succeededFor: 5)

        XCTAssertEqual(Set(list.jobs.map(\.title)), ["running", "just done", "broken"])
    }
}
