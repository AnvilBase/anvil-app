# LiteRT-LM privacy packaging

The pinned LiteRT-LM 0.17.0 iOS dynamic framework has no privacy manifest. Its device binary
imports `stat`, `fstat`, `fstatat`, `lstat`, and `mach_absolute_time`. Anvil uses it only for
model/cache files in its own container and local inference timing. This manifest declares
`C617.1` and `35F9.1` for that use; the SDK does not upload inference content.

The public target's **LiteRT-LM Privacy** build phase adds this file inside the embedded
`CLiteRTLM.framework`, then re-signs that framework if code signing is enabled. It leaves the
downloaded Swift package artifact unchanged. `Scripts/check-app-store.py` checks the archived
framework, so a resource accidentally copied into the app alone cannot pass validation.

Re-audit this workaround when updating LiteRT-LM and remove it when upstream ships a manifest
that covers these APIs. The public target disables user-script sandboxing because this phase's
`codesign` invocation needs Keychain access. This phase performs no networking.

[Apple's required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
