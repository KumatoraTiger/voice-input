import Foundation

/// Maps a `VoiceActionID` to the action that implements it.
public struct ActionRegistry: Sendable {
    public let all: [any VoiceAction]
    private let byID: [VoiceActionID: any VoiceAction]

    public init(actions: [any VoiceAction]) {
        self.all = actions
        self.byID = Dictionary(actions.map { ($0.id, $0) }) { _, last in last }
    }

    public func action(for id: VoiceActionID) -> (any VoiceAction)? {
        byID[id]
    }

    public static let live = ActionRegistry(actions: [FormatAction(), RawAction()])
}
