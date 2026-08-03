import Foundation

/// Emits the transcript untouched. No LLM, no API key.
public struct RawAction: VoiceAction {
    public let id = VoiceActionID.raw
    public let displayName = "そのまま"
    public let requiresLLM = false

    public init() {}

    public func run(transcript: Transcript, context: ActionContext) async throws -> ActionOutcome {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceInputError.emptyTranscript }
        return ActionOutcome(
            text: text,
            copyToClipboard: true,
            pasteIntoFrontmostApp: context.settings.autoPasteEnabled,
            summary: "整形なし"
        )
    }
}
