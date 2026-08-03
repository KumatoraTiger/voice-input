import Foundation
import os

/// Runs `work` but stops waiting for it after `timeout`, returning `fallback`.
///
/// The abandoned work is **not** cancelled. Nothing this is used for — a
/// ScreenCaptureKit capture, a Vision OCR pass — checks for cancellation, so
/// pretending otherwise would be a lie; it simply loses the race and its result
/// is dropped. That is acceptable for work whose only product is an optional
/// improvement to a prompt, and it is the reason this helper is not general
/// purpose: never reach for it where the side effects matter.
func withDeadline<T: Sendable>(
    _ timeout: Duration,
    fallback: T,
    work: @escaping @Sendable () async -> T
) async -> T {
    let settled = OSAllocatedUnfairLock(initialState: false)

    return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let finish: @Sendable (T) -> Void = { value in
            let isFirst = settled.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if isFirst { continuation.resume(returning: value) }
        }

        Task.detached { finish(await work()) }
        Task.detached {
            try? await Task.sleep(for: timeout)
            finish(fallback)
        }
    }
}
