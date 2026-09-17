#!/usr/bin/env bash
# Prepares local artifacts only. This script never uploads or submits an app.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
mode="${1:-validate}"
case "$mode" in validate|archive|export) ;; *) echo "Usage: $0 {validate|archive|export}" >&2; exit 2 ;; esac

if [[ -z "${DEVELOPER_DIR:-}" ]] && [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export GIT_LFS_SKIP_SMUDGE=1
major="$(xcodebuild -version | awk '/^Xcode / {split($2,v,"."); print v[1]}')"
if [[ ! "$major" =~ ^[0-9]+$ ]] || (( major < 26 )); then
  echo "Use Xcode 26 or later with the iOS 26 SDK or later." >&2; exit 1
fi
python3 Scripts/check-app-store.py

output="$root/build/app-store/$mode"
mkdir -p "$output"
if [[ "$mode" == export ]]; then
  : "${ANVIL_APP_STORE_ARCHIVE:?Set this to a signed personal-account .xcarchive}"
  : "${ANVIL_APP_STORE_TEAM_ID:?Set Nathan's paid personal Apple Developer team ID, not Based Hardware}"
  python3 Scripts/check-app-store.py "$ANVIL_APP_STORE_ARCHIVE"
  python3 - "$ANVIL_APP_STORE_ARCHIVE" "$output/ExportOptions.plist" "$ANVIL_APP_STORE_TEAM_ID" <<'PY'
import pathlib, plistlib, sys
archive = pathlib.Path(sys.argv[1])
info = plistlib.loads((archive / 'Info.plist').read_bytes())
team = info.get('ApplicationProperties', {}).get('Team')
if not team:
    raise SystemExit('This archive is unsigned. Run archive with the personal developer team first.')
if team != sys.argv[3]:
    raise SystemExit('The archive team does not match the requested personal developer team.')
options = dict(method='app-store-connect', destination='export', signingStyle='automatic',
               teamID=team, manageAppVersionAndBuildNumber=False, uploadSymbols=True)
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(options))
PY
  xcodebuild -exportArchive -archivePath "$ANVIL_APP_STORE_ARCHIVE" \
    -exportPath "$output" -exportOptionsPlist "$output/ExportOptions.plist" \
    -allowProvisioningUpdates > "$output/export.log" 2>&1 || {
      tail -50 "$output/export.log"; exit 1;
    }
  echo "Exported locally to $output. Nothing has been uploaded."
  exit 0
fi

args=(archive -project AnvilAI.xcodeproj -scheme AnvilAI -configuration Release
  -destination 'generic/platform=iOS' -derivedDataPath "$root/build/DerivedData"
  -onlyUsePackageVersionsFromResolvedFile ANVIL_BRAVE_API_KEY= ANVIL_HOST=www.anvilai.com
  SWIFT_ACTIVE_COMPILATION_CONDITIONS= CODE_SIGN_ENTITLEMENTS=Support/AnvilAI/AnvilAI.entitlements)
if [[ "$mode" == archive ]]; then
  : "${ANVIL_APP_STORE_TEAM_ID:?Set Nathan's paid personal Apple Developer team ID, not Based Hardware}"
  : "${ANVIL_APP_STORE_BUNDLE_ID:?Set the bundle ID registered to that personal developer team}"
  : "${ANVIL_APP_STORE_VERSION:?Set the version matching App Store Connect}"
  : "${ANVIL_APP_STORE_BUILD:?Set an unused build number}"
  if [[ ! "$ANVIL_APP_STORE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] ||
     [[ ! "$ANVIL_APP_STORE_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] ||
     [[ "$ANVIL_APP_STORE_BUNDLE_ID" == *.dev ]] ||
     [[ ! "$ANVIL_APP_STORE_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
     [[ ! "$ANVIL_APP_STORE_BUILD" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid team, production bundle ID, version, or build number." >&2; exit 2
  fi
  # Require Anvil's private resources for an official release. bootstrap copies them from
  # the adjacent private repository; no private prompt is committed to this public repository.
  for prompt in Sources/Prompt/DefaultPrompt.txt Sources/Prompt/VoicePrompt.txt; do
    [[ -s "$prompt" ]] || { echo "Missing $prompt; run Scripts/bootstrap.sh." >&2; exit 1; }
  done
  output="$output/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$output"
  args+=(-allowProvisioningUpdates "DEVELOPMENT_TEAM=$ANVIL_APP_STORE_TEAM_ID"
    CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES
    "PRODUCT_BUNDLE_IDENTIFIER=$ANVIL_APP_STORE_BUNDLE_ID"
    "MARKETING_VERSION=$ANVIL_APP_STORE_VERSION" "CURRENT_PROJECT_VERSION=$ANVIL_APP_STORE_BUILD")
else
  args+=(CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=)
fi
archive="$output/AnvilAI.xcarchive"
echo "Building $archive; log: $output/archive.log"
xcodebuild "${args[@]}" -archivePath "$archive" > "$output/archive.log" 2>&1 || {
  tail -50 "$output/archive.log"; exit 1;
}
python3 Scripts/check-app-store.py "$archive" | tee "$output/verification.txt"
if [[ "$mode" == validate ]]; then
  echo "Unsigned validation archive complete. It cannot be uploaded."
else
  echo "Personal-account archive complete: $archive"
  echo "Export using ANVIL_APP_STORE_ARCHIVE and Scripts/app-store.sh export."
fi
