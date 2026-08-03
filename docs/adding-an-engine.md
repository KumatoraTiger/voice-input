# Adding a transcription engine

Referenced from `Sources/VoiceInputCore/Contracts/Transcription.swift`.
Slash command: `/add-engine`.

## Decide where it lives

| The engine is… | Target | Folder |
|---|---|---|
| pure HTTP / `URLSession` | `VoiceInputCore` | `Sources/VoiceInputCore/ASR/` |
| an Apple framework (Speech, AVFoundation…) | `VoiceInputPlatform` | `Sources/VoiceInputPlatform/Engines/` |

Core must not import Speech or AVFoundation. If in doubt, it goes in Platform.

## Steps

1. **Add the id.** New case in `TranscriptionEngineID`
   (`Sources/VoiceInputCore/Contracts/Transcription.swift`). The raw value is
   persisted in `AppSettings` and used to key its Keychain entry
   (`SecretKey.transcriptionAPIKey(for:)`), so **never rename an existing one**.

2. **Implement `TranscriptionSession`.** Lifecycle contract:
   `makeSession` → repeated `append(_:)` → exactly one of `finish()` / `cancel()`.
   Single-use. `partialTranscripts` is an `AsyncStream<String>` that must finish
   when the session ends — return an empty finished stream if the backend has no
   partials.

3. **Implement `TranscriptionEngine`.** `supportsStreamingPartials` drives the UI.
   `availability(locale:)` must be specific: `.needsAPIKey`, `.needsPermission`,
   `.unsupportedOS(...)`, `.unsupportedLocale(...)` — never a generic
   `.unavailable` when you know the real reason, because Settings shows it verbatim.

4. **Register it.** `PlatformEngineRegistry`
   (`Sources/VoiceInputPlatform/Engines/PlatformEngineRegistry.swift`). If the
   engine cannot exist on the current OS or SDK, register an `UnavailableEngine`
   with a reason instead of omitting it — a greyed-out entry that explains itself
   beats a missing one. `StaticEngineResolver` is the fake used by tests.

5. **Audio format.** Everything is fed mono 32-bit float PCM at 16 kHz
   (`AudioStreamFormat.capture`). Convert inside your session; do not change the
   capture format.

6. **Secrets.** If the engine needs a key, read it through `SecretStore` with
   `SecretKey.transcriptionAPIKey(for:)`. Never accept a key as a literal, never log
   it, and truncate any provider error body before putting it in
   `VoiceInputError.providerHTTPError`.

7. **Compile-time gating.** If the API only exists in a newer SDK, follow the
   `SPEECH_ANALYZER` pattern: an env var read in `Package.swift`, `#if` around the
   implementation, an `UnavailableEngine` in the `#else` branch, and detection in
   `Scripts/build_app.sh`.

8. **Tests.** `Tests/VoiceInputCoreTests/`. Network engines are tested through
   `StubURLProtocol` — never against a live endpoint. Cover: happy path, empty
   transcript, non-2xx, cancel-before-finish.

9. **Docs.** Add the engine to `docs/ENGINES.md` including the decision table
   (cost / privacy / accuracy / OS requirement) and to `docs/SECURITY.md` if it
   sends anything off-device.
