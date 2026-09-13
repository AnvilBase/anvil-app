# Security Policy

## Reporting a vulnerability

Please don't open a public issue for a security problem.

Report it privately through GitHub: on the
[Security tab](https://github.com/AnvilBase/anvil-app/security/advisories/new), choose **Report a
vulnerability**. That creates a private advisory only the maintainers can see.

Useful details, as far as you have them: what an attacker can do, the steps to reproduce it, the app
version and iOS version, and whether it needs physical access to the device, a compromised network, or
a hostile companion server.

Expect a first reply within a few days. Once a fix is out, we're happy to credit you in the advisory —
tell us how you'd like to be named, or that you'd rather not be.

## Scope

This is a client-side iPhone app with no backend, so the interesting surface is fairly small:

**In scope**

- Data at rest: chats, photos, memories, and settings escaping complete file protection or being
  swept into a backup.
- The Keychain item holding your computer's access token.
- The pairing URL scheme (`anvil://pair`): anything that lets a link redirect replies, save a token,
  or change settings without the confirmation dialog.
- The connection to your computer: token handling, HTTPS enforcement in `ComputerAddress`, and
  anything a hostile or spoofed server could do to the app — including through streamed content, tool
  arguments, or the raw tool-call parsing in `RawToolCalls.swift`.
- Web search: anything that sends more than the model's query, or that a malicious search result could
  do to the app.
- Any path where data leaves the device that the README and PRIVACY.md don't describe. That's a
  security bug by definition.

**Out of scope**

- A Brave Search API key extracted from a build you made with your own key. Keys compiled into an app
  can always be read out of it; that's why the public app carries none, and why yours belongs in an
  untracked config file with a spending limit.
- Vulnerabilities in LiteRT-LM, llama.cpp, Tailscale, or iOS itself — please report those upstream. We
  do want to hear about it if this app uses them in a way that makes a known issue worse.
- Anything requiring an unlocked, jailbroken, or physically-attached-and-trusted device.
- What a model itself says. Prompt injection that changes the model's words is a model problem; prompt
  injection that makes the app exfiltrate data, call a tool the user disabled, or reach a host outside
  the documented two is very much in scope.

## Supported versions

This is a source-built app with no release channel yet, so fixes land on `main`. If you're running a
build of your own, rebuild from `main` to pick up security fixes.
