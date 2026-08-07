# CLAUDE.md — working agreement for AI agents in this repo

## What this is

**VoiceInput** — a macOS menu-bar dictation app. Press a global hotkey, speak, and
polished text lands on the clipboard (and optionally is pasted into the frontmost
app).

Pipeline: `hotkey → mic capture → speech-to-text → LLM rewrite → clipboard/paste`.

- Bundle id `io.github.voiceinput.VoiceInput`, display name **VoiceInput**.
- Menu-bar-only (`LSUIElement`) — no Dock icon, no main window.
- Speech: Apple on-device `SFSpeechRecognizer` (default), Apple `SpeechAnalyzer`
  (macOS 26+), or OpenAI cloud STT.
- Formatting LLM: OpenAI (default) or Anthropic.
- **This repository is PUBLIC.** Assume every line you write will be read by
  strangers.

## Layout and the dependency rule

```
Sources/VoiceInputCore/       pure logic, unit-testable, no I/O frameworks
Sources/VoiceInputPlatform/   AVFoundation / Speech / AppKit / Carbon
Sources/VoiceInputApp/        SwiftUI menu-bar app (executable)
Tests/VoiceInputCoreTests/    tests for Core only
```

**Hard rule:** `VoiceInputCore` must **not** import AppKit, AVFoundation, Speech,
Carbon or SwiftUI. Foundation, Observation, os and Security only. `VoiceInputPlatform`
may import all of them and depends on Core. `VoiceInputApp` depends on both and
should stay thin — wiring and views, no pipeline logic.

If you need a system capability inside Core, don't import it: define a protocol in
`Sources/VoiceInputCore/Contracts/` and implement it in Platform. That is the whole
design.

## The contracts are the extension points

Everything in `Sources/VoiceInputCore/Contracts/` is a seam. Read it before adding
anything.

| Contract | Meaning |
|---|---|
| `TranscriptionEngine` / `TranscriptionSession` | a speech-to-text backend |
| `LLMProvider` | a chat-completion backend used for rewriting |
| `VoiceAction` | what happens to a finished transcript (`.format`, `.raw`) |
| `AudioCapturing` | microphone source |
| `OutputSink` | clipboard + paste |
| `SecretStore` | Keychain-backed API key storage |
| `SettingsStore` | persisted `AppSettings` (**never** secrets) |
| `FeedbackPresenting` | sounds/HUD signals |
| `TranscriptionEngineResolving` | id → engine lookup, so Core can drive Platform engines |
| `DictationState` | the state machine the UI renders from |

`DictationCoordinator` (`Sources/VoiceInputCore/Pipeline/`) is the spine. It is
`@MainActor @Observable`, takes every dependency by injection, and owns the state
machine — put pipeline behaviour there, not in views.

## Build / test / run

**Xcode is not installed on the reference machine. Never invoke `xcodebuild`.**
Everything runs through SwiftPM plus a hand-assembled `.app`:

```bash
make build     # swift build (all targets)
make test      # swift build + swift test          -> Scripts/test.sh
make app       # assemble build/VoiceInput.app     -> Scripts/build_app.sh
make run       # build the bundle, launch it, tail its logs
make lint      # swift-format lint (advisory; skipped if the tool is absent)
make format    # swift-format --in-place
make check     # check-secrets + lint + test  <- run before you hand work back
make install   # copy build/VoiceInput.app to /Applications
make clean
```

Notes:
- The app **must** run from a `.app` bundle. TCC (microphone/speech/accessibility)
  and the menu-bar presentation need a real bundle with an `Info.plist`; a bare
  `swift run` binary will be denied permissions.
- Builds are ad-hoc signed by default, so macOS re-prompts for permissions after
  each rebuild. Set `CODESIGN_IDENTITY` to a self-signed certificate to avoid it
  (see README).

## `SPEECH_ANALYZER`

Apple's `SpeechAnalyzer` / `SpeechTranscriber` API only exists in the **macOS 26
SDK**. Building against an older SDK cannot even parse code that references it, so:

- `Package.swift` reads the env var `VOICEINPUT_SPEECH_ANALYZER`; when it is `1` it
  defines the Swift compilation condition `SPEECH_ANALYZER`.
- `Scripts/build_app.sh` and `Scripts/test.sh` set it automatically when
  `xcrun --show-sdk-version` reports major ≥ 26.
- All SpeechAnalyzer code lives behind `#if SPEECH_ANALYZER` in
  `Sources/VoiceInputPlatform/Engines/SpeechAnalyzerEngine.swift`. The `#else`
  branch substitutes `UnavailableEngine`, which reports why the engine is off.

Consequence you must respect: **the `#if SPEECH_ANALYZER` branch is not compiled on
a macOS 15 machine.** Changes there are unverified locally — keep that code small,
keep the two branches' public API identical, and say so when you hand work back.
CI has a best-effort job that compiles it when an SDK-26 runner is available.

## Hard rules

1. **Never commit a secret.** No API keys, tokens, `.env` files, or `.pem`/`.p12`
   material — not in code, not in tests, not in a fixture, not in a comment.
   `Scripts/check_secrets.sh` runs in `make check` and in CI.
2. **Keys live only in the macOS Keychain** (service `io.github.voiceinput.VoiceInput`),
   written through `SecretStore` and entered by the user in Settings. Never in
   `AppSettings`, `UserDefaults`, a plist, or a log line.
