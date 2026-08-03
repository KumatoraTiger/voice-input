import Foundation
import Observation
import VoiceInputCore

/// Live `EngineAvailability` for every registered engine.
///
/// Availability depends on TCC state, installed locale models and stored keys, so
/// it is re-probed rather than cached across launches. Kept out of the views: the
/// probes are async and must not run inside `body`.
@MainActor
@Observable
final class EngineAvailabilityModel {
    private(set) var statuses: [TranscriptionEngineID: EngineAvailability] = [:]
    private(set) var isRefreshing = false

    @ObservationIgnored private let engines: any TranscriptionEngineResolving

    init(engines: any TranscriptionEngineResolving) {
        self.engines = engines
    }

    var all: [any TranscriptionEngine] { engines.engines }

    func availability(for id: TranscriptionEngineID) -> EngineAvailability? {
        statuses[id]
    }

    func refresh(locale: Locale) async {
        isRefreshing = true
        defer { isRefreshing = false }

        var results: [TranscriptionEngineID: EngineAvailability] = [:]
        for engine in engines.engines {
            results[engine.id] = await engine.availability(locale: locale)
        }
        statuses = results
    }
}
