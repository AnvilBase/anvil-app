# Privacy

Anvil AI is built so that your conversations stay on your iPhone. This document describes exactly
what the app stores, what it can send, and how to verify it yourself.

There are no app accounts, advertising trackers, analytics SDKs, or automatic crash-reporting
services. Chat and image generation run on your iPhone. Optional web search uses Anvil's server
and Brave; model downloads, App Store purchases, and feedback you choose to send also involve
external services, as described below.

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

Chats are kept until you delete them, unless you set a retention period in **Settings › Chat
history**, after which a chat with no activity is deleted automatically; **Delete all chats** removes
them immediately. **Export chats** writes every chat to
one Markdown file and hands it to the share sheet; where it goes from there — Files, AirDrop, another
app — is your choice, and the app keeps no copy beyond the temporary file iOS clears itself.

## What can leave the phone

The app has three pieces of networking. The first two use a `URLSession` with no cookies, no cache,
and no stored credentials, and are visible in the UI while they're in use; the third is Apple's.

**1. Web search — `www.anvilai.com`, then Brave.** Only when web search is on *and* the model decides
to call the tool. What's sent is the query the model wrote, which can include details drawn from your
message. It goes to anvilai.com, which forwards it to Brave Search with Anvil's own API key and
returns Brave's answer; the relay code does not log query text, and the app never sees the key. The
relay keeps IP addresses and request times in memory to limit abuse. Hosting providers also receive
network request information, including IP addresses. Brave's
[privacy policy](https://brave.com/privacy/browser/#brave-search) governs what they do with it.
Nothing else about the chat is sent — not your history, not your system prompt, not your photos, and
no app account or advertising identifier. Like any network service, the relay sees the connection's
IP address. The reply lists every query it ran. A build made with a
developer's own Brave key sends the query to `api.search.brave.com` directly instead.

**2. Downloading a model — `anvilai.com`, then GitHub.** The app reads the catalog during model setup
and when you open model management in Settings, including after a model is installed. Reading
the model list is a plain `GET` of a public JSON file with no query, no identifier, and nothing about
you attached. Tapping **Download** fetches the parts from the same domain, which redirects each one to a
file hosted in a GitHub release — so, as with any download, anvilai.com and GitHub see your IP address
and which model you chose. Nothing about your chats, your settings, or your phone is sent. Downloads
use Wi-Fi unless you turn on **Download over cellular**. A build can be pointed at a different host
with `ANVIL_HOST`.

**3. Anvil Pro — the App Store.** Buying, restoring or checking the subscription goes through
StoreKit, which is Apple talking to Apple: what Apple learns is what it learns from any in-app
purchase, under [Apple's privacy policy](https://www.apple.com/legal/privacy/). The app sends it
nothing of its own, and Apple's answer — whether Pro is active — is the only thing that comes back.
Nothing about your chats is involved.

`NWPathMonitor` (`Sources/System/NetworkStatus.swift`) reads whether the phone is online and
transmits nothing. The app has no embedded web browser; networking uses the services described above.

Three Pro features touch the phone's own hardware and nothing beyond it. **Passcode lock** asks for a
passcode of the app's own, chosen in Settings; a salted hash of it is kept in the Keychain on this
iPhone, never backed up and never sent anywhere, and the app never sees your face or the phone's
own passcode. **Respond with audio**
reads replies aloud with the voices built into iOS, on the phone, and then listens with the same
on-device speech recognition as the microphone button. **Anvil Dream** makes pictures with Core ML on
the phone's Neural Engine: the prompt, the picture, and the model itself never leave the phone, and
the only network use is downloading the model, as in point 2. Pictures are stored with the chat they
were made in, with the same protection as photos.

Other services you can choose to use:

- The photo picker runs in a separate system process. If a photo lives only in iCloud, iOS itself may
  download it; the app doesn't.
- Tapping a source opens it in Safari, outside the app.
- **Settings › Feedback** has a page each for feedback and for a bug report. What you write there is
  sent only when you send it from your mail: **Send** opens it as a mail to you first, and the app
  transmits nothing itself. By default it ends with one line naming the app version, the phone model,
  the iOS version, the model in use and whether Pro is on — shown in full on the page, nothing from
  your chats, and switched off with **Include device details**.

## Microphone, speech, and camera

Dictation uses Apple's speech recognizer with `requiresOnDeviceRecognition` set, so audio is
transcribed on the phone and never sent to Apple's servers. If your language has no on-device model,
the app refuses to dictate rather than falling back to the network. Audio isn't recorded or saved
anywhere; only the text you see in the message field exists afterwards.

On supported iOS versions, Apple's speech analyzer may download a language asset before the first
use. That download installs the recognition model; it does not send your microphone audio.

Camera photos go straight into the message and are not written to your photo library. Every photo is
downscaled to at most 1024 px before any model sees it.

Anvil Pro can read replies aloud using Apple's installed voices. Speech synthesis runs on the phone.

## Verifying it yourself

- With a model installed, turn web search off and chat in airplane mode. Chat and image generation
  should still work. **Settings › Privacy & Security › App Privacy Report** can show model catalog,
  download, search, and App Store traffic when online; generation itself does not upload your chats.
- Read the code: the networking files are `Sources/Tools/BraveSearch.swift` and
  `Sources/Engine/ModelCatalog.swift` with `Sources/Engine/ModelDownloadSession.swift`. Searching the
  project for `URLSession` finds them and nothing else.
- The app is MIT-licensed and builds from source, so nothing here has to be taken on trust.

## A note on API keys

The public app carries no API key: Anvil's Brave key stays on anvilai.com. If you build with a key of
your own, it can be extracted from that build by anyone who has it. Keep it in `Config/Local.xcconfig`,
don't distribute builds that carry it, and set a monthly usage limit in Brave's dashboard.

## Contact

For privacy questions or requests about feedback you have sent, email [hello@anvilai.com](mailto:hello@anvilai.com).
Delete local chats and memories in Settings; deleting the app removes its local app-container data.
