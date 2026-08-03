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
  minute of continuous speech. The LLM rewrite step hides a lot of this, but it
  cannot recover a word that was never recognised.
- **Mitigation:** put names and jargon in Settings → 語彙 (`contextualStrings`).

#### The running transcript is not the whole dictation

This engine has a trap worth knowing about, and it is the reason
`AppleOnDeviceSession` is more than a thin wrapper. `SFSpeechRecognizer` does not
hand back one transcript for one dictation. It discards what it has and starts over
in **three** different ways, and only the first is announced:

1. **The task ends.** The endpointer decides an utterance is over — a pause between
   two sentences is enough — and the task reports `isFinal` (or, on this hardware,
   `kAFAssistantErrorDomain 1101`) and goes quiet, while the microphone keeps
   streaming into a request nobody is listening to. On-device recognition also
   hard-stops at roughly a minute of audio.
2. **The task restarts itself, silently.** Part-way through, `formattedString`
   reverts to the newest utterance alone and the segment timestamps rewind — no
   `isFinal`, no error, no callback of any kind. Measured on macOS 15.5: a 65-second
   dictation did this **ten times**. Before it was handled, that dictation reduced
   to the last sentence.
3. **The terminal result comes back empty.** `endAudio()` can tear the task down
   mid-utterance, and the `isFinal` result then carries an empty string even though
   dozens of partials carried text.

So the session tracks the running transcript itself:

- `UtteranceBoundary.restarted(...)` (Core, unit-tested) spots case 2 from a partial
  that is *shorter* than the last one **and** either rewinds the segment timestamp
  or no longer shares the first half of it. Both signals are required — a missed
  restart silently drops the first half of a dictation, a false one duplicates it.
- Case 1 banks the segment and swaps a fresh request and task in under the session
  lock, so audio keeps flowing. `finish()` is the only thing that ends the dictation.
- Case 3 falls back to the segment's last partial.

The transcript `finish()` returns is `TranscriptSegmentJoiner.join(...)` over
everything banked. The joiner (Core, unit-tested) inserts a space between segments
only when neither side of the seam is Japanese/Chinese, so 日本語 does not come back
with spaces sprinkled through it.

Rollover is bounded: a task that ends empty within half a second of the previous one
counts towards a spin guard, and there is an absolute cap on reopened tasks. Both
exist so a recognizer that has stopped working fails instead of looping.

None of this is documented by Apple, and all of it was found by instrumenting a real
dictation — which is why the `io.github.voiceinput:asr` log category exists and logs
segment counts, partial counts and character counts (never text). If this engine
starts losing speech again, that log is the first thing to read.

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
<https://openai.com/api/pricing/>, <https://www.anthropic.com/pricing> and
<https://ai.google.dev/pricing>. A typical
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
