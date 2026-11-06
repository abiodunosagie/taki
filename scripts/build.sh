#!/bin/zsh
# Build Taki (Release), install it to /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")/.."
app_name="Taki"
mkdir -p build
xcodegen generate --quiet

xcodebuild \
  -project Taki.xcodeproj \
  -scheme Taki \
  -configuration Release \
  -derivedDataPath build/DerivedData \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
  build > build/build.log 2>&1 || {
    grep -E "error:" build/build.log | head -20 || true
    echo "Build failed, full log: build/build.log"
    exit 1
  }

app="build/DerivedData/Build/Products/Release/$app_name.app"
codesign --verify --deep --strict "$app"

osascript -e "quit app \"$app_name\"" 2>/dev/null || true
for _ in {1..50}; do
  pgrep -x "$app_name" > /dev/null || break
  sleep 0.2
done
if pgrep -x "$app_name" > /dev/null; then
  pkill -x "$app_name" || true
  sleep 1
fi
rm -rf "/Applications/$app_name.app"
ditto "$app" "/Applications/$app_name.app"
open "/Applications/$app_name.app"

echo "Installed /Applications/$app_name.app"
