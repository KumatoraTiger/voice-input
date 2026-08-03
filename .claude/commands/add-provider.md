---
description: Add a new LLMProvider (chat-completion backend for text formatting)
---

Add an LLM provider. Reference: `docs/adding-a-provider.md`.

Providers are pure HTTP and live in `VoiceInputCore`, so they are fully unit
testable. Model the new one on `OpenAIProvider.swift` / `AnthropicProvider.swift`.

## Files to touch, in order

1. **`Sources/VoiceInputCore/Contracts/LLM.swift`**
   Add a case to `LLMProviderID`. The raw value is persisted in
   `AppSettings.llmProvider` / `AppSettings.models` and keys the Keychain entry via
   `SecretKey.apiKey(for:)` — **never rename an existing case.**

2. **`Sources/VoiceInputCore/LLM/<Name>Provider.swift`**
   Implement `LLMProvider`:
   - `init(session: URLSession = .shared)` so tests can stub the transport;
   - reuse the helpers in `ProviderHTTP.swift`;
   - fill in `displayName`, `suggestedModels`, `defaultModel`, `apiKeyURL`
     (Settings links it and keeps the model field free text).

3. **Map the request faithfully.** `LLMRequest.systemPrompt` goes into the
   provider's *system* slot; `messages` stay user/assistant messages. **Never
   concatenate the system prompt and the transcript** — that separation is the
   prompt-injection defence (`docs/SECURITY.md`).

4. **Errors**: non-2xx → `.providerHTTPError(provider:status:body:)` with a
   **truncated** body; bad JSON → `.providerDecodingFailed`; transport → 
   `.networkFailure`. The body must never contain the API key. Nothing here is
   logged.

5. **`Sources/VoiceInputCore/LLM/ProviderRegistry.swift`**
   Register it in `LLMProviderRegistry.live(session:)`.

6. **Tests** in `Tests/VoiceInputCoreTests/` with `StubURLProtocol`: request URL and
   headers, JSON body shape, system/user separation, success decoding with token
   counts, 401 / 429 / 500 mapping, malformed response.

7. **Docs**: update the "what leaves your machine" table in `docs/SECURITY.md`
   (new destination host) and the provider list in `README.md`. Link the provider's
   pricing page — do **not** quote a price you have not verified against that page
   today.

Finish with `make check`.
