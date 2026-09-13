# Anvil AI

A private AI assistant for iPhone. The model runs on the phone, the chats stay on the phone, and
nothing is uploaded — no accounts, no analytics, no telemetry.

Anvil AI is a SwiftUI app built on [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM). The
model file isn't bundled in the app; you install one from the model screen. Two things reach the
network, both visible in the UI: downloading a model, and web search.

**Two apps, one codebase.** `AnvilAI` is the public app. `AnvilAIDev` is the development app: same
code, its own bundle identifier, so it installs alongside the public one with separate chats,
settings, and imported model. They're identical today. As tools land in the development app first,
the difference will live behind a single compile-time flag — see
[Two apps](#two-apps-public-and-development).

- **Requirements:** Xcode 16 or newer (the project uses folder-synchronized groups), iOS 17.0 or
  newer, and an iPhone with enough memory for a 3–4 GB model. The simulator can build the app but
  can't usefully run a model.
- **Dependency:** the LiteRT-LM Swift package, `0.17.x` — the API this code was written against.
- **License:** MIT. See [LICENSE](LICENSE).

## Quick start

```sh
git clone https://github.com/AnvilBase/anvil-app.git
cd anvil-app
./Scripts/bootstrap.sh          # optional: creates Config/Local.xcconfig
open AnvilAI.xcodeproj
```

1. Let Xcode resolve the LiteRT-LM package on first open. It downloads about 120 MB of prebuilt
   framework. If you see `no such module 'LiteRTLM'`, use **File › Packages › Resolve Package
   Versions**. Resolving needs roughly 3.5 GB of free disk (a 2.7 GB git mirror, a 0.5 GB checkout,
   and the framework itself).
2. Choose a scheme: **AnvilAI** or **AnvilAIDev**.
3. In **Signing & Capabilities**, pick your team. A free Apple ID works — see
   [Signing](#signing-and-bundle-identifiers).
4. Run on your iPhone (⌘R), then [install a model](#install-a-model).

The app builds and runs with no configuration. Everything personal — your signing team, your bundle
prefix, your Brave Search key — goes in `Config/Local.xcconfig`, which git ignores.

### Configuration

`Config/Local.xcconfig.example` lists every setting. Copy it to `Config/Local.xcconfig` (or run
`./Scripts/bootstrap.sh`) and uncomment what you need:

| Setting | What it does |
| --- | --- |
| `DEVELOPMENT_TEAM` | Your Apple Developer team, so you don't have to pick it in Xcode each time. |
| `ANVIL_BUNDLE_PREFIX` | Reverse-DNS prefix for both apps. Change it if `com.anvilbase` is taken for you. |
| `ANVIL_BRAVE_API_KEY` | Turns on web search. Without it the feature is simply unavailable. |
| `ANVIL_ENTITLEMENTS` | Set it empty to build without the increased-memory-limit capability. |
| `ANVIL_MODELS_HOST` | Where the app downloads models from. Defaults to `www.anvilai.com`. |

There is no `Secrets.swift` and no key anywhere in the source. The key travels from
`Config/Local.xcconfig` into the app's `Info.plist` at build time, and `AppSecrets` reads it back
from the bundle at runtime. Anyone with a copy of a build can still extract a key compiled into it,
so don't share builds that carry yours, and set a monthly limit in the
[Brave dashboard](https://api-dashboard.search.brave.com).

### Signing and bundle identifiers

| | Public app | Development app |
| --- | --- | --- |
| Target and scheme | `AnvilAI` | `AnvilAIDev` |
| Name on the Home Screen | Anvil AI | Anvil Dev |
| Bundle identifier | `$(ANVIL_BUNDLE_PREFIX).AnvilAI` | `$(ANVIL_BUNDLE_PREFIX).AnvilAI.dev` |
| URL scheme | `anvil://` | `anvil-dev://` |

The committed project carries no team ID, so signing is yours to set: choose a team in **Signing &
Capabilities** (Xcode keeps that in your own workspace, not in the repo) or set `DEVELOPMENT_TEAM`
in `Config/Local.xcconfig`. With a free Apple ID, set `ANVIL_BUNDLE_PREFIX` to something nobody else
has claimed.

**Increased memory limit.** Both apps request `com.apple.developer.kernel.increased-memory-limit`,
without which iOS may kill the app while a 3–4 GB model loads. Free Apple IDs can't sign it: if you
see *"Personal development teams do not support the Increased Memory Limit capability"*, put
`ANVIL_ENTITLEMENTS =` (empty) in `Config/Local.xcconfig`. Then, if iOS still closes the app while
loading, lower **Settings › Model › Context size** to 2,048 or turn off **Image input**.

**Running from Xcode.** Turn on **Settings › Privacy & Security › Developer Mode** on the iPhone,
connect it by cable, select it as the run destination, and press ⌘R. The first time, trust the
certificate under **Settings › General › VPN & Device Management**. A free Apple ID's install
expires after 7 days; run it again from Xcode to renew. Reinstalling keeps the imported model,
chats, and settings as long as the bundle identifier doesn't change.

### Git LFS errors while resolving the package

LiteRT-LM keeps Android binaries in Git LFS, and one of those objects is missing upstream. None of
them are needed for iOS, where the framework arrives as a release zip. If resolving fails with
`git-lfs: command not found` or `remote missing object` for something under `prebuilt/android_arm64`:

- Install git-lfs and skip those folders:
  `brew install git-lfs && git config --global lfs.fetchexclude "prebuilt/**"`
- If it works in Terminal but Xcode still says `git-lfs: command not found`, Xcode launched from the
  Dock doesn't search `/opt/homebrew/bin`. Point the filters at the full path:
  `git config --global filter.lfs.process "/opt/homebrew/bin/git-lfs filter-process"`, and the same
  for `filter.lfs.clean` and `filter.lfs.smudge`.
- Or resolve once from Terminal with LFS downloads skipped:
  `GIT_LFS_SKIP_SMUDGE=1 xcodebuild -resolvePackageDependencies -project AnvilAI.xcodeproj`

## Install a model

A new install opens on a welcome screen — what the app is, in three lines, and **Continue**. It is
shown once. After that the app ships without a model — it's gigabytes, and which one you want is your
choice — so the next screen asks for one.

### Download it in the app

The first screen lists the models published at
[anvilai.com/api/models](https://www.anvilai.com/api/models). Tap **Download** and leave it running.

| Model | Size | Licence |
| --- | --- | --- |
| Anvil Forge | 3.41 GB | [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) |

A model is served as a list of 512 MB parts, because a file that size can't be hosted as a single
asset. The app downloads them one at a time, checks each against its SHA-256, appends it to the file
it's building, and deletes it — so the phone needs the model's size free, plus one part, not twice the
model. Progress is written down after every part, so closing the app or losing Wi-Fi costs you at most
the part in flight; reopening the screen offers to carry on. The transfer runs in a background
`URLSession`, so it keeps going while you're in another app.

Downloads are Wi-Fi only unless you turn on **Download over cellular** on that screen. The catalog and
the model files are published from
[AnvilBase/anvil-models](https://github.com/AnvilBase/anvil-models), which also holds the script that
publishes them — point `ANVIL_MODELS_HOST` (see [Configuration](#configuration)) at your own
deployment to serve your own.

A new model replaces the old one. If loading fails, **Settings › Model** offers **Remove model**. The
first load is slow; engine caches go in `Library/Caches/EngineCache`, so later launches are much
faster.

## What the app does

**Chatting.** Saved chats are listed newest first, searchable by title and message text. Reopening an
older chat gives its most recent messages back to the model (about half the context; photos are noted
in text rather than re-sent). Tap one of your own messages to edit and resend it — that replaces it
and every reply after it. The latest reply has a **Regenerate** button, which also retries a failed
one. Long-press any message to copy it whole, or **Select Text** to pick out part of it; code blocks
have their own Copy button.

**Photos.** The camera button offers **Take Photo** or **Choose from Library**. Every photo is
downscaled on the phone to at most 1024 px before any model sees it, and stored only with the chat —
camera photos aren't saved to your photo library. Tap a photo to open it full screen: pinch or
double-tap to zoom, drag to pan, swipe down to dismiss.

**Voice input.** When the message field is empty, the Send button becomes a microphone. Speech is
typed into the field by Apple's recognizer, restricted to on-device recognition, so audio never
leaves the phone; if your language can't be recognized on-device, dictation is refused rather than
sent to Apple's servers. With **Settings › Voice input › Send when you stop talking**, a pause sends
the message. Replies are never read aloud.

**Memory.** The model can save a short fact about you with the `save_memory` tool, and the reply
shows what it saved. Saved facts (newest first, up to about 1,500 characters) are added to the
instructions for new chats. **Settings › Memory** lists them, and lets you add, delete, or clear
them. They're stored in `Application Support/Memory` with complete file protection and aren't
backed up.

**Current time.** The `get_current_time` tool reads the iPhone's clock for any time zone. It works
offline and with web search off, so "what time is it in NYC?" gets an exact answer instead of a
stale search snippet.

**Web search.** Off by default, and unavailable at all unless the build has a Brave Search key. The globe
button next to the message field toggles it. The model decides when to search, and the reply shows
the queries it ran plus a numbered **Sources** list matching its `[1]`, `[2]` citations. The model
receives Brave's info box and top two direct answers when available, then the web results, each with
a snippet and how recent it is. Only the queries the model writes leave the phone — they can include
details from your message. While the phone is offline the button is disabled and the status line says
so; your preference is kept and search resumes when the connection returns.

**Formatting.** Replies render Markdown with a small built-in renderer (no third-party
dependencies): headings, fenced code blocks with a language label and Copy button, lists, quotes,
tables, dividers, and inline bold, italics, code, and links. LaTeX like `$O(n)$` is shown as code. An
unfinished code block renders as code while the reply streams.

**Settings**, in order: system prompt · memory · voice input · web search · metrics ·
generation (temperature, top-K, top-P, max reply length, thinking) · model (backend, context size,
image input — these need **Reload model**) · chat history (delete chats after 1, 3, 7, or 30 days, or
never) · developer (development app only).

**Metrics.** The caption under each reply — tokens, decode speed, time to first token, where it ran —
opens the full breakdown. **Performance and usage** shows live app memory, memory left before the iOS
limit, GPU (Metal) memory, CPU, and thermal state, each explained; what the loaded model supports;
the context this chat is using; and totals across every reply, which survive deleting chats.

- **App memory** is what iOS counts against the app's limit (model, context, image encoder, UI).
- **Memory left before iOS limit** is how much more the app can use before iOS closes it. If it nears
  zero, lower the context size or turn off image input.
- **GPU (Metal) memory** is the part of app memory set aside for the GPU. iPhones share one pool of
  RAM, so it isn't extra, and it says nothing about how busy the GPU is — iOS doesn't expose that.
- Token counts and speeds come from LiteRT-LM's experimental benchmark counters, which are always on.
  No fixed benchmark token counts are set, so the engine still tokenizes the real prompt and stops at
  the model's own stop tokens: replies are unaffected.

## Two apps: public and development

Both targets compile everything in `Sources/`. The only difference is that `AnvilAIDev` defines
`ANVIL_DEV`, which today adds **Settings › Developer** (build identity plus the live tool list) and a
DEV chip in the toolbar.

Tools are declared in one place, [`Sources/Tools/ToolRegistry.swift`](Sources/Tools/ToolRegistry.swift),
and the engine asks it for their tools — so what the model can call is described where the
model on the phone can call. To add a tool to the development app only, write it in `Sources/Tools`
and add an entry inside the registry's `#if ANVIL_DEV` block:

```swift
private static let developmentOnly: [ToolEntry] = [
  ToolEntry(
    name: MyNewTool.name,
    summary: "What it does, in one line.",
    isDevelopmentOnly: true,
    make: { MyNewTool() }),
]
```

Promoting it to the public app later means moving that one entry into `shared`. Nothing else changes.

## How it's built

```
Apps/            the two @main entry points, ~10 lines each
Config/          xcconfig build settings; Local.xcconfig (ignored) holds anything personal
Sources/         everything else, compiled into both apps
  App/           flavor identity (public vs development) and the root scene
  Chat/          chat state, the transcript model, and protected on-disk storage
  Engine/        the model on this iPhone: downloading and importing it, prompt building
  Tools/         the tool registry and the tools themselves
  Memory/        facts remembered across chats
  Settings/      settings model and build-time secrets
  System/        device metrics, images, connectivity, dictation
  UI/            every screen
Support/         per-app Info.plist and entitlements
```

| File | Role |
| --- | --- |
| `App/AppFlavor.swift` | Public or development build: app name, URL scheme, storage namespace |
| `App/AnvilRootScene.swift` | Switches between welcome, installing a model and chatting; history and foreground work |
| `Chat/ChatModel.swift` | The observable state every screen reads; decides where each reply runs |
| `Chat/ChatTranscript.swift` | Chat, message, reply-stats, and usage-totals models |
| `Chat/ChatArchive.swift` | Saves chats, photos, and totals as protected files |
| `Chat/PrivateFiles.swift` | Complete file protection, excluded from backups |
| `Engine/OnDeviceEngine.swift` | LiteRT-LM engine and conversation: load with fallbacks, stream, cancel, count |
| `Engine/ModelLibrary.swift` | Finds the installed model in private storage and keeps it out of backups |
| `Engine/ModelCatalog.swift` | The models anvilai.com publishes, and where to fetch their parts |
| `Engine/ModelDownloader.swift` | Downloads a model part by part, checks each one, appends them into the file |
| `Engine/ModelDownloadSession.swift` | The background URLSession that keeps a download running when the app isn't |
| `Engine/PromptBuilder.swift` | The system prompt both engines use |
| `Engine/EngineTypes.swift` | Model details, conversation options, reply events and counters |
| `Tools/ToolRegistry.swift` | Where tools are declared, and where the two apps diverge |
| `Tools/ToolSession.swift` | Connects a running tool to the streaming reply |
| `Tools/BraveSearch.swift` | Brave Search client |
| `Tools/WebSearchTool.swift`, `ClockTool.swift`, `MemoryTool.swift` | The three tools |
| `Memory/MemoryStore.swift` | Facts remembered across chats |
| `Settings/AppSettings.swift` | Settings model and its protected JSON file |
| `Settings/AppSecrets.swift` | Reads build-time keys from the bundle |
| `System/DeviceMetrics.swift` | Memory footprint, available memory, Metal memory, CPU, thermal state |
| `System/ImageProcessing.swift` | Downscales photos to 1024 px JPEG; decodes saved photos |
| `System/NetworkStatus.swift` | Watches connectivity so web search is disabled while offline |
| `System/SpeechInput.swift` | On-device dictation |
| `UI/ChatScreen.swift` | Message list, scroll following, notices, the bar across the top |
| `UI/SidebarContainer.swift` | The drawer the chat slides over: button, edge swipe, scrim |
| `UI/ChatSidebar.swift` | What's in the drawer: search, new chat, chats by day, settings |
| `UI/Composer.swift` | Input card: photos, web search, field, Send/Stop/microphone |
| `UI/MessageRow.swift` | One message, with thinking, searches, sources, and metrics |
| `UI/ChatStyle.swift` | Shared colours and the Liquid Glass helpers |
| `UI/MarkdownView.swift` | The Markdown renderer |
| `UI/WelcomeScreen.swift`, `SettingsScreen.swift`, `MetricsScreen.swift`, `ModelSetupScreen.swift`, `MemoryScreen.swift`, `DeveloperScreen.swift` | The rest of the screens |

**Engine fallbacks.** With the backend set to Automatic, loading tries GPU with vision on CPU, then
GPU text-only, then CPU with vision on CPU, then CPU text-only, and shows a banner if it had to fall
back. GPU only and CPU only try just their half of that list.

**LiteRT-LM APIs used (0.17.0).** `EngineConfig(modelPath:backend:visionBackend:maxNumTokens:cacheDir:)`,
`Engine(engineConfig:)`, `initialize()`, `createConversation(with:)`, `ConversationConfig`,
`SamplerConfig`, `ThinkingConfig`, `Tool` + `@ToolParam`, `sendMessageStream(_:maxOutputTokens:)`,
`cancel()`, `getTokenCount()`, `ExperimentalFlags.enableBenchmark` + `getBenchmarkInfo()`,
`Capabilities(modelPath:)`, and `Message(contents:)` for image input.

More detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Privacy

The app has two pieces of networking, both on a `URLSession` with no cookies or cache:

- `BraveSearch` in `Sources/Tools/BraveSearch.swift` calls `api.search.brave.com`, only when web
  search is on and the model calls the tool.
- `ModelCatalog` and `ModelDownloadSession` in `Sources/Engine/` call `anvilai.com` to list and
  download models, only from the model screen, and never once a model is installed. Neither request
  carries anything about you or your chats.

`NWPathMonitor` reads whether the phone is online and sends nothing. There are no web views, no
sockets, no analytics, and no crash reporting. Chats (including search queries and sources), photos,
memories, settings, and usage totals live in Application Support with complete file protection —
unreadable while the phone is locked — and are excluded from backups. Chats are deleted automatically
after the retention period.

To check: with web search off, chat in airplane mode, then look at **Settings › Privacy & Security ›
App Privacy Report**. There should be no network activity for the app once a model is installed. With
web search on, the only domain should be `api.search.brave.com`. See [PRIVACY.md](PRIVACY.md).

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) — it covers the
layout, the house style (2-space indent, 110 columns, comments that explain why), and what to test
before opening a PR. Security reports go through [SECURITY.md](SECURITY.md), not the issue tracker.
