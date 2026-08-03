---
description: Build all targets and run the VoiceInputCore unit tests
---

Run the test suite.

1. Run `make test` (= `Scripts/test.sh`: `swift build` for every target, then
   `swift test`). Never `xcodebuild`.
2. `swift test` alone is not sufficient — it only builds what the test target
   depends on, so it misses breakage in `VoiceInputPlatform` and `VoiceInputApp`.
   That is why the script builds everything first.
3. Report failures with the test name and the actual assertion, not a summary.
4. When a test fails, fix the **code**, not the test — unless the test genuinely
   encodes the wrong expectation, in which case say so explicitly and explain why.
5. Never make a test pass by loosening an assertion, adding a sleep, or skipping it.
6. Tests live in `Tests/VoiceInputCoreTests/` and use swift-testing (`@Test`,
   `#expect`). Network behaviour is tested through `StubURLProtocol` — never hit a
   live endpoint, never require an API key to run the suite.

If the user asked for a specific test, pass it through:
`Scripts/test.sh --filter <name>`.
