import Foundation
import Testing

@testable import VoiceInputCore

@Suite("Voice actions")
struct ActionTests {
    private func settings(
        autoPaste: Bool = false,
        models: [LLMProviderID: String] = [:]
    ) -> AppSettings {
        AppSettings(
            vocabulary: ["Shaperon"],
            models: models,
            autoPasteEnabled: autoPaste
        )
    }

    // MARK: RawAction

    @Test("raw action returns the transcript unchanged")
    func rawPassthrough() async throws {
        let action = RawAction()
        #expect(action.id == .raw)
        #expect(action.requiresLLM == false)

        let outcome = try await action.run(
            transcript: Transcript(text: "  そのままの文字列  ", engine: .appleOnDevice),
            context: ActionContext(settings: settings())
        )
        #expect(outcome.text == "そのままの文字列")
        #expect(outcome.copyToClipboard)
        #expect(outcome.pasteIntoFrontmostApp == false)
    }

    @Test("raw action rejects a blank transcript")
    func rawEmpty() async {
        await #expect(throws: VoiceInputError.emptyTranscript) {
            _ = try await RawAction().run(
                transcript: Transcript(text: "   \n ", engine: .appleOnDevice),
                context: ActionContext(settings: settings())
            )
        }
    }

    // MARK: FormatAction

    @Test("format action sends the built prompt and returns the cleaned reply")
    func formatHappyPath() async throws {
        let provider = FakeLLMProvider(reply: "整形されたテキスト。")
        let action = FormatAction()
        #expect(action.id == .format)
        #expect(action.requiresLLM)

        let outcome = try await action.run(
            transcript: Transcript(text: "えーっと これは テスト", engine: .appleOnDevice),
            context: ActionContext(
                settings: settings(models: [.openAI: "gpt-4.1"]),
                llm: provider,
                apiKey: "sk-test"
            )
        )

        #expect(outcome.text == "整形されたテキスト。")
        #expect(outcome.copyToClipboard)

        let request = try #require(provider.requests.first)
        #expect(request.model == "gpt-4.1")
        #expect(request.systemPrompt?.isEmpty == false)
        #expect(request.messages.first?.content.contains("えーっと これは テスト") == true)
        #expect(request.messages.first?.content.contains("Shaperon") == true)
    }

    @Test("model falls back to the provider default")
    func modelFallback() async throws {
        let provider = FakeLLMProvider()
        _ = try await FormatAction().run(
            transcript: Transcript(text: "テスト", engine: .appleOnDevice),
            context: ActionContext(settings: settings(), llm: provider, apiKey: "sk-test")
        )
        #expect(provider.requests.first?.model == provider.defaultModel)
    }

    @Test("summary is model · elapsed seconds")
    func summaryFormat() async throws {
        let start = Date(timeIntervalSince1970: 1_000)
        // First call is the start timestamp, second is taken after the reply.
        let times = [start, start.addingTimeInterval(1.24)]
        let index = CallCounter()
        let action = FormatAction(
            clock: { times[min(index.next(), times.count - 1)] }
        )

        let outcome = try await action.run(
            transcript: Transcript(text: "テスト", engine: .appleOnDevice),
            context: ActionContext(
                settings: settings(),
                llm: FakeLLMProvider(),
                apiKey: "sk-test"
            )
        )
        #expect(outcome.summary == "fake-model · 1.2s")
        #expect(FormatAction.summary(model: "gpt-4.1-mini", elapsed: 1.24) == "gpt-4.1-mini · 1.2s")
    }

    @Test("markdown fences and surrounding whitespace are stripped")
    func fenceStripping() {
        #expect(FormatAction.cleanReply("```\nテキスト\n```") == "テキスト")
        #expect(FormatAction.cleanReply("```markdown\n一行目\n二行目\n```") == "一行目\n二行目")
        #expect(FormatAction.cleanReply("\n\n  テキスト  \n\n") == "テキスト")
        #expect(FormatAction.cleanReply("コード ```inline``` を含む") == "コード ```inline``` を含む")
    }

    @Test("auto paste is only requested when enabled in settings")
    func autoPaste() async throws {
        let outcomeOff = try await FormatAction().run(
            transcript: Transcript(text: "テスト", engine: .appleOnDevice),
            context: ActionContext(
                settings: settings(autoPaste: false),
                llm: FakeLLMProvider(),
                apiKey: "sk-test"
            )
        )
        #expect(outcomeOff.pasteIntoFrontmostApp == false)

        let outcomeOn = try await FormatAction().run(
            transcript: Transcript(text: "テスト", engine: .appleOnDevice),
            context: ActionContext(
                settings: settings(autoPaste: true),
                llm: FakeLLMProvider(),
                apiKey: "sk-test"
            )
        )
        #expect(outcomeOn.pasteIntoFrontmostApp)
    }

    @Test("missing key and blank transcript are rejected before the network")
    func formatFailures() async {
        let provider = FakeLLMProvider()

        await #expect(throws: VoiceInputError.missingAPIKey(.openAI)) {
            _ = try await FormatAction().run(
                transcript: Transcript(text: "テスト", engine: .appleOnDevice),
                context: ActionContext(settings: settings(), llm: provider, apiKey: nil)
            )
        }
        await #expect(throws: VoiceInputError.missingAPIKey(.openAI)) {
            _ = try await FormatAction().run(
                transcript: Transcript(text: "テスト", engine: .appleOnDevice),
                context: ActionContext(settings: settings(), llm: nil, apiKey: "sk-test")
            )
        }
        await #expect(throws: VoiceInputError.emptyTranscript) {
            _ = try await FormatAction().run(
                transcript: Transcript(text: "  ", engine: .appleOnDevice),
                context: ActionContext(settings: settings(), llm: provider, apiKey: "sk-test")
            )
        }
        #expect(provider.requests.isEmpty)
    }

    // MARK: Registries

    @Test("the live registries expose the shipped implementations")
    func registries() {
        #expect(ActionRegistry.live.action(for: .format)?.requiresLLM == true)
        #expect(ActionRegistry.live.action(for: .raw)?.requiresLLM == false)
        #expect(ActionRegistry.live.action(for: VoiceActionID(rawValue: "nope")) == nil)

        let providers = LLMProviderRegistry.live()
        #expect(providers.all.count == 2)
        #expect(providers.provider(for: .openAI)?.defaultModel == "gpt-4.1-mini")
        #expect(providers.provider(for: .anthropic)?.defaultModel == "claude-haiku-4-5")
    }
}

/// Tiny call counter so the clock can be stepped deterministically.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value += 1
        return current
    }
}
