# Architecture

How the app is put together and why, for anyone about to change it. The [README](../README.md) lists
what every file does; this is about the decisions behind them.

## The shape of it

```
                        ┌────────────────────────────┐
                        │  ChatScreen · Composer ·   │  SwiftUI, reads state, sends intent
                        │  Settings · Metrics · …    │
                        └─────────────┬──────────────┘
                                      │
                        ┌─────────────▼──────────────┐
                        │        ChatModel           │  @MainActor @Observable
                        │  open chat · routing ·     │  the one place decisions are made
                        │  history · measurements    │
                        └───┬──────────────┬─────────┘
                            │              │
                        ┌─────────────▼──────────────┐
                        │      OnDeviceEngine        │  actor, LiteRT-LM
                        │  load · stream · cancel    │
                        └─────────────┬──────────────┘
                                      │  asks for its prompt and its tools
                        ┌─────────────▼──────────────┐
                        │ PromptBuilder · ToolRegistry │
                        └─────────────┬──────────────┘
                               │  a running tool reports back through
                 ┌─────────────▼──────────────┐
                 │        ToolSession         │
                 └────────────────────────────┘
```

The engine emits `ReplyEvent` values — text, searching, sources, searchError, memorySaved
— and `ChatModel` applies each one to the screen in a single place. When you add something a reply
can do, add a case there and handle it once.

## Why things are where they are

**`ChatModel` is deliberately the only decision-maker.** Views read its state and call its methods;
they never talk to the engine or the archive. That's what keeps the decisions in one readable place
instead of spread across screens.

**Slow work lives on actors.** `OnDeviceEngine` is an actor because loading a 3–4 GB model and
generating from it must never touch the main thread. `ChatArchive` is an actor for the same reason
applied to file I/O. Everything observable is `@MainActor`, so SwiftUI never reads state mid-change.

**The engine holds one conversation at a time.** LiteRT-LM supports a single active session, so
`ChatModel` tracks `activeConversation: ConversationOptions?` — the options the live conversation was
built with. When they no longer match (you switched chats, edited a message, toggled search, changed
sampling), it's set to nil and the next send rebuilds the conversation from the chat's history. Any
change that invalidates the engine's idea of the conversation must clear it.

**History is rebuilt, not resumed.** Reopening a chat replays its recent turns as initial messages,
fitted to about half the context at roughly four characters per token. Photos aren't re-sent; they
become "(shared a photo)" in text. Chat templates need the history to start with a user turn, hence
the trim at the end of `historyTurns`.

**Tools reach the reply through a side channel.** LiteRT-LM builds a tool from the model's arguments
itself, so there's no way to hand a tool the Brave key or the stream it should report into.
`ToolSession.shared` bridges that gap for the one reply in flight. It's the single piece of shared
mutable state in the app, which is why it's lock-guarded and why `begin`/`end` bracket every stream.

**Falling back is a first-class path, not error handling.** Model loading walks an ordered list of
configurations (GPU with vision on CPU → GPU text-only → CPU with vision → CPU text-only) and each
entry carries the sentence the user sees if that's the one that worked. Running out of memory is the
exception, and deliberately so: it isn't a Swift error at all, so `LoadAttempt` catches it the only
way it can be caught — by noticing the note it left behind is still there on the next launch.

## Two apps from one codebase

`Sources/` compiles into both targets. `Apps/AnvilAI` and `Apps/AnvilAIDev` contain one file each — an
`@main` App that shows `AnvilRootScene` — and everything else about their identity comes from
`Config/Public.xcconfig` and `Config/Dev.xcconfig`: display name, bundle identifier, entitlements,
and, for the development app, `ANVIL_DEV`.

`AppFlavor` reads that identity back out of the bundle at runtime rather than hard-coding it, so
`AppFlavor.appName` is correct in both apps and there's exactly one place that decides it.
`AppFlavor.storageNamespace` (the bundle identifier) keeps anything stored per-app from being shared
between them.

The apps diverge in exactly two places today: the developer screen, and `ToolRegistry`'s `#if
ANVIL_DEV` block. Keep it that way — a feature flag scattered through views is how two apps become two
codebases.

## Secrets and configuration

Nothing secret is in source, and nothing secret is in a build either: web search goes through
`anvilai.com/api/search`, which holds Anvil's Brave key. `Config/Local.xcconfig` (git-ignored) sets
build settings; a developer's own Brave key travels into the app's `Info.plist` through
`$(ANVIL_BRAVE_API_KEY)`, `AppSecrets` reads it from the bundle, and `WebSearchConfig` then routes
searches to Brave directly. New configuration should follow the same route: an `ANVIL_*` build
setting, an `Info.plist` key, a typed accessor. `ANVIL_HOST` → `AnvilHost` → `AnvilServer.host` is the
second example. Note that an
xcconfig reads `//` as the start of a comment, which is why that setting is a host and not a URL.

