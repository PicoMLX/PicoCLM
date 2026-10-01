#!/bin/bash
set -euo pipefail

PICO_CONTEXT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PICO_CONTEXT_ROOT"
export PICO_CONTEXT_ENABLE_MLX=1

# Swift Build compiles the dependency's Metal sources, including on Swift 6.2.
swift build --build-system swiftbuild --product ContextPlayground --disable-index-store -j 2
PICO_CONTEXT_BIN=$(swift build --build-system swiftbuild --show-bin-path)
PICO_CONTEXT_APP="$PICO_CONTEXT_ROOT/.build/ContextPlayground.app"
mkdir -p "$PICO_CONTEXT_APP/Contents/MacOS" "$PICO_CONTEXT_APP/Contents/Resources"
cp "$PICO_CONTEXT_BIN/ContextPlayground" "$PICO_CONTEXT_APP/Contents/MacOS/ContextPlayground"
shopt -s nullglob
for resource in "$PICO_CONTEXT_BIN/"*.bundle; do
    cp -R "$resource" "$PICO_CONTEXT_APP/Contents/Resources/"
done
cat > "$PICO_CONTEXT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ContextPlayground</string>
<key>CFBundleIdentifier</key><string>org.picocontext.playground</string>
<key>CFBundleExecutable</key><string>ContextPlayground</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$PICO_CONTEXT_APP"
exec "$PICO_CONTEXT_APP/Contents/MacOS/ContextPlayground" "$@"
