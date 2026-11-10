#!/bin/bash
# Build MenuFold.app (universal: Apple Silicon + Intel).
#   ./build.sh          -> build/MenuFold.app
#   ./build.sh install  -> also copy to ~/Applications and launch
#   ./build.sh zip      -> also create build/MenuFold.zip for sharing
set -euo pipefail
cd "$(dirname "$0")"

APP="build/MenuFold.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos14.0" Sources/*.swift -o "build/MenuFold-$ARCH"
done
lipo -create build/MenuFold-arm64 build/MenuFold-x86_64 -output "$APP/Contents/MacOS/MenuFold"
rm build/MenuFold-arm64 build/MenuFold-x86_64

codesign --force --sign - "$APP"
echo "Built $APP"

case "${1:-}" in
  install)
    pkill -x MenuFold 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/MenuFold.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/MenuFold.app
    echo "Installed and launched ~/Applications/MenuFold.app"
    ;;
  zip)
    ditto -c -k --keepParent "$APP" build/MenuFold.zip
    shasum -a 256 build/MenuFold.zip
    echo "Created build/MenuFold.zip"
    ;;
esac
