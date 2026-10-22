#!/bin/zsh
# Rebuild the spike tools. Output goes to build/ (git-ignored).
set -e
cd "$(dirname "$0")"
mkdir -p build/FakePlayer.app/Contents/MacOS
cp src/Info.plist build/FakePlayer.app/Contents/
swiftc -O src/fakeplayer.swift -o build/FakePlayer.app/Contents/MacOS/FakePlayer
codesign -s - --force build/FakePlayer.app
swiftc -O src/mrtest.swift -o build/mrtest
codesign -s "Developer ID Application: Ahmed Elgazar (3BB4JMG8GR)" --options runtime --force build/mrtest
clang -dynamiclib -framework CoreFoundation src/mrperl.c -o build/libmrperl.dylib
codesign -s - --force build/libmrperl.dylib
