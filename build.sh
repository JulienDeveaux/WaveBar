#!/bin/bash
set -e

cd "$(dirname "$0")"

APP="WaveBar.app"

echo "==> Building WaveBar..."
swift build -c release 2>&1

echo "==> Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp .build/release/WaveBar "$APP/Contents/MacOS/"

# Copy Info.plist
cp Resources/Info.plist "$APP/Contents/"

# Copy app icon
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Ad-hoc sign with entitlements
echo "==> Signing..."
codesign --force --sign - --entitlements Resources/Entitlements.plist "$APP"

echo ""
echo "==> Built successfully: $APP"
echo "==> Run with: open $(pwd)/$APP"
