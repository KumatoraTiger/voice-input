import Foundation
import Observation
import os

/// The spine of the app: owns the state machine that capture, transcription,
/// the action and the output sink all hang off.
///
/// Everything is injected, so the whole pipeline can be exercised in tests with
/// fakes and no I/O.
@MainActor
@Observable
public final class DictationCoordinator {
    // MARK: Observable state

    public private(set) var state: DictationState = .idle
    public private(set) var partialText: String = ""
    public private(set) var inputLevel: Float = 0
    public private(set) var history: [DictationRecord] = []

    /// Assigning persists through the injected `SettingsStore`.
    public var settings: AppSettings {
        get { storedSettings }
        set {
            storedSettings = newValue
            trimHistory()
            do {
                try settingsStore.save(newValue)
            } catch {
                Self.log.error("設定を保存できませんでした: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Run once before each capture, to request microphone / speech permission.
    ///
    /// Core cannot touch TCC itself, so the app injects
    /// `PermissionsService.requireDictationPermissions`. Throwing here surfaces as a
    /// normal failure state — without it a first run would fail with a confusing
    /// "engine unavailable" instead of prompting.
    public var preflight: (@MainActor @Sendable () async throws -> Void)?

    /// Supplies the name of the app that was frontmost when recording started, so an
    /// action can adapt to its target. Set by the app layer; nil in tests.
    public var frontmostAppNameProvider: (@MainActor @Sendable () -> String?)?

    /// How long `.finished` lingers before returning to `.idle`, so the HUD has
    /// something to show. Tests set this to zero.
    public var finishedStateDuration: Duration = .milliseconds(800)

    // MARK: Dependencies

    private let audio: any AudioCapturing
    private let engines: any TranscriptionEngineResolving
    private let providers: LLMProviderRegistry
    private let actions: ActionRegistry
    private let settingsStore: any SettingsStore
    private let secrets: any SecretStore
    private let output: any OutputSink
    private let feedback: (any FeedbackPresenting)?

    // MARK: Private state

    private var storedSettings: AppSettings
    @ObservationIgnored private var session: (any TranscriptionSession)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var captureTask: Task<Void, Never>?
    @ObservationIgnored private var partialsTask: Task<Void, Never>?
    @ObservationIgnored private var currentAction: VoiceActionID = .format
    @ObservationIgnored private var capturedFrontmostAppName: String?

    private static let log = Logger(subsystem: "io.github.voiceinput", category: "pipeline")

    public init(
        audio: any AudioCapturing,
        engines: any TranscriptionEngineResolving,
        providers: LLMProviderRegistry,
        actions: ActionRegistry = .live,
        settingsStore: any SettingsStore,
        secrets: any SecretStore,
        output: any OutputSink,
        feedback: (any FeedbackPresenting)? = nil
    ) {
        self.audio = audio
        self.engines = engines
        self.providers = providers
        self.actions = actions
        self.settingsStore = settingsStore
        self.secrets = secrets
        self.output = output
        self.feedback = feedback
        self.storedSettings = settingsStore.load()
    }

    // MARK: - Commands

    public func toggle(action: VoiceActionID = .format) {
        if isRecordingOrPreparing {
            stopAndProcess()
        } else if !state.isBusy {
            start(action: action)
        }
    }

    public func start(action: VoiceActionID = .format) {
        // Guard against double-start: a second hotkey press while transcribing
        // must not open a second session.
        guard !state.isBusy, startTask == nil, processTask == nil else { return }

        currentAction = action
        partialText = ""
        inputLevel = 0
        state = .preparing

        startTask = Task { [weak self] in
            await self?.beginCapture()
            self?.startTask = nil
        }
    }

    public func stopAndProcess() {
        // Guard against out-of-order stop.
        guard isRecordingOrPreparing, processTask == nil else { return }

        processTask = Task { [weak self] in
            await self?.finishAndRun()
            self?.processTask = nil
        }
    }

    public func cancel() {
        startTask?.cancel()
        processTask?.cancel()
        partialsTask?.cancel()
        captureTask?.cancel()
        startTask = nil
        processTask = nil
        partialsTask = nil
        captureTask = nil

        audio.stop()
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }

        partialText = ""
        inputLevel = 0
        state = .idle
        notify(.cancelled)
    }

    /// Test / preview helper: awaits any in-flight pipeline work.
    public func waitUntilIdle() async {
        await startTask?.value
        await processTask?.value
    }

    // MARK: - Pipeline

    private func beginCapture() async {
        do {
            capturedFrontmostAppName = frontmostAppNameProvider?()
            try await preflight?()
            let engine = try resolveEngine()
            let locale = settings.locale
            let availability = await engine.availability(locale: locale)
            guard availability.isUsable else {
                throw VoiceInputError.engineUnavailable(
                    engine.id,
                    availability.detail ?? "現在は利用できません。"
                )
            }

            let configuration = TranscriptionConfiguration(
                locale: locale,
                format: .capture,
                contextualStrings: settings.vocabulary,
                model: settings.transcriptionModel.nilIfEmpty
            )
            let session = try await engine.makeSession(configuration: configuration)
            self.session = session

            guard state == .preparing else {
                // Cancelled while the engine was warming up.
                await session.cancel()
                self.session = nil
                return
            }

            let stream = try audio.start(format: configuration.format)
            state = .recording
            notify(.recordingStarted)

            partialsTask = Task { [weak self] in
                for await partial in session.partialTranscripts {
                    guard let self, !Task.isCancelled else { return }
                    self.partialText = partial
                }
            }
            captureTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self, !Task.isCancelled else { return }
                    await session.append(buffer)
                    self.inputLevel = self.audio.level
                }
            }
        } catch {
            handle(error)
        }
    }

    private func finishAndRun() async {
        // A stop that arrives while the engine is still opening waits for it.
        await startTask?.value
        guard state == .recording else { return }

        state = .transcribing
        notify(.recordingStopped)

        do {
            audio.stop()
            await captureTask?.value
            captureTask = nil
            partialsTask?.cancel()
            partialsTask = nil
            inputLevel = 0

            guard let session else { throw VoiceInputError.transcriptionFailed("録音セッションがありません。") }
            self.session = nil

            let transcript = try await session.finish()

            let actionID = effectiveActionID(currentAction)
            guard let action = actions.action(for: actionID) else {
                throw VoiceInputError.transcriptionFailed("アクション \(actionID.rawValue) が登録されていません。")
            }
            if action.requiresLLM { state = .formatting }

            let outcome = try await action.run(
                transcript: transcript,
                context: makeContext(for: action)
            )

            if outcome.copyToClipboard {
                try output.copy(outcome.text)
            }
            if outcome.pasteIntoFrontmostApp, settings.autoPasteEnabled, output.canPaste {
                try await output.paste(outcome.text)
            }

            record(transcript: transcript, outcome: outcome)
            partialText = ""
            state = .finished(outcome)
            notify(.finished)

            if finishedStateDuration > .zero {
                try? await Task.sleep(for: finishedStateDuration)
            }
            if case .finished = state { state = .idle }
        } catch {
            handle(error)
        }
    }

    // MARK: - Helpers

    private var isRecordingOrPreparing: Bool {
        state == .preparing || state == .recording
    }

    private func resolveEngine() throws -> any TranscriptionEngine {
        guard let engine = engines.engine(for: settings.transcriptionEngine) else {
            throw VoiceInputError.engineUnavailable(
                settings.transcriptionEngine,
                "このビルドには含まれていません。"
            )
        }
        return engine
    }

    /// `formattingEnabled == false` means "skip the LLM entirely".
    private func effectiveActionID(_ id: VoiceActionID) -> VoiceActionID {
        (id == .format && !settings.formattingEnabled) ? .raw : id
    }

    private func makeContext(for action: any VoiceAction) -> ActionContext {
        guard action.requiresLLM else {
            return ActionContext(settings: settings, frontmostAppName: capturedFrontmostAppName)
        }
        let provider = providers.provider(for: settings.llmProvider)
        let key = provider.flatMap { try? secrets.secret(for: .apiKey(for: $0.id)) } ?? nil
        return ActionContext(
            settings: settings,
            llm: provider,
            apiKey: key,
            frontmostAppName: capturedFrontmostAppName
        )
    }

    /// Applies `historyLimit` to what is already retained, so lowering the limit in
    /// Settings takes effect immediately rather than at the next dictation.
    private func trimHistory() {
        guard storedSettings.historyLimit > 0 else {
            history = []
            return
        }
        if history.count > storedSettings.historyLimit {
            history.removeLast(history.count - storedSettings.historyLimit)
        }
    }

    private func record(transcript: Transcript, outcome: ActionOutcome) {
        guard settings.historyLimit > 0 else {
            history = []
            return
        }
        history.insert(
            DictationRecord(
                rawText: transcript.text,
                formattedText: outcome.text,
                date: Date(),
                summary: outcome.summary
            ),
            at: 0
        )
        if history.count > settings.historyLimit {
            history.removeLast(history.count - settings.historyLimit)
        }
    }

    private func handle(_ error: Error) {
        let wrapped = VoiceInputError.wrapping(error)

        audio.stop()
        captureTask?.cancel()
        partialsTask?.cancel()
        captureTask = nil
        partialsTask = nil
        if let session {
            self.session = nil
            Task { await session.cancel() }
        }
        inputLevel = 0

        if wrapped == .cancelled {
            state = .idle
            return
        }
        // Detail strings can echo user speech, so never log them.
        Self.log.error("dictation failed: \(String(describing: wrapped), privacy: .private)")
        state = .failed(wrapped)
        notify(.failed)
    }

    private func notify(_ event: FeedbackEvent) {
        guard settings.playSounds, let feedback else { return }
        feedback.played(event)
    }
}
