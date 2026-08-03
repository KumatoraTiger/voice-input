# Resources/

Files consumed by `Scripts/build_app.sh` when it assembles `build/VoiceInput.app`.
Anything here that is *not* `Info.plist` or `*.entitlements` is copied verbatim into
`VoiceInput.app/Contents/Resources/` (put an `AppIcon.icns` here, for example).

## `Info.plist`

Template. The build script renders it with the version derived from `git describe`
and fails if a placeholder survives substitution. Key choices:

- `LSUIElement = true` — menu-bar-only agent: no Dock icon, no app-switcher entry.
- `LSMinimumSystemVersion = 14.0` — must stay in sync with `platforms:` in `Package.swift`.
- `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` — shown
  verbatim by macOS in the TCC prompt, so keep them accurate and in Japanese.
- Accessibility (needed only for auto-paste) has **no** Info.plist key on macOS;
  it is granted in System Settings → Privacy & Security → Accessibility.

## `VoiceInput.entitlements`

**VoiceInput is deliberately not sandboxed**, and this file is **not applied by
default**.

Why no sandbox: the app must synthesise key events into whatever application is
frontmost (auto-paste — an Accessibility operation the App Sandbox forbids
outright) and reach user-chosen HTTPS endpoints. It is built from source by the
person running it rather than shipped through the Mac App Store, so the sandbox
would cost capability and buy nothing.

Why not applied by default: without the Hardened Runtime and without the sandbox,
an entitlements blob has no effect. `build_app.sh` therefore signs plainly unless
you pass `--hardened`, which adds `--options runtime` and applies exactly the two
entitlements in the file — the configuration you would use with a real Developer ID
certificate if you ever wanted to notarize a build.

The file contains no XML comments on purpose: the entitlements parser used during
code signing (`AMFIUnserializeXML`) rejects them.

See `docs/SECURITY.md` for the full threat model.
