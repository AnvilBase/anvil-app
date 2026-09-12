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
          ┌─────────────────▼───┐      ┌───▼────────────────────┐
          │   OnDeviceEngine    │      │    ComputerEngine      │
          │   actor, LiteRT-LM  │      │    HTTPS + SSE         │
          └─────────┬───────────┘      └───┬────────────────────┘
                    │                      │
                    └──────────┬───────────┘
                               │  both ask for the same prompt and the same tools
                 ┌─────────────▼──────────────┐
                 │  PromptBuilder · ToolRegistry │
                 └─────────────┬──────────────┘
                               │  a running tool reports back through
                 ┌─────────────▼──────────────┐
                 │        ToolSession         │
                 └────────────────────────────┘
```

Both engines emit the same `ReplyEvent` values — text, thinking, searching, sources, searchError,
memorySaved — so `ChatModel` applies a reply to the screen identically no matter where it came from.
That symmetry is the main structural idea in the app. When you add something a reply can do, add a
case there and handle it once.

## Why things are where they are

**`ChatModel` is deliberately the only decision-maker.** Views read its state and call its methods;
they never talk to an engine, the archive, or the Keychain. That's what keeps routing logic (phone vs
computer vs fallback) in one readable place instead of spread across screens.

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
entry carries the sentence the user sees if that's the one that worked. Reply routing is the same
idea: with *Automatic*, an unreachable computer isn't an error, it's a reply on the phone with a note
saying so.

## Where replies run

```
send()
  └─ computerRoute()
       ├─ Run replies on = iPhone            → nil, straight to OnDeviceEngine
       ├─ = My computer, unreachable         → throw (the user asked for the computer)
       ├─ = Automatic, unreachable < 30s ago → nil, skip the timeout entirely
       ├─ = Automatic, /status times out     → nil + notice, reply on the phone
       └─ reachable                          → ComputerEngine
              └─ connection drops before any text, and Automatic
                   → fall through to OnDeviceEngine mid-reply, with a notice
```

The two-second `/status` probe before each remote reply is what makes *Automatic* feel instant when
the computer is off: a failed check is cached for 30 seconds, so the next message doesn't wait again.

## Two apps from one codebase

`Sources/` compiles into both targets. `Apps/AnvilAI` and `Apps/AnvilAIDev` contain one file each — an
`@main` App that shows `AnvilRootScene` — and everything else about their identity comes from
`Config/Public.xcconfig` and `Config/Dev.xcconfig`: display name, bundle identifier, URL scheme,
entitlements, and, for the development app, `ANVIL_DEV`.

`AppFlavor` reads that identity back out of the bundle at runtime rather than hard-coding it, so
`AppFlavor.appName` and `AppFlavor.urlScheme` are correct in both apps and there's exactly one place
that decides them. `AppFlavor.storageNamespace` (the bundle identifier) namespaces the Keychain item,
which is what lets the two apps point at different computers.

The apps diverge in exactly two places today: the developer screen, and `ToolRegistry`'s `#if
ANVIL_DEV` block. Keep it that way — a feature flag scattered through views is how two apps become two
codebases.

## Secrets and configuration

Nothing secret is in source. `Config/Local.xcconfig` (git-ignored) sets build settings; the Brave key
travels into the app's `Info.plist` through `$(ANVIL_BRAVE_API_KEY)` and `AppSecrets` reads it from
the bundle. A missing key isn't an error — web search disables itself and says why. New configuration
should follow the same route: an `ANVIL_*` build setting, an `Info.plist` key, a typed accessor.

## Storage

Everything personal goes through `PrivateFiles`, which means `.completeFileProtection` and
`isExcludedFromBackup`. Writes are best-effort and never fatal: the phone can lock mid-write, so a
failed save is retried by the next one rather than surfaced as an error. Chats live one folder per
chat, with photos as sibling JPEGs, so deleting a chat is removing a directory.

The model is moved, not copied, out of Documents once its size has held steady across two checks —
copying would need 8 GB free, and moving a file that's still being written would leave a truncated
model.

## Things that look odd but aren't

- **`MarkdownView` is hand-written.** The app ships no third-party dependencies, and SwiftUI's `Text`
  handles only inline Markdown. It also has to render a half-finished code fence sensibly while a
  reply streams.
- **`RawToolCalls.swift` parses tool calls out of ordinary content.** llama.cpp sometimes streams a
  tool call as text (llama.cpp issue #22786). Without it, users would see a model's internal call
  syntax mid-answer and the call would never run.
- **Scroll following does nothing on iOS 17.** It needs `onScrollPhaseChange`, which is iOS 18. The
  degradation is deliberate: on 17 a streaming reply simply doesn't auto-scroll.
- **Benchmark counters are always on.** That's how LiteRT-LM reports token counts and speeds. No fixed
  benchmark token counts are set, so the engine still tokenizes the real prompt and honours the
  model's stop tokens.
- **A search on/off note is injected into the prompt.** Models keep answering the way they did earlier
  in a chat, so toggling search mid-chat adds one line only the model sees.

## What's missing

No automated tests yet: the app is a thin UI over a large binary dependency that needs a real device.
The parts worth testing in isolation are the pure ones — `MarkdownParser`, `GemmaToolCall`,
`RawToolCallFilter`, `ChatModel.historyTurns`, `ComputerAddress.url(from:)` — and a test target for
those would be a welcome contribution.
