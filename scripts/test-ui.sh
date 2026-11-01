#!/usr/bin/env bash
# The UI journey. Ad-hoc signed, and always the Debug build, which only ever sees demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
scripts/fetch-cloudflared.sh >/dev/null
xcodegen generate >/dev/null
mkdir -p build
rm -rf build/results-ui.xcresult
xcodebuild test -project TaskFerry.xcodeproj -scheme TaskFerryUI -configuration Debug \
  -destination platform=macOS -derivedDataPath build/ui -resultBundlePath build/results-ui.xcresult \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= "$@" > build/ui.log 2>&1 || {
    grep -E " error:|Test Case .*failed|XCTAssert" build/ui.log | sort -u | cut -c1-220 >&2
    exit 1
  }
grep -E "Test Case .*passed|TEST SUCCEEDED" build/ui.log | sort -u | cut -c1-120
