# Speech engines

VoiceInput can transcribe with three different backends. They are genuinely
different trade-offs, not three flavours of the same thing — pick per situation.

**Default: Apple on-device (`appleOnDevice`).** It is free, works offline, needs no
account, and nothing leaves the machine. Switch in Settings → 音声認識.

## The three engines

### 1. Apple on-device — `SFSpeechRecognizer`

`TranscriptionEngineID.appleOnDevice` · `VoiceInputPlatform/Engines/AppleOnDeviceEngine.swift`

The recognizer that powers system dictation, forced into on-device mode
(`requiresOnDeviceRecognition = true`).

- **Cost:** free.
- **Privacy:** audio never leaves the Mac.
- **Requires:** macOS 14+, microphone + speech-recognition permission, and the
  language model for the chosen locale downloaded (macOS fetches it the first time;
  the engine reports `unsupportedLocale` until it is there).
- **Streaming:** yes — live partial results while you speak.
- **Weaknesses, honestly:** it is tuned for short utterances. On long-form Japanese
  it drifts: punctuation is sparse, homophones (漢字変換) go wrong, proper nouns and
  technical jargon get mangled, and quality degrades noticeably past roughly a
  minute of continuous speech. Apple also historically caps a single on-device
  recognition session at about one minute of audio. The LLM rewrite step hides a
  lot of this, but it cannot recover a word that was never recognised.
- **Mitigation:** put names and jargon in Settings → 語彙 (`contextualStrings`).

### 2. Apple SpeechAnalyzer — macOS 26+

`TranscriptionEngineID.appleSpeechAnalyzer` · `VoiceInputPlatform/Engines/SpeechAnalyzerEngine.swift`

Apple's rewritten speech stack (`SpeechAnalyzer` + `SpeechTranscriber`), introduced
with macOS 26. Still fully on-device and still free, but a substantially better
model: markedly better accuracy on long-form and conversational speech, better
punctuation, and faster-than-realtime processing. If you are on macOS 26, this is
the one to use.

- **Cost:** free.
- **Privacy:** audio never leaves the Mac.
- **Requires:** macOS 26+ **at runtime**, *and* the app must have been **built
  against the macOS 26 SDK** — see below.
- **Streaming:** yes, with volatile (fast, revisable) plus finalized results.

#### Why the `SPEECH_ANALYZER` flag exists

The `SpeechAnalyzer` API only ships in the macOS 26 SDK. Code that references it
cannot be compiled at all by an older toolchain — this is a compile-time problem,
not something `if #available` can solve. So:

- `Package.swift` turns the env var `VOICEINPUT_SPEECH_ANALYZER=1` into the Swift
  compilation condition `SPEECH_ANALYZER`.
- `Scripts/build_app.sh` and `Scripts/test.sh` set it automatically when
  `xcrun --show-sdk-version` reports major version ≥ 26, and print which way they
  went.
- The implementation sits behind `#if SPEECH_ANALYZER`. The `#else` branch compiles
  an `UnavailableEngine` that reports, in Settings, that the binary was built
  against an older SDK.

So on a macOS 15 machine the engine appears in Settings but is greyed out with a
reason, and the rest of the app is unaffected. Build on a macOS 26 machine (or with
an Xcode 26 toolchain selected) to get it. To force it on manually:

```bash
VOICEINPUT_SPEECH_ANALYZER=1 make app
```

### 3. OpenAI cloud STT

`TranscriptionEngineID.openAICloud` · `VoiceInputCore/ASR/OpenAITranscriptionEngine.swift`

Uploads the recorded audio as a WAV to OpenAI's transcription endpoint. Default
model `gpt-4o-transcribe`; `gpt-4o-mini-transcribe` and `whisper-1` also work
(the model field in Settings is free text).

- **Cost:** paid, per minute of audio. See the table below.
- **Privacy:** **your audio leaves the machine.** This is the only engine that does.
- **Requires:** an OpenAI API key (stored in the Keychain) and a network connection.
- **Streaming:** no — the upload happens after you stop speaking, so there are no
  live partials and there is an upload round-trip before you see text.
- **Strengths:** the most robust option for messy input — accents, background noise,
  code-switching between Japanese and English, mumbling, long recordings. When the
  Apple engines produce nonsense, this is what fixes it.

## Decision table

| | Apple on-device | Apple SpeechAnalyzer | OpenAI cloud |
|---|---|---|---|
| Cost | free | free | per minute (see pricing) |
| Audio leaves the Mac | no | no | **yes** |
| Works offline | yes | yes | no |
| Needs an API key | no | no | yes |
| OS requirement | macOS 14+ | macOS 26+ **and** built with the macOS 26 SDK | macOS 14+ |
| Live partial text | yes | yes | no |
| Short Japanese utterances | good | very good | very good |
| Long-form / noisy Japanese | weak | good | best |
| Latency after you stop | instant | instant | upload + inference |
| Default | **yes** | | |

Rule of thumb: stay on **Apple on-device** for everyday short dictation; move to
**SpeechAnalyzer** the moment you are on macOS 26; reach for **OpenAI cloud** only
for long or difficult recordings where accuracy is worth both the money and sending
audio off-device.

## Pricing

Verified on the OpenAI pricing page on **2026-08-03**
(<https://developers.openai.com/api/docs/pricing>):

| Model | Listed price |
|---|---|
| `gpt-4o-transcribe` | $0.006 / minute |
| `gpt-4o-mini-transcribe` | $0.003 / minute |
| Whisper | $0.006 / minute |

`gpt-4o-transcribe` and `gpt-4o-mini-transcribe` are additionally listed with
token-based pricing ($2.50 / $10.00 and $1.25 / $5.00 per 1M input/output tokens
respectively). Prices change — **check
<https://developers.openai.com/api/docs/pricing> before relying on these numbers.**

The formatting LLM is billed separately by tokens: see
<https://openai.com/api/pricing/> and <https://www.anthropic.com/pricing>. A typical
dictation is a few hundred tokens in and out, so the transcription side usually
dominates only if you use cloud STT.

The Apple engines cost nothing, ever.

## Switching engines

Settings → 音声認識 → エンジン. The list shows every engine with its current
availability, so an unusable one tells you *why*: `needsAPIKey`, `needsPermission`,
`unsupportedOS`, `unsupportedLocale`. The selection is stored in
`AppSettings.transcriptionEngine` and applies to the next dictation.

Recognition language is Settings → 言語 (`AppSettings.localeIdentifier`, default
`ja-JP`). Every engine honours it.

## Adding a fourth engine

See `docs/adding-an-engine.md`, or run `/add-engine`.
