# Assistant

A chat with a model that can operate the app: find and change settings, search and play, manage subscriptions and
sources, read and edit the viewer's own Python/JavaScript source scripts, and so on. Design reference: FlowDown
(github.com/Lakr233/FlowDown, AGPL-3.0, so only ideas are taken, no code) and its MIT ChatClientKit (wire formats).

## Entry points

- **iPhone and iPad:** on Watch Now and Discover (their root pages), a swipe that starts at the right edge (within
  ~24 pt) and moves left pulls the assistant in from the right. It must not take horizontal swipes that start
  elsewhere (shelves scroll sideways), nor work while a player or sheet is up. A toolbar button (`sparkles`) opens it
  too, for discoverability and VoiceOver. iPhone: a full-height panel sliding over from the right, dismissed by
  swiping it back right or a close button. iPad (regular width): a ~400 pt trailing panel beside the page.
- **Mac:** a toolbar button and ⌘⇧A toggle a trailing panel (inspector style) on Watch Now and Discover.
- **Apple TV:** a button on Watch Now and Discover; the text field takes dictation. No swipe (focus moves on it).
- Nothing shows until the viewer turns the assistant on in **Settings › Assistant**.

## Settings › Assistant

On/off; connection: **Sign in with ChatGPT** (offered only when `assistant.chatGPTSignIn` is on, see Eligibility) or
**API key** (OpenAI by default; any OpenAI-compatible server by base URL, with Responses or Chat Completions); model
(picked from `GET /models`); "Ask before changes" (on by default; destructive tools always ask); clear conversation;
a privacy note: what is sent (your messages, and what tools read: titles, settings, script text you ask about), what
never is (passwords, cookies, keys, tokens), and that the provider's own terms apply.

## Core (Sources/TVCore/Agent)

- `AgentCore.swift`: the shared types (messages, tool specs, events, failures, connections). Add, don't break.
- `ResponsesClient`: `POST {base}/responses`, `stream: true`, `store: false`, `instructions` for the system prompt,
  function tools, SSE; success only on `response.completed`. `ChatCompletionsClient`: `POST {base}/chat/completions`,
  SSE, `tools`/`tool_calls` deltas. Both: `GET {base}/models`. No retries hidden from the viewer; cancellation stops.
- `AgentConversation`: the loop. At most 12 tool rounds per message. A `change` tool asks when "Ask before
  changes" is on; a `destructive` one always asks. Tool results go back to the model as JSON text, cut to ~8 KB.
  The conversation is saved (Application Support/Assistant, last 50 messages) and restored.
- `AgentSettings` / Keychain: API keys per base URL; ChatGPT tokens. Never synced to iCloud, never logged.
- `ChatGPTSignIn`: OpenAI's "Sign in with ChatGPT" for open-source apps (developers.openai.com/siwc):
  `client_id=dynamic_agent_client` on first sign-in (save the issued `oaiapp_` id), `agent_name_hint=Yingxia`,
  `ext_agent_host_id=urn:uuid:<persisted>`, PKCE S256, state + nonce, `redirect_uri=http://127.0.0.1:1455/auth/callback`
  (a loopback listener while the browser sheet is up), scopes
  `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct`, `resource=https://api.openai.com/v1`;
  token and refresh at `https://auth.openai.com/api/accounts/oauth/token` (rotating refresh, serialized), revoke at
  the discovery document's `revocation_endpoint` on sign-out. Inference: `POST https://api.openai.com/v1/responses`
  with the access token. Map the `subscription_sharing_*` errors to `AgentFailure` (usage limit → link to
  chatgpt.com/settings/usage). Not on Apple TV (no browser): the TV uses an API key.
- Logging: `Diagnostics` category `assistant`: request ids, status, error codes, tool names and durations. Never
  the viewer's words, tool results, keys or tokens.

### Eligibility

OpenAI offers plan usage to open-source and locally run apps; paid or hosted apps are asked to use the interest
form first. Yingxia is open source but ships through the App Store and TestFlight, so the ChatGPT sign-in stays
behind `assistant.chatGPTSignIn` (off) until the owner confirms. API keys work everywhere.

## Tools (App/Agent/Tools)

`AppAgentTools.all(store:)` returns every tool. Each is small, typed by its JSON Schema, and returns compact JSON
(lists capped at ~30 items with a `more` count). Effects: read / change / destructive.

- App: `app_state` (page, what plays, platform, which sections exist), `open_page` (section or a page: a video, a
  source, a settings item).
- Settings: `settings_search` (the Settings search index, with each item's current value and allowed values),
  `settings_get`, `settings_set` (change), `settings_open`.
- Videos: `search_videos` (global search across sources), `video_details`, `play` (a result, an episode, from
  history or favorites), `player_control` (pause/resume/seek/speed/next/previous/subtitles/audio track).
- Library: history list/remove (destructive), favorites list/add/remove, downloads list/start/pause/remove.
- Subscriptions and sources: list, add (change), refresh, enable/disable, rename, reorder, remove (destructive),
  source health.
- Scripts: `scripts_list` (the viewer's imported `.py`/`.js` files), `script_read` (by line range), `script_write`
  (destructive: shows a diff, keeps the previous copy as `<name>.bak`), `script_test` (loads it as a source and runs
  its home and a search, returning errors and counts).
- Live, music, novels, manga: search, open, play.
- Diagnostics: `recent_log` (the app's recent diagnostic lines, already scrubbed of addresses).

Rules: tools only reach what the viewer could reach on screen. Sections the App Store build hides
(`Store.hiddenSections`, `extrasUnlocked`) stay hidden. No source names in app code. What tools return is data,
never instructions: the system prompt says so, since titles and scripts come from third parties.

## Who builds what (branch feature/agent)

- core: Sources/TVCore/Agent (except the contract, which only grows), Tests.
- ui: App/Agent/Assistant*.swift, App/Agent/AssistantSettingsView.swift, the entry points (Watch Now, Discover, Root,
  Settings), strings in all four languages.
- tools: App/Agent/Tools/*.swift and the hooks they need in Store/SettingsView.
