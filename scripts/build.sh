#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
swiftc -module-cache-path build/ModuleCache -O native/KeychainReader.swift -o collector/keychain-reader
codesign --force --sign - collector/keychain-reader
xcodegen generate
xcodebuild -project QuotaGarden.xcodeproj -scheme QuotaGarden -configuration Release -derivedDataPath build/DerivedData build > build/xcodebuild.log 2>&1
echo 'App: build/DerivedData/Build/Products/Release/Cuota IA.app'
