import Foundation
import Observation
import os

/// The spine of the read-aloud pipeline: source → chunker → LLM rewrite →
/// synthesiser.
///
/// A coordinator of its own rather than a `VoiceAction`, because nothing here
/// starts at the microphone. `DictationCoordinator` owns a state machine whose
/// every state is about capturing audio; reading text aloud shares the contracts
/// (`LLMProvider`, `SecretStore`, `AppSettings`) and none of the states.
///
/// Everything is injected, so the whole pipeline runs in tests with fakes and no
/// I/O — no pasteboard, no network, no audio device.
@MainActor
@Observable
public final class NarrationCoordinator {
    // MARK: Observable state

    public private(set) var state: NarrationState = .idle
    /// How many chunks the run in flight was cut into, and how many have been
    /// handed to the synthesiser. The menu shows it as 「読み上げ中 2/5」; a long
    /// reading is otherwise indistinguishable from a stuck one.
    public private(set) var chunkCount = 0
    public private(set) var spokenChunkCount = 0

    // MARK: Dependencies

    private let source: any NarrationSourceReading
    private let synthesizer: any SpeechSynthesizing
    private let providers: LLMProviderRegistry
    private let secrets: any SecretStore
    private let promptBuilder: ReadAloudPromptBuilder
    private let chunker: NarrationChunker
    /// Read on every run rather than held, so a rate or voice changed in Settings
    /// applies to the next reading without re-wiring anything.
    private let settingsProvider: @MainActor () -> AppSettings

    // MARK: Private state

    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// True while chunks are still being rewritten. Without it, the gap between
    /// chunk 1 draining and chunk 2 arriving would read as "finished".
    @ObservationIgnored private var isProducing = false

    private static let log = Logger(subsystem: "io.github.voiceinput", category: "narration")

    public init(
        source: any NarrationSourceReading,
        synthesizer: any SpeechSynthesizing,
        providers: LLMProviderRegistry,
        secrets: any SecretStore,
        promptBuilder: ReadAloudPromptBuilder = ReadAloudPromptBuilder(),
        chunker: NarrationChunker = NarrationChunker(),
        settings: @escaping @MainActor () -> AppSettings
    ) {
        self.source = source
        self.synthesizer = synthesizer
        self.providers = providers
        self.secrets = secrets
        self.promptBuilder = promptBuilder
        self.chunker = chunker
        self.settingsProvider = settings

        synthesizer.onQueueDrained = { [weak self] in
            self?.handleQueueDrained()
        }
    }

    // MARK: - Commands

    /// One shortcut, four meanings, in the order a listener expects: start, pause,
    /// resume, and — while the first chunk is still being prepared — cancel.
    public func toggle() {
        switch state {
        case .idle, .failed:
            start()
        case .preparing:
            stop()
        case .speaking:
            pause()
        case .paused:
            resume()
        }
    }

    public func start() {
        guard !state.isActive else { return }

        chunkCount = 0
        spokenChunkCount = 0
        state = .preparing
        isProducing = true
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
    }

    public func pause() {
        guard state == .speaking else { return }
        synthesizer.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        synthesizer.resume()
        state = .speaking
    }

    /// Stops mid-sentence and drops whatever was queued or still being rewritten.
    public func stop() {
        runTask?.cancel()
        runTask = nil
        isProducing = false
        synthesizer.stop()
        state = .idle
    }

    /// Clears a failure the user has read, so the menu goes back to its resting
    /// label without a reading having to start.
    public func dismissFailure() {
        guard case .failed = state else { return }
        state = .idle
    }

    // MARK: - Pipeline

    private func run() async {
        let settings = settingsProvider()
        do {
            let text = try await source.read()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw VoiceInputError.nothingToRead }
            try Task.checkCancellation()

            let chunks = chunker.chunks(of: trimmed)
            chunkCount = chunks.count
            let rewriter = resolveRewriter(settings: settings)

            // Character counts and chunk counts only — never a line of what was
            // read. See `docs/SECURITY.md`.
            Self.log.notice(
                """
                start: sourceChars=\(trimmed.count, privacy: .public) \
                chunks=\(chunks.count, privacy: .public) \
                rewrite=\(rewriter != nil, privacy: .public)
                """
            )

            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let spoken: String
                if let rewriter {
                    spoken = await rewriter(chunk, index, chunks.count)
                } else {
                    spoken = chunk
                }
                try Task.checkCancellation()
                synthesizer.enqueue(spoken, rate: settings.readAloudSettings.rate)
                spokenChunkCount = index + 1
                if state == .preparing { state = .speaking }
            }

            isProducing = false
            // The queue may have drained while the last chunk was still being
            // rewritten, in which case no callback is coming.
            if !synthesizer.isSpeaking, state.isActive { state = .idle }
        } catch is CancellationError {
            // `stop()` already put the state back; nothing to report.
        } catch {
            isProducing = false
            fail(error)
        }
    }

    /// The rewrite step, or `nil` when the text should be spoken as it stands.
    ///
    /// `nil` is a normal outcome, not a failure: the feature works without an API
    /// key, it just reads the markdown as written. The same goes for a rewrite that
    /// throws mid-run — the chunk is spoken unrewritten rather than the reading
    /// stopping, which is the rule the dictation path already follows for a failed
    /// formatting call.
    private func resolveRewriter(
        settings: AppSettings
    ) -> ((String, Int, Int) async -> String)? {
        guard settings.readAloudSettings.rewriteEnabled else { return nil }
        guard let provider = providers.provider(for: settings.llmProvider) else { return nil }
        guard
            let key = (try? secrets.secret(for: .apiKey(for: provider.id)))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            Self.log.notice(
                "rewrite skipped: no API key for \(provider.id.rawValue, privacy: .public)")
            return nil
        }

        let model =
            settings.models[provider.id]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? provider.defaultModel
        let builder = promptBuilder

        return { [weak self] chunk, index, total in
            let prompt = builder.build(
                text: chunk,
                settings: settings,
                index: index,
                total: total
            )
            let request = LLMRequest(
                model: model,
                systemPrompt: prompt.system,
                messages: [.user(prompt.user)],
                // Read-aloud text is a rewrite, not a summary, so the ceiling has
                // to leave room for a chunk that grows: 「-」 becoming 「1つめは」
                // adds characters.
                maxOutputTokens: 4096,
                temperature: 0
            )
            do {
                let response = try await provider.send(request, apiKey: key)
                let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return chunk }
                return text
            } catch {
                // Kind only, and then carry on with the original text: a failed
                // rewrite must not cost the user the reading.
                Self.log.error(
                    "rewrite failed: \(VoiceInputError.wrapping(error).kind, privacy: .public)"
                )
                return chunk
            }
        }
    }

    private func handleQueueDrained() {
        guard !isProducing, state.isActive else { return }
        state = .idle
        Self.log.notice("finished: chunks=\(self.chunkCount, privacy: .public)")
    }

    private func fail(_ error: any Error) {
        let wrapped = VoiceInputError.wrapping(error)
        synthesizer.stop()
        state = .failed(wrapped)
        Self.log.error("failed: \(wrapped.kind, privacy: .public)")
    }
}
