import Foundation
import Testing
import os

@testable import VoiceInputCore

@Suite("Preparation timeout")
struct PreparationTimeoutTests {
    private struct TimedOut: Error {}

    @Test("a fast operation returns its value")
    func fastOperation() async throws {
        let value = try await PreparationTimeout.run(
            seconds: 5,
            onTimeout: { TimedOut() }
        ) { 42 }
        #expect(value == 42)
    }

    @Test("an operation error propagates unchanged")
    func operationError() async {
        await #expect(throws: VoiceInputError.emptyTranscript) {
            _ = try await PreparationTimeout.run(
                seconds: 5,
                onTimeout: { TimedOut() }
            ) { () -> Int in
                throw VoiceInputError.emptyTranscript
            }
        }
    }

    @Test("a stalled operation is abandoned at the deadline")
    func stalledOperation() async {
        await #expect(throws: TimedOut.self) {
            _ = try await PreparationTimeout.run(
                seconds: 0.05,
                onTimeout: { TimedOut() }
            ) { () -> Int in
                try await Task.sleep(for: .seconds(3600))
                return 0
            }
        }
    }

    @Test("a value produced after the deadline is handed back for disposal")
    func abandonedResult() async throws {
        let disposed = OSAllocatedUnfairLock<Int?>(initialState: nil)

        await #expect(throws: TimedOut.self) {
            _ = try await PreparationTimeout.run(
                seconds: 0.05,
                onTimeout: { TimedOut() },
                onAbandonedResult: { value in disposed.withLock { $0 = value } }
            ) { () -> Int in
                // Outlives cancellation on purpose — the hang being simulated
                // (an XPC call that never returns) does not observe it either.
                let clock = ContinuousClock()
                let deadline = clock.now + .milliseconds(150)
                while clock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                return 7
            }
        }

        var attempts = 100
        while disposed.withLock({ $0 }) == nil, attempts > 0 {
            try await Task.sleep(for: .milliseconds(10))
            attempts -= 1
        }
        #expect(disposed.withLock { $0 } == 7)
    }
}
