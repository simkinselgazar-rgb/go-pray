#!/bin/bash
# Builds build/GoPraySpike.app (shield/test modes) and build/GoPraySpikeFS.app (same binary, own bundle id, full-screen stand-in).
set -euo pipefail
cd "$(dirname "$0")"
ID="Developer ID Application: Ahmed Elgazar (3BB4JMG8GR)"
rm -rf build && mkdir -p build
swiftc -swift-version 5 -O Sources/main.swift -o build/GoPraySpike-bin -framework AppKit -framework WebKit -framework AVFoundation -framework ServiceManagement -framework CoreAudio -framework Carbon
mk() { # name bundleid
  local A=build/$1.app
  mkdir -p $A/Contents/MacOS $A/Contents/Resources $A/Contents/Library/LaunchAgents
  cp build/GoPraySpike-bin $A/Contents/MacOS/GoPraySpike
  cat > $A/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>GoPraySpike</string><key>CFBundleIdentifier</key><string>$2</string><key>CFBundleName</key><string>$1</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>0.0.1</string><key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PL
}
mk GoPraySpike com.gopray.spike
mk GoPraySpikeFS com.gopray.spike.fs
cp -R ../../design/scenes build/GoPraySpike.app/Contents/Resources/scenes
rm -rf build/GoPraySpike.app/Contents/Resources/scenes/shots
cp agent/com.gopray.spike.agent.plist build/GoPraySpike.app/Contents/Library/LaunchAgents/
for a in GoPraySpike GoPraySpikeFS; do codesign --force --sign "$ID" --timestamp=none build/$a.app; done
codesign -dv build/GoPraySpike.app 2>&1 | grep -E "Identifier|Authority" | head -3
echo built
