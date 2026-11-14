#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app="dist/AgentUsage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/AgentUsage "$app/Contents/MacOS/AgentUsage"
cp Support/Info.plist "$app/Contents/Info.plist"
for bundle in .build/release/*.bundle; do
    if [ -d "$bundle" ]; then
        ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
    fi
done
codesign --force --sign - "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" dist/AgentUsage-macOS.zip
printf '%s\n' "Built $app"
