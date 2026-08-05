# Security and privacy

VoiceInput listens to a microphone, holds API keys, and can type into other
applications. This document states exactly what it does with each of those.

## API keys

- Keys are stored in the **macOS Keychain**, service
  `io.github.voiceinput.VoiceInput`, through `SecretStore`
  (`Sources/VoiceInputCore/Secrets/KeychainSecretStore.swift`).
- Each key is a separate item, so an OpenAI key used only for transcription and an
  Anthropic key used only for formatting stay independent:
  - `llm.apiKey.openAI`, `llm.apiKey.anthropic`, `llm.apiKey.gemini`
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
| Apple on-device | Google Gemini | no | **yes** | `generativelanguage.googleapis.com` |
| Apple SpeechAnalyzer | OpenAI / Anthropic / Gemini | no | **yes** | as above |
| OpenAI cloud STT | off | **yes** | **yes** (returned text) | `api.openai.com` |
| OpenAI cloud STT | OpenAI | **yes** | **yes** | `api.openai.com` |
| OpenAI cloud STT | Anthropic / Gemini | **yes** (to OpenAI) | **yes** (to the LLM) | both |

Read it as: **audio only ever leaves the machine if you select the OpenAI cloud
engine. Text only ever leaves the machine if LLM formatting is enabled.** Turn both
off (Apple engine + 整形オフ) and the app makes no network requests at all.

What is sent, precisely:

- **Cloud STT:** the recorded audio as a WAV, plus the model name, the locale, and
  any vocabulary terms you configured. No identifiers beyond your API key.
