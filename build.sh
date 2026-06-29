#!/bin/bash
# WMover 빌드 스크립트 — 소스를 컴파일해 WMover.app 번들을 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP="WMover.app"
BIN="$APP/Contents/MacOS/WMover"

echo "▸ 이전 빌드 정리"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

echo "▸ Info.plist 생성"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>WMover</string>
    <key>CFBundleDisplayName</key>     <string>WMover</string>
    <key>CFBundleIdentifier</key>      <string>com.suyong.wmover</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleExecutable</key>      <string>WMover</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ 컴파일"
swiftc -O \
    Sources/WMover/main.swift \
    -framework Cocoa -framework ApplicationServices -framework IOKit \
    -o "$BIN"

echo "▸ 코드 서명 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "✅ 완료: $(pwd)/$APP"
echo "   실행:  open $APP   (첫 실행 시 손쉬운 사용 권한 허용 필요)"
