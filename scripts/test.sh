#!/usr/bin/env bash
set -euo pipefail

TASK_FERRY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TASK_FERRY_DERIVED_DATA="${1:-$TASK_FERRY_ROOT/.derivedData-tests}"
TASK_FERRY_SPM_CACHE="${TASK_FERRY_SPM_CACHE:-$TASK_FERRY_DERIVED_DATA/SourcePackages}"

cd "$TASK_FERRY_ROOT"
scripts/fetch-cloudflared.sh
xcodegen generate
xcodebuild test \
  -project TaskFerry.xcodeproj \
  -scheme TaskFerry \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$TASK_FERRY_DERIVED_DATA" \
  -clonedSourcePackagesDirPath "$TASK_FERRY_SPM_CACHE" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES
