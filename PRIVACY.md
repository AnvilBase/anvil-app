# Privacy

Anvil AI is built so that your conversations stay on your iPhone. This document describes exactly
what the app stores, what it can send, and how to verify it yourself.

There are no accounts, no analytics, no crash reporting, and no telemetry of any kind. The project has
no servers, and the maintainers never receive your data — there is nowhere for it to go.

## What the app stores, and where

| What | Where | Protection |
| --- | --- | --- |
| Chats, including search queries and sources | `Application Support/Chats/<id>/chat.json` | Complete file protection, excluded from backups |
| Photos attached to chats | `Application Support/Chats/<id>/<message>.jpg` | Same |
| Memories | `Application Support/Memory/memories.json` | Same |
| Settings, including your system prompt | `Application Support/Settings/settings.json` | Same |
| Usage totals | `Application Support/Metrics/usage.json` | Same |
| The installed model | `Application Support/Models/` | Excluded from backups |
| Engine caches | `Library/Caches/EngineCache` | Not backed up |

"Complete file protection" means the files are encrypted with a key tied to your passcode and can't be
read while the phone is locked — not even by the app itself. Nothing personal is included in iCloud or
Finder backups.

Chats are deleted automatically after the retention period in **Settings › Chat history** (three days
by default), and **Delete all chats** removes them immediately.

## What can leave the phone

The app has three pieces of networking. The first two use a `URLSession` with no cookies, no cache,
and no stored credentials, and are visible in the UI while they're in use; the third is Apple's.

**1. Web search — `api.search.brave.com`.** Only when web search is on *and* the model decides to
call the tool. What's sent is the query the model wrote, which can include details drawn from your
message, plus the build's Brave API key. Brave's
[privacy policy](https://brave.com/privacy/browser/#brave-search) governs what they do with it.
Nothing else about the chat is sent — not your history, not your system prompt, not your photos. The
reply lists every query it ran. Web search is unavailable entirely in builds without a key.

**2. Downloading a model — `anvilai.com`, then GitHub.** Only from the **Install the AI model** screen, and
only until a model is installed: once you have one, the app never contacts anvilai.com again. Reading
the model list is a plain `GET` of a public JSON file with no query, no identifier, and nothing about
you attached. Tapping **Download** fetches the parts from the same domain, which redirects each one to a
file hosted in a GitHub release — so, as with any download, anvilai.com and GitHub see your IP address
and which model you chose. Nothing about your chats, your settings, or your phone is sent. Downloads
use Wi-Fi unless you turn on **Download over cellular**. A build can be pointed at a different host
with `ANVIL_MODELS_HOST`.

**3. Anvil Pro — the App Store.** Buying, restoring or checking the subscription goes through
StoreKit, which is Apple talking to Apple: what Apple learns is what it learns from any in-app
purchase, under [Apple's privacy policy](https://www.apple.com/legal/privacy/). The app sends it
nothing of its own, and Apple's answer — whether Pro is active — is the only thing that comes back.
Nothing about your chats is involved.

`NWPathMonitor` (`Sources/System/NetworkStatus.swift`) reads whether the phone is online and
transmits nothing. The app has no web views and opens no sockets.

Two Pro features touch the phone's own hardware and nothing beyond it. **Face ID lock** asks iOS to
authenticate you; the app is told yes or no and never sees your face or your passcode. **Talk mode**
reads replies aloud with the voices built into iOS, on the phone, and then listens with the same
on-device speech recognition as the microphone button.

Two things are worth knowing because they aren't the app:

- The photo picker runs in a separate system process. If a photo lives only in iCloud, iOS itself may
  download it; the app doesn't.
- Tapping a source opens it in Safari, outside the app.

## Microphone, speech, and camera

Dictation uses Apple's speech recognizer with `requiresOnDeviceRecognition` set, so audio is
transcribed on the phone and never sent to Apple's servers. If your language has no on-device model,
the app refuses to dictate rather than falling back to the network. Audio isn't recorded or saved
anywhere; only the text you see in the message field exists afterwards.

Camera photos go straight into the message and are not written to your photo library. Every photo is
downscaled to at most 1024 px before any model sees it.

The app never speaks replies aloud; there's no text-to-speech.

## Verifying it yourself

- With a model installed, turn web search off and chat in airplane mode. In **Settings › Privacy & Security › App Privacy Report**, the app should show no
  network activity at all. With web search on, the only domain should be `api.search.brave.com`.
- Read the code: the networking files are `Sources/Tools/BraveSearch.swift` and
  `Sources/Engine/ModelCatalog.swift` with `Sources/Engine/ModelDownloadSession.swift`. Searching the
  project for `URLSession` finds them and nothing else.
- The app is MIT-licensed and builds from source, so nothing here has to be taken on trust.

## A note on API keys

A Brave Search key compiled into a build can be extracted from that build by anyone who has it. Keep
your key in `Config/Local.xcconfig`, don't distribute builds that carry it, and set a monthly usage
limit in Brave's dashboard.
