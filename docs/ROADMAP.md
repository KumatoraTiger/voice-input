# Roadmap

Short and deliberately unambitious. Everything below is a natural extension of an
existing seam, not a rewrite.

## 1. Voice commands as a second `VoiceAction`

The contracts already separate "capture and transcribe" from "what to do with the
result" (`VoiceAction`, `ActionRegistry`, `VoiceActionID`). A `CommandAction` bound
to its own hotkey could interpret the dictation as an instruction ("この文を英語に",
"箇条書きにして") rather than as text to clean up.

- Ships as a new action + a second `HotkeyBinding`; capture and transcription do not
  change.
- **Constraint:** the transcript stays data. The set of permitted operations comes
  from the app's configuration, and the model may only select among them — it may
  never name an arbitrary command, path or URL. See `docs/SECURITY.md`.

## 2. Per-app formatting styles

`ActionContext.frontmostAppName` is already captured at record time and threaded
through unused. Map app → `FormattingStyle` so dictating into Slack gets the chat
style and dictating into a document gets the standard one, with a manual override.

## 3. Streaming formatting

Today the LLM is called once after the final transcript. Both Apple engines already
emit partials, so the rewrite could start on stable prefixes and stream into the HUD,
cutting perceived latency to near zero. Needs `LLMProvider` to grow a streaming
variant (SSE) and the coordinator to handle revisions of already-formatted text.

## 4. Local LLM provider

An `LLMProvider` pointing at a local OpenAI-compatible server (Ollama, LM Studio,
llama.cpp) makes the entire pipeline offline and free when paired with an Apple
speech engine — nothing leaves the machine at any stage. The provider protocol needs
nothing new beyond a configurable base URL and optional-key handling.

## Not planned

- Mac App Store distribution (the sandbox forbids auto-paste).
- Telemetry or analytics of any kind.
- Storing audio or transcripts on disk.
