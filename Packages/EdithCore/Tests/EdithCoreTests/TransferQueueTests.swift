// SPDX-FileCopyrightText: 2026 Kreuder <mk@singular.de>
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import EdithCore

private struct Boom: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

/// Reads the queue's events until `.idle`.
private func eventsUntilIdle(_ queue: TransferQueue) async -> [TransferQueue.Event] {
    var events: [TransferQueue.Event] = []
    for await event in queue.events {
        events.append(event)
        if event == .idle { break }
    }
    return events
}

/// Ignores progress events, which depend on timing.
private func outline(_ events: [TransferQueue.Event]) -> [String] {
    events.compactMap { e in
        switch e {
        case .queued(_, let l): "queued \(l)"
        case .started(_, let l, let pending): "started \(l) +\(pending)"
        case .progress: nil
        case .done(_, let l): "done \(l)"
        case .failed(_, let l, let m): "failed \(l): \(m)"
        case .cancelled(_, let l): "cancelled \(l)"
        case .idle: "idle"
        }
    }
}

@Test func jobsRunOneAtATimeInOrder() async throws {
    let queue = TransferQueue()
    let order = OrderLog()
    for name in ["a", "b", "c"] {
        await queue.enqueue(name) { _ in
            await order.begin(name)
            try await Task.sleep(for: .milliseconds(20))
            await order.end(name)
        }
    }
    let events = await eventsUntilIdle(queue)
    #expect(await order.entries == ["+a", "-a", "+b", "-b", "+c", "-c"])
    #expect(outline(events) == [
        "queued a", "started a +0", "queued b", "queued c", "done a",
        "started b +1", "done b", "started c +0", "done c", "idle",
    ])
}

@Test func failuresAreReportedAndTheQueueMovesOn() async throws {
    let queue = TransferQueue()
    await queue.enqueue("bad") { _ in throw Boom() }
    await queue.enqueue("good") { _ in }
    let events = await eventsUntilIdle(queue)
    #expect(outline(events).contains("failed bad: boom"))
    #expect(outline(events).contains("done good"))
}

@Test func progressIsThrottledToWholePercents() async throws {
    let queue = TransferQueue()
    await queue.enqueue("big") { progress in
        for done in stride(from: UInt64(0), through: 1_000_000, by: 1000) {
            progress(done, 1_000_000)
        }
    }
    let fractions = await eventsUntilIdle(queue).compactMap { e -> Double? in
        if case .progress(_, _, let f, _) = e { f } else { nil }
    }
    #expect(fractions.count == 101)
    #expect(fractions.last == 1)
}

@Test func cancellingRunningAndWaitingJobs() async throws {
    let queue = TransferQueue()
    let running = await queue.enqueue("running") { _ in
        try await Task.sleep(for: .seconds(30))
    }
    let waiting = await queue.enqueue("waiting") { _ in }
    await queue.enqueue("after") { _ in }

    #expect(await queue.cancel(waiting))
    #expect(await queue.cancel(running))
    let lines = outline(await eventsUntilIdle(queue))
    #expect(lines.contains("cancelled waiting"))
    #expect(lines.contains("cancelled running"))
    #expect(!lines.contains("started waiting +1"))
    #expect(lines.contains("done after"))
}

@Test func performReturnsResultsAndErrors() async throws {
    let queue = TransferQueue()
    let value = try await queue.perform("compute") { _ in 42 }
    #expect(value == 42)
    await #expect(throws: Boom.self) {
        try await queue.perform("fail") { _ in throw Boom() }
    }
}

@Test func performOfDiscardedJobThrowsCancellation() async throws {
    let queue = TransferQueue()
    await queue.enqueue("blocker") { _ in try await Task.sleep(for: .milliseconds(200)) }
    let victim = Task { try await queue.perform("victim") { _ in 1 } }
    try await Task.sleep(for: .milliseconds(50))
    await queue.clear()
    await #expect(throws: CancellationError.self) { _ = try await victim.value }
}

private actor OrderLog {
    var entries: [String] = []
    func begin(_ s: String) { entries.append("+" + s) }
    func end(_ s: String) { entries.append("-" + s) }
}
