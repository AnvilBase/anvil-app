#!/bin/sh
# LiteRT-LM 0.17.0's dynamic framework uses stat and mach_absolute_time but has no
# privacy manifest. Keep the declaration inside that framework, where Apple requires it.
set -eu
framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/CLiteRTLM.framework"
test -f "$framework/CLiteRTLM"
/usr/bin/install -m 644 "$SRCROOT/Support/LiteRTLM/PrivacyInfo.xcprivacy" "$framework/PrivacyInfo.xcprivacy"
# Xcode has already signed its package copy. Adding a resource changes its seal.
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
    --preserve-metadata=identifier,entitlements,flags --timestamp=none "$framework"
fi
