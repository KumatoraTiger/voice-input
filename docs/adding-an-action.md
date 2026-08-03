# Adding a voice action

Referenced from `Sources/VoiceInputCore/Contracts/Actions.swift`.
Slash command: `/add-action`.

A `VoiceAction` is "what happens to a finished transcript". Two ship today:
`FormatAction` (LLM rewrite) and `RawAction` (pass-through, no key needed). The
abstraction exists so voice *commands* can be added without touching capture or
transcription.

## Steps

1. **Add the id.** A new `static let` on `VoiceActionID`
   (`Sources/VoiceInputCore/Contracts/Actions.swift`). Raw values may be persisted —
   do not rename existing ones.

2. **Implement `VoiceAction`** in `Sources/VoiceInputCore/Formatting/` (or a sibling
   folder in Core). It must be `Sendable` and take everything it needs from
   `ActionContext` — `settings`, `llm`, `apiKey`, `frontmostAppName`. No globals, no
   singletons; that is what keeps it testable.

3. **Set `requiresLLM` honestly.** `DictationCoordinator` uses it to fail fast with
   `.missingAPIKey` before recording work is wasted.

4. **Return a deliberate `ActionOutcome`.** Decide `copyToClipboard` and
   `pasteIntoFrontmostApp` explicitly (auto-paste needs Accessibility and is off by
   default), and set `summary` to something the HUD can show, e.g.
   `"gpt-4.1-mini · 320ms"`. `summary` must never contain user text.

5. **Register it** in `ActionRegistry.live`
   (`Sources/VoiceInputCore/Formatting/ActionRegistry.swift`). If the action gets
   its own hotkey, add a `HotkeyBinding` to `AppSettings` and bind it in
   `VoiceInputApp` — `DictationCoordinator.toggle(action:)` already takes the id.

6. **Security.** The transcript is untrusted input. An action may not let it choose
   a command, a URL, a file path, a model or a destination; the user's configuration
   decides what is permitted and the model may only select among those options. If
   the action builds a prompt, fence the transcript the way
   `FormattingPromptBuilder` does. Re-read `docs/SECURITY.md` before adding anything
   with a side effect.

7. **Tests** in `Tests/VoiceInputCoreTests/` with a fake `LLMProvider` (see
   `Sources/VoiceInputCore/Pipeline/Fakes.swift`): outcome fields, `requiresLLM`
   behaviour with and without a key, empty transcript, and — if it prompts — that a
   transcript containing instruction-like text is still treated as data.

8. **Docs.** If the action is user-selectable, document it in `README.md` and update
   `docs/ARCHITECTURE.md` if it adds a path through the state machine.
