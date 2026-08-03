---
description: Build, launch VoiceInput.app and tail its unified log
---

Build and run the app.

1. Run `make run` (= `Scripts/run.sh`): it builds the bundle, quits any running
   instance, launches `build/VoiceInput.app` with `open`, and then tails
   `log stream --predicate 'subsystem == "io.github.voiceinput"'`.
   Use `Scripts/run.sh --no-logs` if the log tail would block you.
2. The app **must** run from the `.app` bundle. Do not `swift run VoiceInputApp` —
   without a bundle and `Info.plist`, macOS denies microphone, speech-recognition
   and accessibility access, and the menu-bar item will not behave correctly.
3. It is a menu-bar-only agent (`LSUIElement`): nothing appears in the Dock. Verify
   it started with `pgrep -x VoiceInput` rather than looking for a window.
4. You cannot click the menu bar or speak into the microphone. Do not claim the
   app "works" from a successful launch — say what you actually verified (process
   is alive, no errors in the log) and ask the user to try the hotkey.
5. The log contains no transcripts or prompt bodies by design. If you need more
   detail, add a log line that records a state or a duration — never user content.

Default hotkey: ⌥Space (toggle). Esc cancels a recording.