- **LLM formatting:** the system prompt (the built-in instruction plus your selected
  style's instructions) and the raw transcript as a user message. Nothing else — no
  clipboard contents, no window titles, no file paths, no telemetry.
- **LLM formatting with 画面コンテキスト on** (off by default, see below): additionally
  a list of at most twelve isolated words read off the frontmost window. Never
  sentences, never the screenshot, never the full OCR text.
- **Asking a question** (the 質問 shortcut, off until you bind a key): the ask system
  prompt, the answer-length setting, your vocabulary, the locale, and the transcribed
  question as a user message. Same endpoints and the same provider as formatting, on
  whichever model you set in 設定 → 質問. Screen terms are **not** included — that
  feature narrows spellings in a dictation, and a question is not a dictation. The
  answer comes back, is shown in the HUD and placed on the clipboard, and is not sent
  anywhere else.
- **Nothing at all** is sent to any endpoint the user did not select. The app has no
  analytics, no crash reporter, no update check, and no first-party server.

Once data reaches a provider, that provider's policy governs it. Read the relevant
one before enabling a cloud path:
<https://openai.com/policies/> · <https://www.anthropic.com/legal/privacy> ·
<https://ai.google.dev/gemini-api/terms>.

Note on Gemini specifically: Google's terms distinguish the **free tier** from paid
use, and the free tier is documented as allowing human review of the content you
send. If the transcript is confidential, check which tier your key is on before
enabling this provider.

The key is sent in the `x-goog-api-key` header, never as the `?key=` query parameter
Google also accepts — a secret in a URL survives in proxy logs, browser history and
crash reports long after the request.

## What is never persisted

- **Audio** is never written to disk. It is captured into memory, streamed to the
  engine, and discarded. The cloud engine builds its WAV in memory and drops it
  after the request.
- **Transcripts and formatted text** are never written to disk. The history in the
  menu (`DictationRecord`) lives in memory only, is capped by
  `AppSettings.historyLimit`, and dies with the process.
- **Screen captures**, when 画面コンテキスト is on, exist as a `CGImage` for the
  length of one OCR pass and are then released. No file, no cache, no pasteboard.
  The text OCR produced lives in memory for the one dictation that triggered it.
- **Logs never contain user content.** The app logs through `os.Logger` with
  subsystem `io.github.voiceinput`: state transitions, durations, engine ids, error
  kinds, and counts — how many recognition segments and partial results a dictation
  produced, and how many characters the transcript and the formatted output ran to.
  Counts and timestamps are metadata; the text they measure is never logged.
  Transcripts, prompt bodies, LLM responses and keys must never be logged — if
  content is ever logged for debugging it must be marked `privacy: .private` and
  left off by default. `VoiceInputError.kind` exists for exactly this reason: it
  names the failure case without its associated strings, which can quote speech.
  画面コンテキスト follows the same split: OCR line counts, pool sizes and the number
  of candidates that survived matching are logged as metadata, while the words
  themselves go out at `.debug` marked `privacy: .private` — redacted unless someone
  deliberately enables private data with `log config` on their own machine.
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
- **Self-correction is scoped to the text, not to the formatter.** The system prompt
  asks the model to honour a later correction of an earlier phrase (「3 時じゃなくて
  4 時」) and to resolve a spelled-out kanji, which means transcript content does
  steer the output. The boundary is restated at the end of the injection section:
  speech aimed at the formatter itself — anything invoking 出力 / あなた / 指示 /
  プロンプト / システム — is transcribed as body text rather than acted on. The
  worst case a real self-correction can produce is *less* text, never a different
  behaviour, because the output is still text only (next bullet).
- The result of formatting is **text only**. An action's `ActionOutcome` can copy to
  the clipboard and — only with the user's explicit setting — paste. It cannot run a
  command, call a tool, open a URL, choose a model or pick a destination. A future
  voice-command action (see `docs/ROADMAP.md`) must keep that property: the
  *user's* configuration decides what may happen, never the transcript.
- Practical consequence you should still be aware of: the formatted text can contain
  anything the speaker said, and auto-paste types it into whatever is frontmost.
  Auto-paste is off by default for that reason.

### The ask action is the one place speech is a request

`AskAction` breaks the sentence above deliberately: the point of the 質問 shortcut is
that 「Swift で配列の重複を取り除く方法」 gets *answered*, not punctuated. Nothing
about the rule changed for dictation — the two paths never mix, because only the
shortcut the user bound to `.ask` reaches this action, and `DictationCoordinator`
takes the action id from the `HotkeyPurpose` rather than from anything in the audio.

Where the licence stops, and why it is still safe to give:

- **Content, not configuration.** `AskPromptBuilder`'s system prompt says the model
  may answer what is inside the fence, and must not obey text there that tries to
  rewrite the output rules, its role, or the destination. That distinction is the
  whole security property of this action, so it is asserted in the tests.
- **Still fenced, still a user message.** The question travels in `<question>` …
  `</question>` inside a *user* message and is never interpolated into the system
  prompt, exactly like a transcript. `AskPromptBuilder.neutralize(_:)` shares one
  fence list with the formatter (`PromptFence`), so neither prompt's tags can be
  closed early from either path.
- **Text only, and the prompt says so.** An answer is a string that lands on the
  clipboard. There is no tool, path, URL, shell or network destination an
  `ActionOutcome` can name, and the prompt states that rather than leaving the model
  to infer it. The worst case of a hostile question is a useless answer.
- **No memory.** One recording is one question; nothing from a previous question or
  answer is carried into the next call. There is no conversation state to poison, and
  nothing about a question outlives the process.
- **An answer is never auto-pasted.** `AskAction` returns
  `pasteIntoFrontmostApp: false` regardless of `autoPasteEnabled`: that setting means
  "put my dictation in the field I am typing in", and an answer is shown on screen
  instead (`ResultPresentation.persistent`). So the formatting path's practical caveat
  — that text can be typed into whatever is frontmost — does not apply here. The
  answer is still placed on the clipboard, which is the only way it leaves the HUD.
- **The screen is not read for a question.** `AskAction.usesScreenContext` is false,
  and the coordinator checks that before capturing — so asking a question never takes
  a screenshot, even with 画面コンテキスト enabled and the permission granted. The
  feature narrows spellings in a dictation; a question has nothing to do with what is
  on screen, and capturing it anyway would be a screen read with no purpose.

## 画面コンテキスト: reading the screen without handing it to the model

**Off by default.** Turning it on in Settings → 整形 is the consent moment, and the
only thing that ever asks for the screen-recording permission.

The feature exists because a recogniser cannot spell a name it has never seen, and
the right spelling is often on screen. The risk it creates is that screen text is
written by people who are not the user — colleagues, web pages, documents — so
treating it the way the transcript is treated is not enough. Five layers, from
strongest to weakest:

**1. Only what was spoken gets through** (`ScreenTermMatcher`). Formatting runs
*after* transcription, so the prompt does not have to carry the screen. It carries
only the terms that are phonetically close to a word in the transcript. Someone who
controls what is on screen therefore cannot place arbitrary text in the prompt:
whatever they display is dropped unless the user happens to say something that
sounds like it. This bounds the attack surface to the user's own speech.

**2. Tokens, never sentences** (`ScreenTermExtractor`). Every candidate is a single
word: no whitespace, at most 30 characters, no URL or path shape. An instruction
needs a sentence to exist, and this filter makes sentences unrepresentable. The
same filter drops the shapes secrets take — long letter-and-digit runs, all-digit
strings — so an API key or a card number visible on screen is never a candidate.

This stage deliberately does **not** limit how many words survive in any meaningful
sense (the cap is 400, and it is there to bound memory and comparison cost). It runs
when recording starts, before a transcript exists, so it has nothing to rank
relevance against and falls back to frequency — which on a real window favours
chrome over the one proper noun being dictated. Narrowing is layer 1's job, and what
reaches the prompt is capped there, at 12. A wider pool does mean more words are
*eligible* for layer 1, so an attacker gets more attempts at the phonetic gate; each
attempt still has to survive it, and still needs the user to utter something close,
so the bound in layer 1 is unchanged in kind.

**3. One window, and not every window.** Only the frontmost window is captured, so
a chat in the background or a second display is never read. Password managers and
Keychain Access are on a denylist that overrides the setting
(`ScreenCaptureContextProvider.defaultExcludedBundleIDs`).

**4. A separate fence, declared as data** (`FormattingPromptBuilder`). Terms go in
`<screen_terms>` … `</screen_terms>` in the *user* message, and the system prompt
states that the range is a spelling dictionary, that nothing in it may be added to
the output, and that instructions found there are not to be followed.
`neutralize(_:)` defuses attempts to close either fence early. Like all
prompt-level defences this is probabilistic, which is why the next one exists.

**5. The output is checked** (`ScreenContextGuard`). Formatting's contract is to add
no information, widened by exactly one allowance: the model may re-spell a word
using a term we sanctioned. So a result is rejected when it contains a long span
that appears in the OCR text, does not appear in the transcript, and is not one of
the sanctioned terms. That signature covers both failure modes — an injected
instruction the model obeyed, and screen content it simply copied. On detection the
dictation is formatted again with the screen left out entirely, and the result is
marked 画面コンテキスト破棄 in the history. The verdict carries a character count and
never the offending text, so nothing screen-derived can reach a log.

Layers 1, 2, 3 and 5 are structural; only layer 4 depends on the model behaving.

### What this does not fix

- Someone who controls the screen *and* can predict a word the user will say could
  still get one token through. It lands as a wrong word in the pasted text — not as
  a command, a request or a destination, because an `ActionOutcome` cannot express
  any of those.
- Privacy is a separate question from injection. Even filtered tokens are screen
  content, and with a cloud provider configured they are sent to it. That is why
  the feature is opt-in and why Settings says so next to the switch.
- Vision's OCR runs on-device, but it is the *only* on-device part when formatting
  is cloud-backed. Turning formatting off (整形オフ) makes screen context moot: no
  LLM call, no terms, nothing read. Asking a question is the same: the action does
  not declare `usesScreenContext`, so no capture happens.

## Permissions

| Permission | When | Why |
|---|---|---|
| Microphone | always | to record you |
| Speech Recognition | Apple engines only | `SFSpeechRecognizer` / `SpeechAnalyzer` |
| Accessibility | 自動ペースト, or a modifier-only hotkey | synthesize ⌘V into the frontmost app; observe modifier keys globally |
| Screen Recording | 画面コンテキスト only (off by default) | read the frontmost window so the LLM can fix misrecognised names |

Accessibility and Screen Recording are the powerful ones, and they are the only
permissions that touch other applications. Neither is requested at first launch —
Accessibility is asked for when you turn on auto-paste or bind the hotkey to
modifiers alone (⇧⌃), and Screen Recording only when you switch 画面コンテキスト on.
Revoking either in System Settings disables exactly the feature that asked for it
and nothing else.

### What the hotkey monitor observes

The default hotkey shape (a key plus modifiers, ⌥Space) goes through Carbon's
`RegisterEventHotKey`, which observes **nothing** — the OS delivers a callback only
for that one combination. No permission, no event stream.

A formatting style can be given a shortcut of its own, and each one is another
Carbon registration of exactly this kind: one more combination the OS will call back
about, still no event stream and still no permission. Style shortcuts are
key-plus-modifier only — the modifier-only path below stays reserved for the single
main shortcut, so adding styles can never add a keyboard monitor.

A modifier-only hotkey (⇧⌃) cannot be expressed in Carbon, so it is detected from
`NSEvent` monitors. What that means concretely:

- A **`flagsChanged`** monitor runs for as long as such a hotkey is configured. These
  events carry only the set of modifier keys currently held — no characters.
- A **`keyDown`** monitor is installed *only while the hotkey's modifiers are held*,
  and removed the moment they are released. It exists so that ⌃⇧→ (select word) is
  not mistaken for the shortcut. Only `NSEvent.type` is read; the character, the
  key code and the target application are never touched, never logged, and never
  stored. In `push-to-talk` mode it is never installed at all.

If you would rather the app never install a keyboard monitor, use a key-plus-modifier
hotkey — that is why it remains the default.

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