The system prompt is the one piece of configuration that is a file rather than a setting: it is
proprietary, so it lives in a private repository and `Scripts/bootstrap.sh` copies it into
`Sources/Prompt/DefaultPrompt.txt`, git-ignored and picked up by the synchronised folder.
`AppSettings.defaultSystemPrompt` reads it from the bundle and falls back to a built-in line, so a
build without the file is a working build. The `systemPrompt` setting holds only a prompt of the
user's own; empty means the default, and `AppSettings.prompt(for:)` resolves it at the moment a
chat is sent. So the proprietary text is never shown in Settings, written to the settings file, or
stored with a chat — those all say "default" by saying nothing.

## Anvil Pro

`ProAccess` is the only thing that knows whether Pro is active, and it learns it from StoreKit's
current entitlements — at launch and whenever a transaction lands — not from the settings file. The
settings Pro unlocks (`systemPrompt`, `sampler`, `theme`, `appIcon`,
`appLockEnabled`, `talkMode`) are ordinary `AppSettings` fields, stored either way; the places that
honour them ask `pro.isUnlocked` first. `ChatModel.conversationOptions()` does it for the model,
`RootView` does it for the theme. The gate is in a few well-named places rather than in every view,
so a lapsed subscription falls back everywhere at once.

The theme reaches views through the environment (`\.theme`, a `Theme` of colours) rather than
through `ChatStyle`'s statics, which is what lets it change while the app is running. `ChatStyle`
keeps the numbers — sizes, corners, motion — and the Liquid Glass helpers.

The development app's **Preview Pro** switch is inside `#if ANVIL_DEV`, the same way the developer
screen is: the public app doesn't compile it.

## Getting a model onto the phone

`ModelCatalog` reads the list at `https://$(ANVIL_HOST)/api/models`; `ModelDownloader` walks a
model's parts, and `ModelDownloadSession` moves the bytes. `ModelLibrary` owns that path and is the
only thing the root scene knows about — a model is a model to everything downstream.

## Storage

Everything personal goes through `PrivateFiles`, which means `.completeFileProtection` and
`isExcludedFromBackup`. Writes are best-effort and never fatal: the phone can lock mid-write, so a
failed save is retried by the next one rather than surfaced as an error. Chats live one folder per
chat, with photos as sibling JPEGs, so deleting a chat is removing a directory.

A downloaded model is built up in the same folder as `<name>.litertlm.partial` and renamed only when
the last part is in, so a half-finished download can never be mistaken for a model worth loading.
`ModelLibrary.refresh()` no-ops while a download is running, so a half-built file is never mistaken
for an installed model.

## Things that look odd but aren't

- **`MarkdownView` is hand-written.** The app ships no third-party dependencies, and SwiftUI's `Text`
  handles only inline Markdown. It also has to render a half-finished code fence sensibly while a
  reply streams.
- **Scroll following does nothing on iOS 17.** It needs `onScrollPhaseChange`, which is iOS 18. The
  degradation is deliberate: on 17 a streaming reply simply doesn't auto-scroll.
- **Benchmark counters are always on.** That's how LiteRT-LM reports token counts and speeds. No fixed
  benchmark token counts are set, so the engine still tokenizes the real prompt and honours the
  model's stop tokens.
- **A search on/off note is injected into the prompt.** Models keep answering the way they did earlier
  in a chat, so toggling search mid-chat adds one line only the model sees.
- **Downloaded models arrive in 512 MB parts.** A GitHub release asset is capped at 2 GiB and a
  `.litertlm` is 2.4–3.4 GB, so the catalog serves a list of parts with a SHA-256 each. Appending them
  one at a time and deleting each as it lands also means a phone needs the model's size free rather
  than twice it, and an interruption costs one part rather than the whole download.

## What's missing

No automated tests yet: the app is a thin UI over a large binary dependency that needs a real device.
The parts worth testing in isolation are the pure ones — `MarkdownParser`, `GemmaToolCall`,
`ChatModel.historyTurns`, `ModelDownloadFiles`'s verify-and-append — and a test target for
those would be a welcome contribution.
