---
description: Add a new TranscriptionEngine (speech-to-text backend) end to end
---

Add a speech-to-text engine. Reference: `docs/adding-an-engine.md`.

Ask first if it is not obvious from the request: which backend, is it cloud or
local, does it need an API key, does it stream partial results.

## Files to touch, in order

1. **`Sources/VoiceInputCore/Contracts/Transcription.swift`**
   Add a case to `TranscriptionEngineID`. The raw value is persisted in
   `AppSettings` and keys the Keychain entry via
   `SecretKey.transcriptionAPIKey(for:)` — **never rename an existing case.**

2. **The implementation.** Pick the target by what it imports:
   - pure `URLSession`/HTTP → `Sources/VoiceInputCore/ASR/<Name>Engine.swift`
     (model it on `OpenAITranscriptionEngine.swift`; take `URLSession` in the
     initializer so tests can stub it);
   - anything importing Speech/AVFoundation → `Sources/VoiceInputPlatform/Engines/`.

   `VoiceInputCore` must not import AppKit, AVFoundation, Speech or Carbon.

   Implement both `TranscriptionEngine` and `TranscriptionSession`. Session
   lifecycle: `makeSession` → repeated `append(_:)` → exactly one of `finish()` /
   `cancel()`; single-use; `partialTranscripts` must finish when the session ends
   (return an already-finished empty stream if the backend has no partials).

3. **`availability(locale:)` must be specific**: `.needsAPIKey`, `.needsPermission`,
   `.unsupportedOS(...)`, `.unsupportedLocale(...)`. Settings shows the reason
   verbatim to the user — a generic `.unavailable` is a bad answer when you know why.

4. **`Sources/VoiceInputPlatform/Engines/PlatformEngineRegistry.swift`**
   Register it. If it cannot exist on this OS/SDK, register an `UnavailableEngine`
   with a clear reason rather than omitting it.

5. **Audio**: everything is fed mono 32-bit float PCM at 16 kHz
   (`AudioStreamFormat.capture`). Convert inside your session; do not change the
   capture format. `WAVEncoder` exists in Core if you need a WAV upload.

6. **Secrets**: read keys only through `SecretStore`. Never log a key, never put one
   in an error. Truncate any provider error body before it reaches
   `VoiceInputError.providerHTTPError`.

7. **Newer-SDK APIs**: follow the `SPEECH_ANALYZER` pattern — env var in
   `Package.swift`, `#if` around the implementation, `UnavailableEngine` in `#else`,
   detection in `Scripts/build_app.sh`. Say clearly that the gated branch is not
   compiled locally.

8. **Tests** in `Tests/VoiceInputCoreTests/` (use `StubURLProtocol` for HTTP):
   happy path, empty transcript, non-2xx mapping, cancel before finish.

9. **Docs**: add the engine to `docs/ENGINES.md` including the decision table
   (cost / privacy / accuracy / OS requirement) and say which is default; update the
   "what leaves your machine" table in `docs/SECURITY.md` and the engine table in
   `README.md` if anything now leaves the device.

Finish with `make check` and report what you could not verify.
