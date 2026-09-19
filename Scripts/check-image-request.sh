#!/bin/bash
# Checks that ImageRequest reads a message the way it should.
#
# Deciding whether a message wants a picture is done with regular expressions, and the failure
# that prompted this was a quiet one: an optional article backtracked, and "give me a prompt for
# a high quality image" painted a picture instead of answering. There is no test target in the
# project, so this compiles the one file on its own and runs the cases against it.
#
#     Scripts/check-image-request.sh
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

// true means the message wants a picture made; false means it wants words.
let cases: [(String, Bool)] = [
  // Words about a picture are still words.
  ("give me a prompt for a high quality image that I can use to try", false),
  ("give me a prompt", false),
  ("give me a prompt for an image of a fox", false),
  ("write me a caption for this photo", false),
  ("suggest a title for my drawing", false),
  ("come up with a description of a sunset", false),
  ("make me a list of ideas", false),
  ("write a short story", false),
  ("explain how diffusion models work", false),
  ("how do I take a better photo", false),

  // Asking for a picture.
  ("generate an image of a fox", true),
  ("make me a picture", true),
  ("create a picture of a dog wearing sunglasses", true),
  ("draw a fox", true),
  ("paint the sea at night", true),
  ("a picture of the sea", true),
  ("can you make me an illustration of a whale", true),
  ("generate a banana", true),
  ("create a sunset over the sea", true),
  ("show me a cat", true),
]

var failed = 0
for (text, expected) in cases {
  let got = ImageRequest.isAsking(text) || ImageRequest.probablyAsking(text)
  if got != expected {
    failed += 1
    print("  BAD  read as \(got ? "a picture" : "words"): \(text)")
  }
}

if failed == 0 {
  print("ImageRequest: all \(cases.count) cases read correctly")
} else {
  print("ImageRequest: \(failed) of \(cases.count) cases read wrongly")
}
exit(failed == 0 ? 0 : 1)
SWIFT

xcrun swiftc -O Sources/Chat/ImageRequest.swift "$WORK/main.swift" -o "$WORK/check"
"$WORK/check"
