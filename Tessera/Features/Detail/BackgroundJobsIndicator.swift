import SwiftUI
import DBKit

/// The status bar's background-work indicator: one line for whatever is running,
/// clickable for the full list. Absent entirely when nothing is going on, so the
/// bar stays quiet in the common case.
struct BackgroundJobsIndicator: View {
    let jobs: BackgroundJobsModel
    @State private var showingList = false

    var body: some View {
        if let headline = jobs.list.headline {
            Button { showingList = true } label: {
                HStack(spacing: 6) {
                    JobProgressBar(progress: jobs.list.overallProgress,
                                   isRunning: jobs.list.runningCount > 0,
                                   hasFailure: jobs.list.hasFailure)
                    Text(headline.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if jobs.list.runningCount > 1 {
                        Text(verbatim: "+\(jobs.list.runningCount - 1)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                // A fixed slot: titles and counts change as jobs come and go, and
                // without it every change would shove the neighbouring status items.
                .frame(width: 190, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(jobs.list.hasFailure ? Color.red : .secondary)
            .help(helpText)
            .popover(isPresented: $showingList, arrowEdge: .bottom) {
                BackgroundJobsList(jobs: jobs)
            }
        }
    }

    private var helpText: LocalizedStringKey {
        jobs.list.runningCount > 0 ? "Background tasks" : "Recently finished tasks"
    }
}

/// Determinate where the work can say how far it is, a spinner where it can't.
private struct JobProgressBar: View {
    let progress: Double?
    let isRunning: Bool
    let hasFailure: Bool

    var body: some View {
        if !isRunning {
            Image(systemName: hasFailure ? "exclamationmark.triangle.fill" : "checkmark.circle")
        } else if let progress {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 54)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

/// The popover: every job with its own progress and its own Stop.
private struct BackgroundJobsList: View {
    let jobs: BackgroundJobsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(jobs.list.jobs) { job in
                row(job)
                if job.id != jobs.list.jobs.last?.id { Divider() }
            }
            if jobs.list.jobs.contains(where: { !$0.state.isRunning }) {
                Divider()
                Button("Clear Finished") { jobs.dismissFinished() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.top, 6)
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(_ job: BackgroundJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).lineLimit(1).truncationMode(.middle)
                switch job.state {
                case .running:
                    if let progress = job.progress {
                        ProgressView(value: progress).progressViewStyle(.linear)
                    }
                    if let detail = job.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                case .succeeded:
                    Label("Done", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                case .cancelled:
                    Label("Stopped", systemImage: "stop.circle")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            // Offered whenever the file is actually there — including after a
            // stopped dump, whose half-written file is exactly what you'd want to
            // go and delete.
            if let url = job.fileURL, FileManager.default.fileExists(atPath: url.path) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(url.path)
            }
            if job.state.isRunning {
                if job.isCancellable {
                    Button { jobs.cancel(job.id) } label: {
                        Label("Stop", systemImage: "xmark.circle.fill").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop this task")
                }
            } else {
                Button { jobs.dismiss(job.id) } label: {
                    Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove from the list")
            }
        }
        .padding(.vertical, 6)
    }
}
