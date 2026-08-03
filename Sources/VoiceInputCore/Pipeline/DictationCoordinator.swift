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

    /// A formatting style chosen for the dictation in flight — by a style
    /// shortcut, or in the HUD while recording.
    ///
    /// Deliberately **not** persisted: picking a style here is a one-off, and the
    /// default in Settings/the menu is only ever changed explicitly there.
    /// Cleared at the start of every dictation.
    public private(set) var styleOverrideID: UUID?

    /// What the run in flight will do with the transcript — set by whichever
    /// shortcut started it, and switchable while audio is still being captured.
    ///
    /// Observable because the HUD has to say 「回答を作成中…」 rather than
    /// 「整形中…」 for a question; the state machine itself is the same either way.
    public private(set) var currentAction: VoiceActionID = .format

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

    /// `styleID` names a formatting style for this dictation only.
    ///
    /// While recording, a *different* action or style switches the run in flight
    /// instead of ending it — pressing another shortcut mid-sentence is a
    /// correction, not a stop. So the question shortcut turns a dictation already
    /// under way into a question, and the dictation shortcut turns it back. The
    /// same shortcut pressed twice stops.
    public func toggle(action: VoiceActionID = .format, styleID: UUID? = nil) {
        if isCapturing {
            if action != currentAction {
                selectAction(action)
            } else if let styleID, styleID != effectiveStyleID {
                selectStyle(styleID)
            } else {
                stopAndProcess()
            }
        } else if !state.isBusy {
            start(action: action, styleID: styleID)
        }
    }

    public func start(action: VoiceActionID = .format, styleID: UUID? = nil) {
        // Guard against double-start: a second hotkey press while transcribing
        // must not open a second session.
        guard !state.isBusy, startTask == nil, processTask == nil else { return }

        currentAction = action
        styleOverrideID = settings.style(withID: styleID)?.id
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
        guard isCapturing, processTask == nil else { return }

        processTask = Task { [weak self] in
            await self?.finishAndRun()
            self?.processTask = nil
        }
    }

    /// Switches the style used by the dictation in flight. Ignored once the
    /// transcript has been handed to the action — by then the choice is spent.
    public func selectStyle(_ id: UUID) {
        guard isCapturing, let style = settings.style(withID: id) else { return }
        styleOverrideID = style.id
    }

    /// Switches what happens to the recording in flight — 「これは質問にする」.
    /// Ignored once audio has stopped, and ignored for an action that is not
    /// registered, so a stale shortcut cannot strand a recording.
    public func selectAction(_ id: VoiceActionID) {
        guard isCapturing, actions.action(for: id) != nil else { return }
        currentAction = id
    }

    /// The style this dictation will be formatted with: the one-off override when
    /// there is one, otherwise the default from Settings.
    public var effectiveStyle: FormattingStyle? {
        settings.style(withID: styleOverrideID) ?? settings.activeStyle
    }

    public var effectiveStyleID: UUID? { effectiveStyle?.id }

    /// Clears a result the user has finished reading. No-op unless the pipeline is
    /// sitting in `.finished`, so it cannot cut short a run in flight.
    public func dismissFinished() {
        guard case .finished = state else { return }
        state = .idle
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
        styleOverrideID = nil
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

            // Character counts, never the text: they are what tells a truncation in
            // the recognizer apart from one in the LLM rewrite.
            Self.log.notice(
                """
                finished: action=\(actionID.rawValue, privacy: .public) \
                engine=\(transcript.engine.rawValue, privacy: .public) \
                rawChars=\(transcript.text.count, privacy: .public) \
                outputChars=\(outcome.text.count, privacy: .public) \
                seconds=\(transcript.duration, format: .fixed(precision: 1), privacy: .public)
                """
            )

            record(transcript: transcript, outcome: outcome)
            partialText = ""
            styleOverrideID = nil
            state = .finished(outcome)
            notify(.finished)

            // A persistent result waits for `dismissFinished()`: it is on screen to
            // be read, and a timer cannot know when the user is done reading.
            guard outcome.presentation == .transient else { return }
            if finishedStateDuration > .zero {
                try? await Task.sleep(for: finishedStateDuration)
            }
            if case .finished = state { state = .idle }
        } catch {
            handle(error)
        }
    }

    // MARK: - Helpers

    /// Recording, or opening the engine in order to record. The hotkey and the HUD
    /// use it to decide between starting, switching style, and stopping.
    public var isCapturing: Bool {
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
        // The override travels as a *copy* of the settings, never through the
        // store: a style picked for one dictation must not become the default.
        let settings = settings.selectingStyle(styleOverrideID)
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
        styleOverrideID = nil

        if wrapped == .cancelled {
            state = .idle
            return
        }
        // The kind is content-free and public so a failure is diagnosable from the
        // log; the description can echo user speech, so it stays private.
        Self.log.error(
            """
            dictation failed: \(wrapped.kind, privacy: .public) \
            detail: \(String(describing: wrapped), privacy: .private)
            """
        )
        state = .failed(wrapped)
        notify(.failed)
    }

    private func notify(_ event: FeedbackEvent) {
        guard settings.playSounds, let feedback else { return }
        feedback.played(event)
    }
}
