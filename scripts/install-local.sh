#!/bin/zsh
set -euo pipefail

xcodebuild -project CodeQuota.xcodeproj -scheme CodeQuota -configuration Release build

BUILT_APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/CodeQuota-*/Build/Products/Release/CodeQuota.app | head -n 1)

rm -rf /Applications/CodeQuota.app
cp -R "$BUILT_APP" /Applications/
codesign --force --deep -s - /Applications/CodeQuota.app
rm -rf ~/Library/Developer/Xcode/DerivedData/CodeQuota-*

echo "CodeQuota installed in /Applications"
