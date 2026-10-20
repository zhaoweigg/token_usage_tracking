#!/bin/bash
set -euo pipefail
HR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HR_ROOT"
HR_DEVICE="${1:?Usage: scripts/run-simulator.sh SIMULATOR_UDID}"
xcodegen generate
xcodebuild -project Headroom.xcodeproj -scheme Headroom -configuration Debug \
  -destination "platform=iOS Simulator,id=$HR_DEVICE" \
  -derivedDataPath .build/DerivedData build
xcrun simctl boot "$HR_DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$HR_DEVICE" -b
xcrun simctl install "$HR_DEVICE" .build/DerivedData/Build/Products/Debug-iphonesimulator/Headroom.app
xcrun simctl launch --terminate-running-process "$HR_DEVICE" com.example.headroom
open -a Simulator
