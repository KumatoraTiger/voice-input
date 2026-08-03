# Roadmap

Short and deliberately unambitious. Everything below is a natural extension of an
existing seam, not a rewrite.

## 1. Voice commands as a second `VoiceAction`

Half done: `AskAction` ships, bound to its own optional hotkey (設定 → 質問). It
answers the dictation as a question and puts the answer on the clipboard — one call,
no conversation state. It confirmed the seam works: a new action + a second
`HotkeyBinding`, with capture and transcription untouched.

What remains is a `CommandAction` that *acts* rather than answers ("この文を英語に",
"箇条書きにして" applied to something the user already has).

- **Constraint, unchanged and the reason this half is still unbuilt:** the set of
  permitted operations comes from the app's configuration, and the model may only
  select among them — it may never name an arbitrary command, path or URL.
  `AskAction` sidesteps this entirely by producing nothing but text; a command action
  cannot. See the ask-action section of `docs/SECURITY.md` for where the current
  boundary sits.

Follow-ups the ask action deliberately left out:

- **Multi-turn questions.** One recording is one question today. Follow-ups need
  somewhere to *read* the previous answer, which means a window, which is a bigger
  change to the App layer than the action itself was.
- **A per-purpose provider.** The ask model is its own setting, but the provider is
  shared with formatting. Splitting it means a second provider picker and a second
  key path through `APIKeysModel`.

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
