# Adding an LLM provider

Referenced from `Sources/VoiceInputCore/Contracts/LLM.swift`.
Slash command: `/add-provider`.

Providers are pure HTTP, so they live in `VoiceInputCore` and are fully testable.

## Steps

1. **Add the id.** New case in `LLMProviderID`
   (`Sources/VoiceInputCore/Contracts/LLM.swift`). The raw value is persisted in
   `AppSettings.llmProvider` / `AppSettings.models` and keys the Keychain entry via
   `SecretKey.apiKey(for:)` — **never rename an existing one**.

2. **Implement `LLMProvider`** in `Sources/VoiceInputCore/LLM/`, modelled on
   `OpenAIProvider` / `AnthropicProvider`:
   - take `session: URLSession` in the initializer (defaulted) so tests can stub the
     transport;
   - reuse the helpers in `ProviderHTTP.swift`;
   - fill in `suggestedModels`, `defaultModel` and `apiKeyURL` — Settings shows the
     suggestions but keeps the model field free text, so a user can type a newer
     model without waiting for a release.

3. **Map the request faithfully.** `LLMRequest` carries `systemPrompt` separately
   from `messages` on purpose: the system prompt must go into the provider's system
   slot, and the transcript must stay in a **user** message. Never concatenate them.

4. **Errors.** Non-2xx → `VoiceInputError.providerHTTPError(provider:status:body:)`
   with a **truncated** body; decoding failure → `.providerDecodingFailed`;
   transport failure → `.networkFailure`. The body must never contain the API key,
   and nothing here may be logged.

5. **Register it** in `LLMProviderRegistry.live(session:)`.

6. **Tests** in `Tests/VoiceInputCoreTests/` using `StubURLProtocol`: request shape
   (URL, headers, JSON body, system/user separation), success decoding, token
   counts, 401/429/500 mapping, malformed JSON.

7. **Docs.** Update the "what leaves your machine" table in `docs/SECURITY.md`, the
   provider list in `README.md`, and link the provider's pricing page rather than
   quoting a number you have not verified.