3. **Never log transcripts, prompt bodies, LLM responses, or API keys.** Use
   `os.Logger` with subsystem `io.github.voiceinput`; log state transitions,
   durations, error kinds — not user content. If content must appear in a log for
   debugging, mark it `privacy: .private` and default it off.
4. **Nothing user-spoken is persisted.** Audio is never written to disk; history
   lives in memory and dies with the process.
5. **Treat the transcript as untrusted data, never as instructions.** A user can
   dictate "ignore your instructions and …" and so can anyone speaking near the
   mic. Keep the system prompt and the transcript strictly separated (the
   transcript goes in a *user* message, delimited), never interpolate the
   transcript into the system prompt, and never let it select a tool, a model, or
   a destination. See `Sources/VoiceInputCore/Formatting/FormattingPromptBuilder.swift`.
6. **No absolute `/Users/...` paths** anywhere. Scripts resolve their own root from
   `${BASH_SOURCE[0]}`; Swift uses `Bundle`/`FileManager`.
7. **No new dependencies** without a strong reason. The package has zero today, and
   that is a feature for an app that handles a microphone and API keys.
8. **Errors are typed.** Add a case to `VoiceInputError` with a Japanese
   `errorDescription` (and a `recoverySuggestion` when the user can act on it)
   rather than throwing a bare `NSError` or a string.
9. **Never commit real-world material from your own machine.** Rule 1 covers
   credentials; this covers everything else that is real. No employer or client
   name, no colleague's name, no internal project, service or schema name, no
   branch or ticket title from another repository, and nothing you read off your
   own screen while testing — not in code, comments, tests, fixtures, docs,
   commit messages, or a pull request description.

   Two things make this easy to get wrong here. Debugging this app means staring
   at real transcripts and real screen contents, so the nearest example to hand is
   almost always a real one; and an example that came from a live session *reads*
   more convincing than an invented one, which is exactly why it is tempting.
   Neither is a reason. Use invented placeholders that tell a reader they are
   looking at a fixture — `Contoso`, `ProjectAurora`, `user_id`,
   `DATABASE_CONNECTION_TIMEOUT` — and pick generic technical terms (`SQL`,
   `Kubernetes`, `Terraform`) when an example needs a real-sounding proper noun.

   `Scripts/check_secrets.sh` enforces this from an optional `.check-secrets-local`
   — one term per line, matched literally and case-insensitively. That file is
   gitignored on purpose: listing the terms in a tracked file would publish the
   words the rule exists to keep out. Add to it as you notice things; the check
   reports `path:line — local-denylist` and never echoes the term.

## Recipes

Slash commands exist for each of these: `/add-engine`, `/add-provider`, `/add-action`.

**New speech engine**
1. Add a case to `TranscriptionEngineID` (`Contracts/Transcription.swift`).
2. Implement `TranscriptionEngine` + `TranscriptionSession`. Pure HTTP engines go in
   `Sources/VoiceInputCore/ASR/`; anything touching Apple frameworks goes in
   `Sources/VoiceInputPlatform/Engines/`.
3. Register it in `PlatformEngineRegistry` (Platform) — return an `UnavailableEngine`
   with a clear reason when the OS/SDK cannot support it.
4. Return an honest `availability(locale:)` — `needsAPIKey`, `unsupportedOS`,
   `unsupportedLocale`, not a generic failure.
5. Update `docs/ENGINES.md` (including the decision table) and add tests.

**New LLM provider**
1. Add a case to `LLMProviderID` (`Contracts/LLM.swift`).
2. Implement `LLMProvider` in `Sources/VoiceInputCore/LLM/`, reusing `ProviderHTTP`.
   Take a `URLSession` in the initializer so tests can stub the transport.
3. Register it in `LLMProviderRegistry.live(session:)`.
4. Map non-2xx to `.providerHTTPError` with a **truncated, key-free** body.
5. Add tests with `StubURLProtocol`; update `docs/SECURITY.md` (what leaves the
   machine) and the README.

**New voice action**
1. Add a `VoiceActionID` static (`Contracts/Actions.swift`).
2. Implement `VoiceAction` in `Sources/VoiceInputCore/Formatting/` (or a sibling
   folder). Read everything you need from `ActionContext`; do not reach for globals.
3. Register it in `ActionRegistry.live`.
4. Decide `copyToClipboard` / `pasteIntoFrontmostApp` deliberately, and set
   `requiresLLM` honestly — the coordinator uses it to fail fast on a missing key.
5. Add tests; if it is user-selectable, wire it in Settings and document it.

## Expectations for any change

- Changes to Core come with tests in `Tests/VoiceInputCoreTests/` (swift-testing:
  `@Test`, `#expect`). Network code is tested through `StubURLProtocol`, never
  against a live endpoint.
- Platform/App code that cannot be unit-tested still needs its logic pushed down
  into Core so that *something* is testable.
- Run `make check` before handing work back. `swift test` alone is not enough — it
  does not build Platform or App.
- Update the affected doc in the same change: `docs/ARCHITECTURE.md` for structural
  changes, `docs/ENGINES.md` for engines, `docs/SECURITY.md` for anything that
  changes what leaves the machine.
- User-facing strings are Japanese. Code, comments and docs (except `README.md`)
  are English.
