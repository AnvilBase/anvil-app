#!/usr/bin/env bash
# Prepares a fresh clone: creates Config/Local.xcconfig from the example, if it isn't there yet.
# Nothing in Local.xcconfig is required to build, so this is a convenience, not a step you must run.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
local_config="$root/Config/Local.xcconfig"
example="$root/Config/Local.xcconfig.example"

if [[ -f "$local_config" ]]; then
  echo "Config/Local.xcconfig already exists; leaving it alone."
else
  cp "$example" "$local_config"
  echo "Created Config/Local.xcconfig from the example."
fi

cat <<'MESSAGE'

Next:
  1. Open AnvilAI.xcodeproj and let Xcode resolve the LiteRT-LM package (about 120 MB).
  2. Pick a scheme: "AnvilAI" for the public app, "AnvilAIDev" for the development app.
  3. In Signing & Capabilities, choose your team (or set DEVELOPMENT_TEAM in Config/Local.xcconfig).
  4. Run on an iPhone, then copy a .litertlm model file onto the phone. See the README.

Optional, in Config/Local.xcconfig:
  ANVIL_BRAVE_API_KEY   turns on web search
  ANVIL_BUNDLE_PREFIX   a bundle identifier that's unique to you
  ANVIL_ENTITLEMENTS=   (empty) to build without the increased-memory-limit capability
MESSAGE
