---
description: Add a new VoiceAction (what happens to a finished transcript)
---

Add a voice action. Reference: `docs/adding-an-action.md`.

A `VoiceAction` decides what happens to a finished transcript. `FormatAction` (LLM
rewrite) and `RawAction` (pass-through) ship today. This is the seam for voice
*commands* — capture and transcription do not change.

## Files to touch, in order

1. **`Sources/VoiceInputCore/Contracts/Actions.swift`**
   Add a `static let` to `VoiceActionID`. Raw values may be persisted — do not
   rename existing ones.

2. **`Sources/VoiceInputCore/Formatting/<Name>Action.swift`** (or a sibling folder
   in Core). Implement `VoiceAction`. It must be `Sendable` and take everything from
   `ActionContext` (`settings`, `llm`, `apiKey`, `frontmostAppName`) — no globals,
   no singletons.

3. **`requiresLLM`** must be honest: `DictationCoordinator` uses it to fail fast
   with `.missingAPIKey` instead of wasting a recording.

4. **Return a deliberate `ActionOutcome`**: choose `copyToClipboard` and
   `pasteIntoFrontmostApp` explicitly (auto-paste needs Accessibility and is off by
   default), and set `summary` to something the HUD can show, e.g.
   `"gpt-4.1-mini · 320ms"`. **`summary` must never contain user text.**

5. **`Sources/VoiceInputCore/Formatting/ActionRegistry.swift`**
   Register it in `ActionRegistry.live`. If it needs its own hotkey, add a
   `HotkeyBinding` to `AppSettings` and bind it in `VoiceInputApp` —
   `DictationCoordinator.toggle(action:)` already accepts an id.

6. **Security — read this before writing any side effect.** The transcript is
   untrusted: anything the microphone heard ends up in the prompt. The action may
   **not** let the transcript choose a command, a URL, a file path, a model or a
   destination. The user's configuration defines the permitted set; the model may
   only select among it. If the action builds a prompt, fence the transcript exactly
   as `FormattingPromptBuilder` does (delimited, in a user message, with
   `neutralize(_:)` applied). See `docs/SECURITY.md`.

7. **Tests** in `Tests/VoiceInputCoreTests/` using the fakes in
   `Sources/VoiceInputCore/Pipeline/Fakes.swift`: outcome fields, behaviour with and
   without an API key, empty transcript, and — if it prompts — that a transcript
   full of instruction-like text is still treated as data.

8. **Docs**: document it in `README.md` if it is user-selectable, and update
   `docs/ARCHITECTURE.md` if it adds a path through the state machine.
   If it is a step toward voice commands, update `docs/ROADMAP.md`.

Finish with `make check`.
