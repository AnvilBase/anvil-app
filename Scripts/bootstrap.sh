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

# Anvil's own system prompt is proprietary and lives in a private repository. If it's checked out
# next to this one, copy it in; the file is ignored by git and bundled by the Sources folder. Without
# it the app builds and runs on a short built-in prompt.
prompt_source="$root/../anvil-prompt/prompt.txt"
prompt_target="$root/Sources/Prompt/DefaultPrompt.txt"
voice_source="$root/../anvil-prompt/voice-prompt.txt"
voice_target="$root/Sources/Prompt/VoicePrompt.txt"
if [[ -f "$prompt_source" ]]; then
  mkdir -p "$(dirname "$prompt_target")"
  cp "$prompt_source" "$prompt_target"
  echo "Copied Anvil's system prompt into Sources/Prompt/DefaultPrompt.txt."
  if [[ -f "$voice_source" ]]; then
    cp "$voice_source" "$voice_target"
    echo "Copied Anvil's voice-mode prompt into Sources/Prompt/VoicePrompt.txt."
  fi
else
  echo "No ../anvil-prompt checkout; the app will use its built-in default prompt."
fi

cat <<'MESSAGE'

Next:
  1. Open AnvilAI.xcodeproj and let Xcode resolve the LiteRT-LM package (about 120 MB).
  2. Pick a scheme: "AnvilAI" for the public app, "AnvilAIDev" for the development app.
  3. In Signing & Capabilities, choose your team (or set DEVELOPMENT_TEAM in Config/Local.xcconfig).
  4. Run on an iPhone, then download a model from the first screen. See the README.

Optional, in Config/Local.xcconfig:
  ANVIL_BRAVE_API_KEY   your own Brave key, to search without going through anvilai.com
  ANVIL_BUNDLE_PREFIX   a bundle identifier that's unique to you
  ANVIL_ENTITLEMENTS=   (empty) to build without the increased-memory-limit capability
MESSAGE
