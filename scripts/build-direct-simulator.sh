#!/bin/bash
# Historical fallback for the initial incomplete Xcode setup. Uses the
# unmodified Xcode compiler/SDK and codesign; it does not repair system files.
set -euo pipefail
HR_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HR_ROOT"
HR_DEVELOPER="$(xcode-select -p)"
HR_TOOLCHAIN="$HR_DEVELOPER/Toolchains/XcodeDefault.xctoolchain"
HR_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
HR_BUILD_VERSION="$(xcodebuild -version | awk '/Build version/{print $3}')"
HR_APP="$HR_ROOT/.build/Simulator/Headroom.app"
HR_EXTENSION="$HR_APP/PlugIns/HeadroomWidgets.appex"
mkdir -p "$HR_EXTENSION"
xcodegen generate
python3 - "$HR_ROOT" <<'PY'
from pathlib import Path
import json, plistlib, sys
root=Path(sys.argv[1])
app=root/'.build/Simulator/Headroom.app'
for source,destination,name,bundle in [('Headroom/Info.plist',app,'Headroom','com.example.headroom'),('HeadroomWidgets/Info.plist',app/'PlugIns/HeadroomWidgets.appex','HeadroomWidgets','com.example.headroom.widgets')]:
    info=plistlib.loads((root/source).read_bytes())
    info.update(CFBundleExecutable=name,CFBundleIdentifier=bundle,CFBundleName=name,CFBundleDisplayName='Headroom',CFBundleDevelopmentRegion='en',CFBundleVersion='1',CFBundleShortVersionString='0.1.0',MinimumOSVersion='17.0',CFBundleSupportedPlatforms=['iPhoneSimulator'],UIDeviceFamily=[1,2])
    (destination/'Info.plist').write_bytes(plistlib.dumps(info))
(root/'.build/const-protocols.json').write_text(json.dumps(['AppIntent','WidgetConfigurationIntent','AppEntity','AppEnum','EntityQuery']))
sources=sorted((root/'HeadroomShared').glob('*.swift'))+sorted((root/'HeadroomWidgets').glob('*.swift'))
(root/'.build/widget-sources.txt').write_text('\n'.join(map(str,sources))+'\n')
(root/'.build/widget-const-files.txt').write_text(str(root/'.build/widgets.swiftconstvalues')+'\n')
PY
"$HR_TOOLCHAIN/usr/bin/swiftc" -emit-executable -parse-as-library -module-name Headroom \
  -target arm64-apple-ios17.0-simulator -sdk "$HR_SDK" -D DEBUG -D HEADROOM_APP -g -Onone \
  HeadroomShared/*.swift Headroom/*.swift -o "$HR_APP/Headroom"
"$HR_TOOLCHAIN/usr/bin/swiftc" -emit-executable -emit-const-values -parse-as-library \
  -application-extension -module-name HeadroomWidgets -target arm64-apple-ios17.0-simulator \
  -sdk "$HR_SDK" -Onone -whole-module-optimization \
  -emit-const-values-path .build/widgets.swiftconstvalues \
  -Xfrontend -const-gather-protocols-file -Xfrontend .build/const-protocols.json \
  HeadroomShared/*.swift HeadroomWidgets/*.swift -o "$HR_EXTENSION/HeadroomWidgets"
"$HR_TOOLCHAIN/usr/bin/appintentsmetadataprocessor" --output "$HR_EXTENSION" \
  --toolchain-dir "$HR_TOOLCHAIN" --module-name HeadroomWidgets --sdk-root "$HR_SDK" \
  --xcode-version "$HR_BUILD_VERSION" --platform-family iOS --deployment-target 17.0 \
  --target-triple arm64-apple-ios17.0-simulator --source-file-list .build/widget-sources.txt \
  --swift-const-vals-list .build/widget-const-files.txt
codesign --force --sign - --entitlements HeadroomWidgets/HeadroomWidgets.entitlements "$HR_EXTENSION"
codesign --force --sign - --entitlements Headroom/Headroom.entitlements "$HR_APP"
"$HR_TOOLCHAIN/usr/bin/swiftc" -emit-executable -parse-as-library \
  -target arm64-apple-ios17.0-simulator -sdk "$HR_SDK" \
  HeadroomShared/UsageModels.swift HeadroomTests/UsageFixtures.swift scripts/DomainSmoke.swift -o .build/domain-smoke
codesign --force --sign - .build/domain-smoke
echo "Built $HR_APP"
