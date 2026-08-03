# Security and privacy

VoiceInput listens to a microphone, holds API keys, and can type into other
applications. This document states exactly what it does with each of those.

## API keys

- Keys are stored in the **macOS Keychain**, service
  `io.github.voiceinput.VoiceInput`, through `SecretStore`
  (`Sources/VoiceInputCore/Secrets/KeychainSecretStore.swift`).
- Each key is a separate item, so an OpenAI key used only for transcription and an
  Anthropic key used only for formatting stay independent:
  - `llm.apiKey.openAI`, `llm.apiKey.anthropic`
  - `asr.apiKey.openAICloud`
- Keys are entered by the user in the app's Settings window. There is **no `.env`,
  no config file and no build-time key** in this project.
- Keys are never written to `UserDefaults`, never included in `AppSettings` (which
  is deliberately safe to log, export and diff), never logged, and never included in
  an error message. `VoiceInputError.providerHTTPError` carries a **truncated**
  response body precisely so a key echoed back by a provider cannot leak through it.
- Revoking is done at the provider; deleting the key in Settings removes the
  Keychain item.

## What leaves your machine

| Transcription engine | LLM formatting | Audio leaves | Transcript leaves | Destination |
|---|---|---|---|---|
| Apple on-device | off (`raw` / 整形オフ) | no | no | — nothing leaves the Mac |
| Apple SpeechAnalyzer | off | no | no | — nothing leaves the Mac |
| Apple on-device | OpenAI | no | **yes** | `api.openai.com` |
| Apple on-device | Anthropic | no | **yes** | `api.anthropic.com` |
| Apple SpeechAnalyzer | OpenAI / Anthropic | no | **yes** | as above |
| OpenAI cloud STT | off | **yes** | **yes** (returned text) | `api.openai.com` |
| OpenAI cloud STT | OpenAI | **yes** | **yes** | `api.openai.com` |
| OpenAI cloud STT | Anthropic | **yes** (to OpenAI) | **yes** (to Anthropic) | both |

Read it as: **audio only ever leaves the machine if you select the OpenAI cloud
engine. Text only ever leaves the machine if LLM formatting is enabled.** Turn both
off (Apple engine + 整形オフ) and the app makes no network requests at all.

What is sent, precisely:

- **Cloud STT:** the recorded audio as a WAV, plus the model name, the locale, and
  any vocabulary terms you configured. No identifiers beyond your API key.
- **LLM formatting:** the system prompt (the built-in instruction plus your selected
  style's instructions) and the raw transcript as a user message. Nothing else — no
  clipboard contents, no window titles, no file paths, no telemetry.
- **Nothing at all** is sent to any endpoint the user did not select. The app has no
  analytics, no crash reporter, no update check, and no first-party server.

Once data reaches a provider, that provider's policy governs it. Read the relevant
one before enabling a cloud path:
<https://openai.com/policies/> · <https://www.anthropic.com/legal/privacy>.

## What is never persisted

- **Audio** is never written to disk. It is captured into memory, streamed to the
  engine, and discarded. The cloud engine builds its WAV in memory and drops it
  after the request.
- **Transcripts and formatted text** are never written to disk. The history in the
  menu (`DictationRecord`) lives in memory only, is capped by
  `AppSettings.historyLimit`, and dies with the process.
- **Logs never contain user content.** The app logs through `os.Logger` with
  subsystem `io.github.voiceinput`: state transitions, durations, engine ids and
  error kinds. Transcripts, prompt bodies, LLM responses and keys must never be
  logged — if content is ever logged for debugging it must be marked
  `privacy: .private` and left off by default.
- The only things on disk are `AppSettings` in `UserDefaults` (no secrets) and the
  Keychain items.

## Prompt injection: the transcript is data, never instructions

Anything the microphone hears becomes an LLM prompt. That includes speech from the
person at the keyboard, someone else in the room, and audio playing nearby. So:

- The transcript is **always** passed as a *user* message, delimited, never
  interpolated into the system prompt. See
  `Sources/VoiceInputCore/Formatting/FormattingPromptBuilder.swift`.
- The transcript is fenced in `<transcript>` … `</transcript>`, and the system
  prompt states explicitly that everything inside the fence is data: instructions,
  questions and prompt-like strings found there are things the speaker said, not
  commands to follow.
- Delimiter injection is defused: `FormattingPromptBuilder.neutralize(_:)` rewrites
  any literal fence tags in the transcript, so a speaker (or a mis-recognition)
  cannot close the fence early.
- The result of formatting is **text only**. An action's `ActionOutcome` can copy to
  the clipboard and — only with the user's explicit setting — paste. It cannot run a
  command, call a tool, open a URL, choose a model or pick a destination. A future
  voice-command action (see `docs/ROADMAP.md`) must keep that property: the
  *user's* configuration decides what may happen, never the transcript.
- Practical consequence you should still be aware of: the formatted text can contain
  anything the speaker said, and auto-paste types it into whatever is frontmost.
  Auto-paste is off by default for that reason.

## Permissions

| Permission | When | Why |
|---|---|---|
| Microphone | always | to record you |
| Speech Recognition | Apple engines only | `SFSpeechRecognizer` / `SpeechAnalyzer` |
| Accessibility | only when 自動ペースト is enabled | synthesize ⌘V into the frontmost app |

Accessibility is the powerful one: it lets the app post key events to other
applications. It is requested only when you turn on auto-paste, and revoking it in
System Settings → プライバシーとセキュリティ → アクセシビリティ disables only that
feature.

## Code signing and the sandbox

The app is **not sandboxed**, on purpose: the App Sandbox forbids synthesizing input
events into other applications, which is exactly what auto-paste is. It is built
from source by the person running it rather than distributed through the App Store,
so the sandbox would remove capability without adding a meaningful boundary. See
`Resources/README.md`.

Local builds are **ad-hoc signed** by default. An ad-hoc signature has no stable
identity, so macOS treats each rebuild as a new app and re-prompts for permissions.
Using a self-signed certificate via `CODESIGN_IDENTITY` gives a stable identity —
that is a convenience measure, not a trust measure; a self-signed certificate
asserts nothing about provenance.

`Scripts/build_app.sh --hardened` additionally enables the Hardened Runtime and
applies `Resources/VoiceInput.entitlements`, which is what you would use with a real
Developer ID certificate if you ever wanted to notarize a build.

## Keeping secrets out of a public repository

This repository is public. `Scripts/check_secrets.sh` scans the working tree
(respecting `.gitignore`) for OpenAI/Anthropic keys, AWS access key ids, private-key
blocks, bearer tokens, GitHub tokens, and machine-specific absolute home paths. It
runs in `make check` and on every CI run, and reports `path:line` **without echoing
the matched text** so a finding in a public CI log does not leak the secret twice.

If you ever do commit a key: revoke it at the provider first, then clean history.
Rotation is the fix; deleting the commit is not.

## Reporting a problem

Report security issues **privately**, not in a public issue:

- Open a private advisory: repository → **Security** → **Report a vulnerability**
  (GitHub private vulnerability reporting).
- If that is unavailable, open a public issue that says only "security issue, please
  provide a private contact" — with no details, no reproduction and no logs.

Please include the affected version (`git describe` or the version in the app's
menu), macOS version, which engine/provider combination was active, and a
reproduction. Do not attach real API keys, audio, or transcripts. Expect an
acknowledgement within a few days; this is a volunteer project with no SLA.
