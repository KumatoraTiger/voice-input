import Foundation
import Testing
import os

@testable import VoiceInputCore

@MainActor
@Suite("Dictation coordinator")
struct DictationCoordinatorTests {
    /// Everything the pipeline touches, wired to fakes.
    private struct Harness {
        let audio: FakeAudioCapture
        let provider: FakeLLMProvider
        let output: FakeOutputSink
        let secrets: InMemorySecretStore
        let settingsStore: InMemorySettingsStore
        let feedback: RecordingFeedbackPresenter
        let coordinator: DictationCoordinator
    }

    /// Lets background pipeline tasks run until `condition` holds, without
    /// making the test depend on wall-clock timing.
    private static func yieldUntil(
        attempts: Int = 200,
        _ condition: () -> Bool
    ) async {
        var remaining = attempts
        while !condition(), remaining > 0 {
            await Task.yield()
            remaining -= 1
        }
    }

    private func makeHarness(
        settings: AppSettings = AppSettings(),
        engine: any TranscriptionEngine = FakeTranscriptionEngine(transcript: "えーっと 生の書き起こし"),
        apiKey: String? = "sk-test",
        reply: String = "整形されたテキスト。",
        llmError: VoiceInputError? = nil,
        audio: FakeAudioCapture = FakeAudioCapture()
    ) -> Harness {
        let provider = FakeLLMProvider(reply: reply, error: llmError)
        let output = FakeOutputSink()
        let secrets = InMemorySecretStore(
            apiKey.map { [SecretKey.apiKey(for: .openAI): $0] } ?? [:]
        )
        let settingsStore = InMemorySettingsStore(settings)
        let feedback = RecordingFeedbackPresenter()

        let coordinator = DictationCoordinator(
            audio: audio,
            engines: StaticEngineResolver(engines: [engine]),
            providers: LLMProviderRegistry(all: [provider]),
            actions: .live,
            settingsStore: settingsStore,
            secrets: secrets,
            output: output,
            feedback: feedback
        )
        coordinator.finishedStateDuration = .zero

        return Harness(
            audio: audio,
            provider: provider,
            output: output,
            secrets: secrets,
            settingsStore: settingsStore,
            feedback: feedback,
            coordinator: coordinator
        )
    }

    // MARK: Happy path

