# Anvil AI — App Store preparation

Prepared September 13, 2026; distribution preference updated September 14, 2026.
**The public name is Anvil AI. Use Nathan's personal Apple Developer account for the current
TestFlight beta. Do not use Based Hardware.** This replaces the earlier organization-only plan
for this beta. No app has been uploaded, registered, or submitted by this preparation.

Local verification completed: public iOS Release archive **0.1.0 (1)** with Xcode 26.6 / iOS 26.5;
public and development Release simulator builds; deep signature verification of the public
simulator app and embedded framework; first-launch welcome, live model catalog, and Pro screen
with Restore/Privacy/Terms on an iPhone 17 Pro Max simulator. All seven icons and listing text
limits pass, and both private prompts match the archive. The only build warning is skipped
App Intents metadata extraction because the app has no AppIntents dependency. Distribution
signing/export, Apple server validation, and the updated GitHub CI job have not run.

## Current TestFlight account

Nathan explicitly selected his personal account to let his girlfriend test the app. Do not select
the Based Hardware team or wait for an Anvil organization enrollment for this beta.

1. Verify the personal account has an active paid Apple Developer Program membership. A free
   Xcode Personal Team does not include TestFlight. Membership status is not yet verified.
   [Apple's membership comparison](https://developer.apple.com/support/compare-memberships/).
2. Confirm that account's team ID in Xcode/App Store Connect. Supply it explicitly for signing;
   do not infer the selected team from whichever account Xcode last used.
3. Register or confirm the bundle ID under the personal membership and enable Increased Memory
   Limit. The validation build uses `com.nathanjcx.AnvilAI`; its registration is not verified.
4. Create or select the **Anvil AI** app record in that personal account, upload a signed build,
   and use an external TestFlight group. Apple's first external beta review is required before
   the tester can install. Name availability and the app record are not yet verified.
   [External tester instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

This account selection is for the current beta; it does not authorize a public App Store release.

## Build and export

Xcode 26.6 / iOS SDK 26.5 is installed on this Mac. The release configuration uses Swift
optimization, includes app debug symbols, preserves the Increased Memory Limit entitlement,
and compiles the public target without `ANVIL_DEV`. Apple currently requires Xcode 26 and an
iOS 26 SDK or later. [Upload requirements](https://developer.apple.com/news/upcoming-requirements/).

```sh
# Builds an unsigned artifact and validates the real app bundle. No account changes or upload.
./Scripts/app-store.sh validate
```

Output: `build/app-store/validate/AnvilAI.xcarchive`, `archive.log`, and `verification.txt`.
**The validation archive cannot be uploaded.** It is evidence that Release compiles and packages.

After personal membership and team verification, use the actual personal account values (the placeholders below are
not credentials or proposed identifiers):

```sh
./Scripts/bootstrap.sh
ANVIL_APP_STORE_TEAM_ID=YOUR_TEAM_ID \
ANVIL_APP_STORE_BUNDLE_ID=YOUR_REGISTERED_BUNDLE_ID \
ANVIL_APP_STORE_VERSION=0.1.0 \
ANVIL_APP_STORE_BUILD=1 \
./Scripts/app-store.sh archive

ANVIL_APP_STORE_ARCHIVE='/absolute/path/printed/by/archive/AnvilAI.xcarchive' \
ANVIL_APP_STORE_TEAM_ID=YOUR_TEAM_ID \
./Scripts/app-store.sh export
```

Match the version to App Store Connect and use a previously unused build number. Signing needs
the personal account in Xcode and permission to manage distribution certificates/profiles.
The scripts require explicit release identity values and do not fall back to any configured team.
They clear any Brave API key, force the production host and public compile flags, and verify
the archive. Export uses `app-store-connect` with `destination=export`, so the IPA stays local.
Upload the resulting IPA with Transporter or use Organizer > Distribute App > App Store Connect.

## Listing and review materials

English listing copy is in `app-store/en-US/listing.json` and `description.txt`; reviewer steps
are in `review-notes.txt`. Those are local drafts. The public support address matches the website:
`hello@anvilai.com`. Review contact details in App Store Connect are separate from public metadata.

Before review, finish these account and release checks:

- Publish the corrected `PRIVACY.md` so the in-app and listing URL serves the new text; verify
  the support inbox and public links. The source policy changes are local until published.
- Complete App Privacy from actual hosting and Brave retention practices. **Do not automatically
  select Data Not Collected.** Search queries leave the device; the relay stores IP addresses and
  request times in memory for rate limiting. Determine host access-log retention and Brave API
  retention, and disclose the applicable data types and purposes. Optional email feedback must
  satisfy every Apple exception criterion to omit it. The app manifest currently declares
  required-reason APIs and tracking status; it does not assert an empty collection declaration.
  [Apple's definitions](https://developer.apple.com/app-store/app-privacy-details/).
- Configure both subscription IDs from `ProAccess.swift` in one **Anvil Pro** group on the new
  app record. Product IDs need not match the new bundle ID; do not rename them without coordinating
  code and App Store Connect. Set duration, localized name/description, prices, territories, review
  screenshot, and availability. The prices are $9.99 a month and $99 a year (US), the same pair
  `Support/Anvil.storekit` gives the development app and the same pair the site quotes; App Store
  Connect is where they become real. Include the first subscriptions with the first app submission
  and complete paid-app agreements, tax, and banking.
- Test actual StoreKit product loading, purchase, cancellation, pending purchase, restore, renewal,
  expiration, refund, and offline entitlement behavior in the sandbox/TestFlight. The production
  paywall deliberately cannot sell products until they exist for the selected app/account.
- Complete Apple's age-rating/content questionnaire for the actual model output. **Anvil Raw is
  marketed as unrestricted and Dream currently has no output safety classifier.** Review their
  behavior against App Review guideline 1.1 before submission; an age rating alone does not make
  prohibited content acceptable. This preparation does not certify model content compliance.
- Confirm third-party model licenses and distribution rights, including Gemma terms and the
  complete Dreamshaper/base-model license chain. Catalog labels alone are not license clearance.
- Test on physical iPhones with the smallest supported memory capacity: clean installation,
  Core download/resume, low storage, airplane-mode generation, image/voice input, Dream generation,
  background/foreground, passcode, chat deletion/export, and Pro lapse fallback. Record tested
  devices in the reviewer notes. This Mac's simulator cannot establish model memory reliability.
- Capture screenshots of real use in the public build. Suggested order: a useful chat reply,
  a photo/document question, sources after optional web search, local image generation, settings.
  Use a supported 6.9-inch size, such as **1320×2868**; Apple can scale this for smaller iPhones.
  No final in-use screenshot set is fabricated from simulator onboarding.
  [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
- Confirm copyright holder, release territories, pricing, required trader/business details,
  accessibility declarations, and App Review contact information. Select manual release if you
  want a final release decision after approval.

## What the local checks cover

`check-app-store.py` checks all seven public app icons for 1024×1024 dimensions and no alpha,
app and embedded LiteRT-LM privacy manifests, the built app's name/version/platform, SDK version,
permission descriptions, absence of a Brave key, production host, and app dSYM. Signed archives
also receive deep signature and provisioning-capability checks. It does not contact Apple or
claim App Store server validation, organization eligibility, live purchases, or device inference.

LiteRT-LM 0.17.0's missing SDK manifest is supplied during public-app packaging; see
`Support/LiteRTLM/README.md`. Keep that declaration under review when dependencies change.
Encryption is declared exempt based on HTTPS/iOS file protection/Keychain and CryptoKit hashing;
reassess if adding non-system encryption. GitHub CI now checks an unsigned public release archive
in addition to both simulator builds using Xcode 26.6.
