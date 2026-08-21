import Foundation

/// Races an async operation against a deadline **without waiting for the loser**.
///
/// A task group cannot express this: a group always awaits its children, so a
/// child stuck in a non-cancellable framework call (an XPC probe into a wedged
/// speech daemon) would keep the group — and the caller — suspended forever.
/// Here the caller resumes as soon as either side finishes; the losing
/// operation is cancelled and abandoned. An abandoned operation that later
/// produces a value hands it to `onAbandonedResult`, so the caller can dispose
/// of a resource it no longer wants (cancel a session that opened too late).
enum PreparationTimeout {
    static func run<T: Sendable>(
        seconds: TimeInterval,
        onTimeout timeoutError: @escaping @Sendable () -> Error,
        onAbandonedResult: @escaping @Sendable (T) -> Void = { _ in },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = RaceState<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation)
                race.register(
                    Task {
                        let result: Result<T, Error>
                        do { result = .success(try await operation()) } catch {
                            result = .failure(error)
                        }
                        if !race.finish(result), case .success(let value) = result {
                            onAbandonedResult(value)
                        }
                    },
                    Task {
                        do {
                            try await Task.sleep(
                                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                        } catch {
                            // Cancelled: the operation won, or the caller gave up.
                            return
                        }
                        _ = race.finish(.failure(timeoutError()))
                    }
                )
            }
        } onCancel: {
            _ = race.finish(.failure(CancellationError()))
        }
    }
}

/// Resume-once bookkeeping for the race. `@unchecked` because every mutation
/// happens under the lock.
private final class RaceState<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingResult: Result<T, Error>?
    private var finished = false
    private var tasks: [Task<Void, Never>] = []

    /// The cancellation handler can fire before the continuation exists; a
    /// result that arrived early is parked in `pendingResult` and delivered here.
    func start(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func register(_ first: Task<Void, Never>, _ second: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = finished
        if !alreadyFinished { tasks.append(contentsOf: [first, second]) }
        lock.unlock()
        if alreadyFinished {
            first.cancel()
            second.cancel()
        }
    }

    /// Delivers `result` unless someone already has; returns whether this call won.
    func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
        return true
    }
}
