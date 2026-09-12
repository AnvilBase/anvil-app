# Contributing to Anvil AI

Thanks for wanting to help. Anvil AI is an iPhone app that runs a language model locally, so most
contributions need a real device to test on — the simulator builds the app but can't usefully run a
model.

## Getting set up

```sh
git clone https://github.com/AnvilBase/anvil-app.git
cd anvil-app
./Scripts/bootstrap.sh
open AnvilAI.xcodeproj
```

The [README](README.md) covers package resolution, signing with a free Apple ID, and importing a
model. You don't need a Brave Search key unless you're working on web search.

Pick the **AnvilAIDev** scheme while developing. It installs alongside the public app, so you can keep
a working copy on your phone while you break things, and it has **Settings › Developer**.

## The shape of the project

Everything in `Sources/` is compiled into both apps; `Apps/` holds only the two `@main` entry points.
The layout is in the [README](README.md#how-its-built), with more on the design in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Two rules keep the two apps from drifting apart:

- **Tools are declared once**, in `Sources/Tools/ToolRegistry.swift`. Both engines ask it for their
  tools, so anything the model can call on the phone it can also call on your computer. Adding a tool
  means adding one entry, not editing three files.
- **The system prompt is built once**, in `Sources/Engine/PromptBuilder.swift`, for the same reason.

A feature that isn't ready for the public app goes behind `#if ANVIL_DEV` — usually as a
`isDevelopmentOnly: true` entry in the registry. Promoting it later is a one-line move.

## House style

The code aims to read like prose, and reviews hold it to that.

- Two-space indentation, 110-column lines. `.swift-format` and `.editorconfig` carry the settings; if
  you have [swift-format](https://github.com/swiftlang/swift-format) installed,
  `swift-format --in-place --recursive Sources Apps` matches it.
- Comments say **why**, never what the next line obviously does. A comment that explains a workaround,
  a platform limitation, or a decision is worth keeping; one that narrates the code isn't.
- Every type gets a doc comment saying what it's for. Long ones start with a one-line summary, a blank
  line, then the detail.
- Name things for what they mean to the person using the app. `ReplyLocation`, not `BackendMode`.
- No third-party dependencies beyond LiteRT-LM. The Markdown renderer is hand-written for this reason;
  keep it that way.
- Swift concurrency, not completion handlers. Anything slow (file work, inference) stays off the main
  actor: `ChatArchive` and `OnDeviceEngine` are actors on purpose.
- User-facing strings are plain sentences, no jargon and no exclamation marks. Use
  `AppFlavor.appName` rather than writing "Anvil AI" into a string, so both apps read correctly.

## Privacy is a feature, not a preference

The whole point of this app is that your data stays on your phone. A change that adds a network call,
new persistent storage, or a new permission prompt needs to say so plainly in the pull request, and
must keep these true:

- Networking stays confined to the paths the README documents, each visible in the UI and each
  switchable off. No analytics, no crash reporting, no telemetry, ever.
- Anything personal written to disk goes through `PrivateFiles`, which means complete file protection
  and excluded from backups.
- Secrets are never literals in source. They come from `Config/Local.xcconfig` through the bundle, the
  way `AppSecrets` does it.
- Don't log message text, search queries, or photo data.

## Before you open a pull request

There are no automated tests yet — this is a UI-heavy app around a large binary dependency — so
testing is manual and a PR should say what you actually did. As a baseline:

- Both schemes build: `AnvilAI` and `AnvilAIDev`.
- The app runs on a real iPhone with a model imported, and a reply streams.
- Anything you touched still works in airplane mode, and with web search off.
- If you changed model loading: try both GPU and CPU backends, and a context size of 2,048 and 8,192.
- If you changed the composer, scrolling, or message rendering: check on iOS 17 as well as 18 — the
  scroll-following code deliberately does nothing on 17.

Keep pull requests focused; a rename and a behaviour change in one PR are hard to review. Write commit
messages in the imperative mood ("Add a tool for…", not "Added"), and explain the why in the body when
it isn't obvious.

## Reporting bugs and asking for features

Use the issue templates. For a bug, the iPhone model, iOS version, which app (public or development),
the model file, and whether replies were running on the phone or on a computer are usually what's
needed to reproduce it. **Performance and usage** has most of the numbers worth pasting in.

Please don't file security issues publicly — see [SECURITY.md](SECURITY.md).

## License

Contributions are accepted under the MIT License that covers the project. By opening a pull request
you confirm you have the right to contribute the code and are happy for it to be released under those
terms.
