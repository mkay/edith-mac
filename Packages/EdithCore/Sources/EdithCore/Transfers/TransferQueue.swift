// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Transfers, run one at a time, reporting progress for the status bar and
/// transfer panel. A port of the Linux app's TransferQueue.
public actor TransferQueue {
    public struct JobID: Hashable, Sendable, CustomStringConvertible {
        let value: Int
        public var description: String { "#\(value)" }
    }

    public enum Event: Equatable, Sendable {
        case queued(JobID, label: String)
        /// `pending` counts the jobs still waiting behind this one.
        case started(JobID, label: String, pending: Int)
        /// At most one per whole percent.
        case progress(JobID, label: String, fraction: Double, pending: Int)
        case done(JobID, label: String)
        case failed(JobID, label: String, message: String)
        case cancelled(JobID, label: String)
        /// Everything finished.
        case idle
    }

    /// What a job reports progress through.
    public struct Progress: Sendable {
        let report: @Sendable (UInt64, UInt64) -> Void

        /// Pass as the `progress:` of a RemoteFileSystem call.
        public var callback: TransferProgress { report }

        public func callAsFunction(_ done: UInt64, _ total: UInt64) {
            report(done, total)
        }
    }

    public typealias Work = @Sendable (Progress) async throws -> Void

    private struct Job {
        let id: JobID
        let label: String
        let work: Work
        /// Called if the job is removed before it starts.
        let discarded: @Sendable () -> Void
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private var waiting: [Job] = []
    private var active: (id: JobID, task: Task<Void, Never>)?
    private var nextID = 0

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        continuation.finish()
    }

    /// Jobs waiting, not counting the running one.
    public var pending: Int { waiting.count }
    public var isBusy: Bool { active != nil }

    @discardableResult
    public func enqueue(_ label: String, work: @escaping Work) -> JobID {
        add(label, work: work, discarded: {})
    }

    @discardableResult
    private func add(_ label: String, work: @escaping Work, discarded: @escaping @Sendable () -> Void) -> JobID {
        let id = JobID(value: nextID)
        nextID += 1
        waiting.append(Job(id: id, label: label, work: work, discarded: discarded))
        continuation.yield(.queued(id, label: label))
        if active == nil { startNext() }
        return id
    }

    /// Enqueues a job and waits for it, returning its result or rethrowing
    /// its error (`CancellationError` if it was cancelled).
    public func perform<T: Sendable>(_ label: String, work: @escaping @Sendable (Progress) async throws -> T) async throws -> T {
        let box = ResultBox<T>()
        return try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<T, Error>) in
            box.waiter = waiter
            add(label, work: { progress in
                do {
                    box.finish(.success(try await work(progress)))
                } catch {
                    box.finish(.failure(error))
                    throw error
                }
            }, discarded: {
                // Removed while waiting, so it never runs; answer for it.
                box.finish(.failure(CancellationError()))
            })
        }
    }

    /// Stops the running job, or removes a waiting one. False if it's unknown
    /// or already finished.
    @discardableResult
    public func cancel(_ id: JobID) -> Bool {
        if active?.id == id {
            active?.task.cancel()
            return true
        }
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return false }
        let job = waiting.remove(at: index)
        discard(job)
        return true
    }

    /// Removes every waiting job. The running one continues.
    public func clear() {
        let jobs = waiting
        waiting = []
        jobs.forEach(discard)
    }

    private func discard(_ job: Job) {
        continuation.yield(.cancelled(job.id, label: job.label))
        job.discarded()
    }

    private func startNext() {
        guard !waiting.isEmpty else {
            active = nil
            continuation.yield(.idle)
            return
        }
        let job = waiting.removeFirst()
        let pending = waiting.count
        continuation.yield(.started(job.id, label: job.label, pending: pending))

        let throttle = PercentThrottle()
        let events = continuation
        let progress = Progress { done, total in
            guard total > 0, let fraction = throttle.next(done: done, total: total) else { return }
            events.yield(.progress(job.id, label: job.label, fraction: fraction, pending: pending))
        }
        let task = Task {
            let outcome: Event
            do {
                try await job.work(progress)
                outcome = .done(job.id, label: job.label)
            } catch is CancellationError {
                outcome = .cancelled(job.id, label: job.label)
            } catch {
                outcome = Task.isCancelled
                    ? .cancelled(job.id, label: job.label)
                    : .failed(job.id, label: job.label, message: error.localizedDescription)
            }
            // The task inherits the queue's isolation; only `work` runs elsewhere.
            self.finished(outcome)
        }
        active = (job.id, task)
    }

    private func finished(_ outcome: Event) {
        continuation.yield(outcome)
        startNext()
    }
}

/// Passes on a fraction only when the whole percent changes, so a fast
/// transfer doesn't flood the UI.
private final class PercentThrottle: @unchecked Sendable {
    private var last = -1
    private let lock = NSLock()

    func next(done: UInt64, total: UInt64) -> Double? {
        let percent = Int(min(done, total) * 100 / total)
        return lock.withLock {
            guard percent != last else { return nil }
            last = percent
            return min(Double(done) / Double(total), 1)
        }
    }
}

/// Resumes a `perform` caller exactly once, whichever way the job ends.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var waiter: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    func finish(_ result: Result<T, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<T, Error>? in
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }
}
