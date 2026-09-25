#!/bin/zsh
set -eu
cd "$(dirname "$0")"
mkdir -p .module-cache CoolCurve.app/Contents/MacOS CoolCurve.app/Contents/Resources
cp Assets/AppIcon.icns CoolCurve.app/Contents/Resources/AppIcon.icns
cp Source/Info.plist CoolCurve.app/Contents/Info.plist
cp Source/LICENSE-Stats.txt CoolCurve.app/Contents/Resources/LICENSE-Stats.txt
xcrun swiftc -module-cache-path .module-cache -swift-version 5 -O -framework SwiftUI -framework AppKit -framework IOKit Source/SMC.swift Source/Policy.swift Source/Dashboard.swift Source/main.swift -o CoolCurve.app/Contents/MacOS/CoolCurve
codesign --force --sign - CoolCurve.app
CoolCurve.app/Contents/MacOS/CoolCurve --self-test
