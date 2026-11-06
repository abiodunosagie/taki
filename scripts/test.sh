#!/bin/zsh
# Run the unit tests. The host app skips its startup under XCTest (AppModel.isRunningTests),
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p build
xcodegen generate --quiet

xcodebuild test \
  -project Taki.xcodeproj \
  -scheme Taki \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation > build/test.log 2>&1 && result=0 || result=$?

grep -E "error:|Executed [0-9]+ tests|TEST (SUCCEEDED|FAILED)|' failed" build/test.log | sort -u | head -40 || true
exit $result