    @Test("start → record → stop → format → copy → history")
    func happyPath() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        #expect(coordinator.state == .idle)

        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
        #expect(harness.audio.startCount == 1)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.audio.stopCount == 1)
        #expect(harness.output.copiedTexts == ["整形されたテキスト。"])
        #expect(harness.output.pastedTexts.isEmpty)
        #expect(coordinator.history.count == 1)
        #expect(coordinator.history.first?.rawText == "えーっと 生の書き起こし")
        #expect(coordinator.history.first?.formattedText == "整形されたテキスト。")
        #expect(coordinator.partialText.isEmpty)
        #expect(coordinator.inputLevel == 0)
        #expect(
            harness.feedback.events == [.recordingStarted, .recordingStopped, .finished]
        )
    }

    @Test("toggle starts then stops")
    func toggle() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)

        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .idle)
        #expect(harness.output.copiedTexts.count == 1)
    }

    @Test("partials are mirrored into partialText while recording")
    func partials() async throws {
        let harness = makeHarness(
            engine: FakeTranscriptionEngine(
                transcript: "最終結果",
                partials: ["こん", "こんにちは"]
            )
        )
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        await Self.yieldUntil { coordinator.partialText == "こんにちは" }
        #expect(coordinator.partialText == "こんにちは")
    }

    @Test("audio buffers reach the session and drive the level meter")
    func buffersForwarded() async throws {
        let audio = FakeAudioCapture(scriptedBuffers: [FakeAudioCapture.tone(seconds: 0.25)])
        let harness = makeHarness(audio: audio)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        await Self.yieldUntil { coordinator.inputLevel > 0 }
        #expect(coordinator.inputLevel > 0)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .idle)
    }

    @Test("formattingEnabled = false skips the LLM entirely")
    func rawFallback() async throws {
        var settings = AppSettings()
        settings.formattingEnabled = false
        let harness = makeHarness(settings: settings, apiKey: nil)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.provider.requests.isEmpty)
        #expect(harness.output.copiedTexts == ["えーっと 生の書き起こし"])
    }

    @Test("autoPaste pastes as well as copies")
    func autoPaste() async throws {
        var settings = AppSettings()
        settings.autoPasteEnabled = true
        let harness = makeHarness(settings: settings)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.output.copiedTexts == ["整形されたテキスト。"])
        #expect(harness.output.pastedTexts == ["整形されたテキスト。"])
    }

    @Test("history honours the configured limit")
    func historyLimit() async throws {
        var settings = AppSettings()
        settings.historyLimit = 2
        let harness = makeHarness(settings: settings)
        let coordinator = harness.coordinator

        for _ in 0..<3 {
            coordinator.start()
            await coordinator.waitUntilIdle()
            coordinator.stopAndProcess()
            await coordinator.waitUntilIdle()
        }
        #expect(coordinator.history.count == 2)
    }

    @Test("lowering the history limit trims what is already retained")
    func historyLimitAppliesImmediately() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        for _ in 0..<3 {
            coordinator.start()
            await coordinator.waitUntilIdle()
            coordinator.stopAndProcess()
            await coordinator.waitUntilIdle()
        }
        #expect(coordinator.history.count == 3)

        coordinator.settings.historyLimit = 1
        #expect(coordinator.history.count == 1)

        coordinator.settings.historyLimit = 0
        #expect(coordinator.history.isEmpty)
    }

    // MARK: Preflight

    /// Reference box so a `@Sendable` hook can report back into the test.
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test("preflight runs before recording starts")
    func preflightRunsFirst() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator
        let ran = Box(false)
        coordinator.preflight = { ran.value = true }

        coordinator.start()
        await coordinator.waitUntilIdle()

        #expect(ran.value)
        #expect(coordinator.state == .recording)
    }

    @Test("a preflight failure surfaces as that error and copies nothing")
    func preflightFailureStopsCapture() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator
        coordinator.preflight = { throw VoiceInputError.microphonePermissionDenied }

        coordinator.start()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .failed(.microphonePermissionDenied))
        #expect(harness.output.copiedTexts.isEmpty)
    }

    /// Records the context it is handed, so the test can assert on what the
    /// coordinator built.
    private final class ContextSpyAction: VoiceAction, @unchecked Sendable {
        let id = VoiceActionID.format
        let displayName = "spy"
        let requiresLLM = false
        var seenFrontmostAppName: String?
        var seenStyleName: String?

        func run(transcript: Transcript, context: ActionContext) async throws -> ActionOutcome {
            seenFrontmostAppName = context.frontmostAppName
            seenStyleName = context.settings.activeStyle?.name
            return ActionOutcome(text: transcript.text)
        }
    }

    /// A coordinator whose action records the context it was handed.
    private func makeSpyHarness(
        settings: AppSettings = AppSettings()
    ) -> (coordinator: DictationCoordinator, spy: ContextSpyAction, store: InMemorySettingsStore) {
        let spy = ContextSpyAction()
        let store = InMemorySettingsStore(settings)
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            engines: StaticEngineResolver(engines: [FakeTranscriptionEngine(transcript: "テスト")]),
            providers: LLMProviderRegistry(all: []),
            actions: ActionRegistry(actions: [spy]),
            settingsStore: store,
            secrets: InMemorySecretStore([:]),
            output: FakeOutputSink()
        )
        coordinator.finishedStateDuration = .zero
        return (coordinator, spy, store)
    }

    @Test("the frontmost app name reaches the action context")
    func frontmostAppNameIsForwarded() async throws {
        let spy = ContextSpyAction()
        let coordinator = DictationCoordinator(
            audio: FakeAudioCapture(),
            engines: StaticEngineResolver(engines: [FakeTranscriptionEngine(transcript: "テスト")]),
            providers: LLMProviderRegistry(all: []),
            actions: ActionRegistry(actions: [spy]),
            settingsStore: InMemorySettingsStore(AppSettings()),
            secrets: InMemorySecretStore([:]),
            output: FakeOutputSink()
        )
        coordinator.finishedStateDuration = .zero
        coordinator.frontmostAppNameProvider = { "Slack" }

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(spy.seenFrontmostAppName == "Slack")
    }

    // MARK: Formatting style, chosen per dictation

    @Test("starting with a style formats with it and leaves the default alone")
    func styleOverrideAppliesOnce() async throws {
        let harness = makeSpyHarness()
        let coordinator = harness.coordinator

        coordinator.start(styleID: FormattingStyle.messageID)
        await coordinator.waitUntilIdle()
        #expect(coordinator.effectiveStyleID == FormattingStyle.messageID)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.spy.seenStyleName == "チャット向け")
        // The stored default never moved — that is the whole point of the override.
        #expect(harness.store.load().activeStyleID == FormattingStyle.standardID)
        #expect(coordinator.settings.activeStyleID == FormattingStyle.standardID)
        // …and it does not leak into the next dictation.
        #expect(coordinator.styleOverrideID == nil)
        #expect(coordinator.effectiveStyleID == FormattingStyle.standardID)
    }

    @Test("selecting a style while recording switches the dictation in flight")
    func selectStyleWhileRecording() async throws {
        let harness = makeSpyHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.effectiveStyleID == FormattingStyle.standardID)

        coordinator.selectStyle(FormattingStyle.verbatimID)
        #expect(coordinator.effectiveStyleID == FormattingStyle.verbatimID)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        #expect(harness.spy.seenStyleName == "最小限")
    }

    @Test("a style shortcut pressed mid-recording switches instead of stopping")
    func toggleWithAnotherStyleSwitches() async throws {
        let harness = makeSpyHarness()
        let coordinator = harness.coordinator

        coordinator.toggle(styleID: FormattingStyle.messageID)
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)

        coordinator.toggle(styleID: FormattingStyle.verbatimID)
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
        #expect(coordinator.effectiveStyleID == FormattingStyle.verbatimID)

        // The style now in effect stops, like the plain shortcut does.
        coordinator.toggle(styleID: FormattingStyle.verbatimID)
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .idle)
        #expect(harness.spy.seenStyleName == "最小限")
    }

    @Test("the plain shortcut stops a dictation started from a style shortcut")
    func plainToggleStopsStyleDictation() async throws {
        let harness = makeSpyHarness()
        let coordinator = harness.coordinator

        coordinator.toggle(styleID: FormattingStyle.messageID)
        await coordinator.waitUntilIdle()
        coordinator.toggle()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.spy.seenStyleName == "チャット向け")
    }

    @Test("an unknown style id falls back to the default rather than failing")
    func unknownStyleIDIsIgnored() async throws {
        let harness = makeSpyHarness()
        let coordinator = harness.coordinator

        coordinator.start(styleID: UUID())
        await coordinator.waitUntilIdle()
        #expect(coordinator.styleOverrideID == nil)

        coordinator.selectStyle(UUID())
        #expect(coordinator.styleOverrideID == nil)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        #expect(harness.spy.seenStyleName == "標準")
    }

    @Test("selecting a style outside a dictation is ignored")
    func selectStyleWhileIdleIsIgnored() async throws {
        let coordinator = makeSpyHarness().coordinator

        coordinator.selectStyle(FormattingStyle.verbatimID)
        #expect(coordinator.styleOverrideID == nil)
    }

    @Test("cancelling drops the style override")
    func cancelClearsStyleOverride() async throws {
        let coordinator = makeSpyHarness().coordinator

        coordinator.start(styleID: FormattingStyle.messageID)
        await coordinator.waitUntilIdle()
        coordinator.cancel()

        #expect(coordinator.styleOverrideID == nil)
        #expect(coordinator.effectiveStyleID == FormattingStyle.standardID)
    }

    // MARK: Asking a question

    @Test("the ask action answers the transcript and copies the answer")
    func askHappyPath() async throws {
        let harness = makeHarness(
            engine: FakeTranscriptionEngine(transcript: "Swift の Sendable とは"),
            reply: "並行処理で安全に渡せる型のことです。"
        )
        let coordinator = harness.coordinator

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        #expect(coordinator.currentAction == .ask)

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        // The answer waits on screen: `finishedStateDuration` is zero in this
        // harness, so anything but `.finished` here means it was timed out away.
        guard case .finished(let outcome) = coordinator.state else {
            Issue.record("expected .finished, got \(coordinator.state)")
            return
        }
        #expect(outcome.text == "並行処理で安全に渡せる型のことです。")
        #expect(outcome.presentation == .persistent)
        #expect(harness.output.copiedTexts == ["並行処理で安全に渡せる型のことです。"])
        #expect(
            harness.provider.requests.first?.systemPrompt == AskPromptBuilder.systemPrompt
        )
        #expect(coordinator.history.first?.rawText == "Swift の Sendable とは")

        coordinator.dismissFinished()
        #expect(coordinator.state == .idle)
    }

    @Test("dismissing a result is ignored unless one is waiting")
    func dismissFinishedIsGuarded() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.dismissFinished()
        #expect(coordinator.state == .idle)

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        // Mid-recording it must not double as a cancel.
        coordinator.dismissFinished()
        #expect(coordinator.state == .recording)
    }

    @Test("a formatted dictation still returns to idle on its own")
    func formattedResultTimesOut() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
    }

    @Test("a waiting answer does not block the next recording")
    func askResultDoesNotBlockTheNextRun() async throws {
        let harness = makeHarness(reply: "答えです。")
        let coordinator = harness.coordinator

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        guard case .finished = coordinator.state else {
            Issue.record("expected .finished, got \(coordinator.state)")
            return
        }

        // `.finished` is not busy, so the hotkey still starts a new run.
        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
    }

    @Test("formattingEnabled = false does not disable questions")
    func askIgnoresFormattingToggle() async throws {
        // The toggle means "do not rewrite my dictation"; a question the user
        // explicitly asked for still has to reach the LLM.
        var settings = AppSettings()
        settings.formattingEnabled = false
        let harness = makeHarness(settings: settings, reply: "答えです。")
        let coordinator = harness.coordinator

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.provider.requests.count == 1)
        #expect(harness.output.copiedTexts == ["答えです。"])
    }

    @Test("the question shortcut pressed mid-dictation converts the recording")
    func askShortcutSwitchesInFlight() async throws {
        let harness = makeHarness(reply: "答えです。")
        let coordinator = harness.coordinator

        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.currentAction == .format)

        // Not a stop: pressing the other shortcut mid-sentence is a correction.
        coordinator.toggle(action: .ask)
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
        #expect(coordinator.currentAction == .ask)

        // …and the same shortcut again does stop.
        coordinator.toggle(action: .ask)
        await coordinator.waitUntilIdle()
        guard case .finished = coordinator.state else {
            Issue.record("expected the answer to be waiting, got \(coordinator.state)")
            return
        }
        #expect(
            harness.provider.requests.first?.systemPrompt == AskPromptBuilder.systemPrompt
        )
    }

    @Test("the dictation shortcut turns a question back into a dictation")
    func dictationShortcutSwitchesBack() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.toggle(action: .ask)
        await coordinator.waitUntilIdle()
        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
        #expect(coordinator.currentAction == .format)

        coordinator.toggle()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .idle)
        #expect(
            harness.provider.requests.first?.systemPrompt == FormattingPromptBuilder.systemPrompt
        )
    }

    @Test("switching action outside a recording, or to an unknown one, is ignored")
    func selectActionIsGuarded() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.selectAction(.ask)
        #expect(coordinator.currentAction == .format)

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        coordinator.selectAction(VoiceActionID(rawValue: "nope"))
        #expect(coordinator.currentAction == .ask)
    }

    // MARK: Cancel

    @Test("cancel returns to idle and copies nothing")
    func cancel() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)

        coordinator.cancel()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.output.copiedTexts.isEmpty)
        #expect(harness.output.pastedTexts.isEmpty)
        #expect(coordinator.history.isEmpty)
        #expect(coordinator.partialText.isEmpty)
        #expect(harness.provider.requests.isEmpty)
        #expect(harness.feedback.events.last == .cancelled)

        // …and the machine is reusable afterwards.
        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .recording)
    }

    @Test("cancel from idle is a no-op that stays idle")
    func cancelFromIdle() async throws {
        let coordinator = makeHarness().coordinator
        coordinator.cancel()
        #expect(coordinator.state == .idle)
    }

    // MARK: Failures

    @Test("a missing API key surfaces as .failed(.missingAPIKey), with the raw transcript salvaged")
    func missingAPIKey() async throws {
        let harness = makeHarness(apiKey: nil)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .failed(.missingAPIKey(.openAI)))
        #expect(harness.output.copiedTexts == ["えーっと 生の書き起こし"])
        #expect(coordinator.rawTranscriptSalvaged)
        #expect(coordinator.history.first?.formattedText == "えーっと 生の書き起こし")
        #expect(harness.feedback.events.contains(.failed))
    }

    @Test("an unavailable engine fails during preparation")
    func engineUnavailable() async throws {
        let harness = makeHarness(
            engine: FakeTranscriptionEngine(
                availability: EngineAvailability(
                    status: .needsPermission,
                    detail: "マイクの許可が必要です"
                )
            )
        )
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()

        guard case .failed(let error) = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        guard case .engineUnavailable(_, let detail) = error else {
            Issue.record("expected .engineUnavailable, got \(error)")
            return
        }
        #expect(detail == "マイクの許可が必要です")
        #expect(harness.audio.startCount == 0)
    }

    @Test("an unregistered engine id fails rather than hanging")
    func unknownEngine() async throws {
        var settings = AppSettings()
        settings.transcriptionEngine = .appleSpeechAnalyzer
        let harness = makeHarness(settings: settings)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
    }

    @Test("a provider error fails the run but copies the raw transcript")
    func providerFailure() async throws {
        let harness = makeHarness(
            llmError: .providerHTTPError(provider: "OpenAI", status: 500, body: "boom")
        )
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(
            coordinator.state
                == .failed(.providerHTTPError(provider: "OpenAI", status: 500, body: "boom"))
        )
        // The dictation itself is not lost: the raw transcript is on the
        // clipboard, in the history, and flagged so the UI can say so.
        #expect(harness.output.copiedTexts == ["えーっと 生の書き起こし"])
        #expect(harness.output.pastedTexts.isEmpty)
        #expect(coordinator.rawTranscriptSalvaged)
        #expect(coordinator.history.count == 1)
        #expect(coordinator.history.first?.summary == "整形に失敗・原文をコピー")
        #expect(harness.feedback.events.contains(.failed))
    }

    @Test("with auto-paste on, the salvaged transcript is pasted as well")
    func salvagePastesWhenAutoPasteEnabled() async throws {
        var settings = AppSettings()
        settings.autoPasteEnabled = true
        let harness = makeHarness(
            settings: settings,
            llmError: .providerHTTPError(provider: "OpenAI", status: 500, body: "boom")
        )
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.output.copiedTexts == ["えーっと 生の書き起こし"])
        #expect(harness.output.pastedTexts == ["えーっと 生の書き起こし"])
        #expect(coordinator.rawTranscriptSalvaged)
    }

    @Test("a failed question does not copy the transcript as a substitute answer")
    func askFailureDoesNotSalvage() async throws {
        let harness = makeHarness(
            llmError: .providerHTTPError(provider: "OpenAI", status: 500, body: "boom")
        )
        let coordinator = harness.coordinator

        coordinator.start(action: .ask)
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        guard case .failed = coordinator.state else {
            Issue.record("expected .failed, got \(coordinator.state)")
            return
        }
        #expect(harness.output.copiedTexts.isEmpty)
        #expect(!coordinator.rawTranscriptSalvaged)
        #expect(coordinator.history.isEmpty)
    }

    @Test("the salvage flag is cleared when the next dictation starts")
    func salvageFlagResets() async throws {
        let harness = makeHarness(
            llmError: .providerHTTPError(provider: "OpenAI", status: 500, body: "boom")
        )
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        #expect(coordinator.rawTranscriptSalvaged)

        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(!coordinator.rawTranscriptSalvaged)
    }

    @Test("a non-VoiceInputError is wrapped rather than escaping")
    func errorWrapping() {
        struct Boom: Error {}
        #expect(VoiceInputError.wrapping(Boom()) != .cancelled)
        #expect(VoiceInputError.wrapping(VoiceInputError.emptyTranscript) == .emptyTranscript)
        #expect(VoiceInputError.wrapping(CancellationError()) == .cancelled)
        #expect(
            VoiceInputError.wrapping(URLError(.notConnectedToInternet))
                == .networkFailure(URLError(.notConnectedToInternet).localizedDescription)
        )
    }

    // MARK: Ordering guards

    @Test("a second start while recording is ignored")
    func doubleStart() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.start()
        await coordinator.waitUntilIdle()

        #expect(harness.audio.startCount == 1)
        #expect(coordinator.state == .recording)
    }

    @Test("stop before start is ignored")
    func stopWithoutStart() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.audio.stopCount == 0)
        #expect(harness.output.copiedTexts.isEmpty)
    }

    @Test("a stop issued while the engine is still opening still completes")
    func stopWhilePreparing() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        // No await: the engine is still being opened.
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .idle)
        #expect(harness.output.copiedTexts == ["整形されたテキスト。"])
    }

    @Test("a second stop while transcribing is ignored")
    func doubleStop() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.audio.stopCount == 1)
        #expect(harness.output.copiedTexts.count == 1)
    }

    // MARK: Settings

    @Test("assigning settings persists through the store")
    func settingsPersist() async throws {
        let harness = makeHarness()
        let coordinator = harness.coordinator

        #expect(coordinator.settings.localeIdentifier == "ja-JP")
        coordinator.settings.localeIdentifier = "en-US"

        #expect(coordinator.settings.localeIdentifier == "en-US")
        #expect(harness.settingsStore.load().localeIdentifier == "en-US")
    }

    @Test("settings are loaded from the store at init")
    func settingsLoaded() {
        let harness = makeHarness(settings: AppSettings(localeIdentifier: "en-GB"))
        #expect(harness.coordinator.settings.localeIdentifier == "en-GB")
    }

    @Test("playSounds = false silences feedback")
    func silentFeedback() async throws {
        var settings = AppSettings()
        settings.playSounds = false
        let harness = makeHarness(settings: settings)
        let coordinator = harness.coordinator

        coordinator.start()
        await coordinator.waitUntilIdle()
        coordinator.stopAndProcess()
        await coordinator.waitUntilIdle()

        #expect(harness.feedback.events.isEmpty)
    }

    // MARK: Preparation timeout

    @Test("preparation that never completes fails with preparationTimedOut")
    func preparationTimesOut() async throws {
        let engine = StallingEngine()
        let harness = makeHarness(engine: engine)
        let coordinator = harness.coordinator
        coordinator.preparationTimeout = 0.05

        coordinator.start()
        await coordinator.waitUntilIdle()

        #expect(coordinator.state == .failed(.preparationTimedOut))
        #expect(harness.feedback.events == [.failed])

        // The stuck first attempt must not block a retry: the next start()
        // reaches the engine again with a fresh session request.
        coordinator.start()
        #expect(coordinator.state == .preparing)
        await coordinator.waitUntilIdle()
        #expect(engine.makeSessionCalls == 2)
    }

    @Test("a session that opens after the timeout is cancelled, not leaked")
    func lateSessionIsCancelled() async throws {
        let engine = StallingEngine(sessionDelay: .milliseconds(150))
        let harness = makeHarness(engine: engine)
        let coordinator = harness.coordinator
        coordinator.preparationTimeout = 0.05

        coordinator.start()
        await coordinator.waitUntilIdle()
        #expect(coordinator.state == .failed(.preparationTimedOut))

        var attempts = 100
        while engine.createdSession == nil, attempts > 0 {
            try await Task.sleep(for: .milliseconds(10))
            attempts -= 1
        }
        let session = try #require(engine.createdSession)

        attempts = 100
        while (await session.wasCancelled) == false, attempts > 0 {
            try await Task.sleep(for: .milliseconds(10))
            attempts -= 1
        }
        #expect(await session.wasCancelled)
    }
}

/// An engine whose `makeSession` stalls, like a wedged speech daemon.
private final class StallingEngine: TranscriptionEngine, @unchecked Sendable {
    let id: TranscriptionEngineID = .appleOnDevice
    let displayName = "応答しないエンジン"
    let supportsStreamingPartials = false

    /// `nil`: never returns (gives up only when its task is cancelled).
    /// Otherwise: a session appears after this long, *surviving cancellation* —
    /// an XPC reply that arrives after the caller stopped waiting.
    private let sessionDelay: Duration?
    private let storedSession = OSAllocatedUnfairLock<FakeTranscriptionSession?>(initialState: nil)
    private let storedCalls = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(sessionDelay: Duration? = nil) {
        self.sessionDelay = sessionDelay
    }

    var createdSession: FakeTranscriptionSession? { storedSession.withLock { $0 } }
    var makeSessionCalls: Int { storedCalls.withLock { $0 } }

    func availability(locale: Locale) async -> EngineAvailability { .available }

    func makeSession(
        configuration: TranscriptionConfiguration
    ) async throws -> any TranscriptionSession {
        storedCalls.withLock { $0 += 1 }

        guard let sessionDelay else {
            try await Task.sleep(for: .seconds(3600))
            throw VoiceInputError.cancelled
        }
        let clock = ContinuousClock()
        let deadline = clock.now + sessionDelay
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let session = FakeTranscriptionSession(
            transcript: "遅れて届いた結果",
            partials: [],
            engine: id,
            locale: configuration.locale.identifier,
            finishError: nil
        )
        storedSession.withLock { $0 = session }
        return session
    }
}
