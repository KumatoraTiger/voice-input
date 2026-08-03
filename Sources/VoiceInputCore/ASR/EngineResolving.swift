import Foundation

/// Lets Core drive engines that are implemented in the platform target.
///
/// `VoiceInputPlatform` owns the Apple speech adapters; Core only needs to be
/// able to look one up by id.
public protocol TranscriptionEngineResolving: Sendable {
    var engines: [any TranscriptionEngine] { get }
    func engine(for id: TranscriptionEngineID) -> (any TranscriptionEngine)?
}

/// A resolver over a fixed list — used by the app for the cloud-only engine set
/// and by tests/previews for fakes.
public struct StaticEngineResolver: TranscriptionEngineResolving {
    public let engines: [any TranscriptionEngine]

    public init(engines: [any TranscriptionEngine]) {
        self.engines = engines
    }

    public func engine(for id: TranscriptionEngineID) -> (any TranscriptionEngine)? {
        engines.first { $0.id == id }
    }
}
