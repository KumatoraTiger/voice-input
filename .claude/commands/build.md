---
description: Build VoiceInput.app (never xcodebuild) and report what happened
---

Build the app bundle.

1. Run `make app` (add `--debug` via `Scripts/build_app.sh --debug` if the user asked
   for a debug build).
2. **Never run `xcodebuild`.** Xcode is not installed on the reference machine.
   Everything goes through SwiftPM plus `Scripts/build_app.sh`.
3. Read the script's header output and report:
   - whether `SPEECH_ANALYZER` was compiled in, and why (SDK version);
   - the version/build strings written into `Info.plist`;
   - whether the signature was ad-hoc or from `CODESIGN_IDENTITY`.
4. If the build fails, distinguish clearly between:
   - a **Swift compile error** in `Sources/` — report the file:line and the actual
     diagnostic, do not paper over it;
   - a **bundling/script problem** — that is a bug in `Scripts/build_app.sh`.
5. Do not "fix" a compile error by deleting code or weakening a type. Fix the cause
   or report it.

The result lands at `build/VoiceInput.app`. Remind the user it is a menu-bar-only
app (no Dock icon) and that ad-hoc builds re-prompt for permissions.
