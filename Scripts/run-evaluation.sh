#!/bin/bash
set -euo pipefail
PICO_CONTEXT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PICO_CONTEXT_ROOT"
export PICO_CONTEXT_ENABLE_MLX=1
export PICO_CONTEXT_SOURCE_REVISION=$(git rev-parse HEAD)
export PICO_CONTEXT_SWIFT_VERSION=$(swift --version)
swift build --build-system swiftbuild --product ContextEvaluate --disable-index-store -j 2
PICO_CONTEXT_BIN=$(swift build --build-system swiftbuild --show-bin-path)
# Match the example's bundle layout so the upstream Metal resources are available.
PICO_CONTEXT_APP="$PICO_CONTEXT_ROOT/.build/ContextEvaluate.app"
mkdir -p "$PICO_CONTEXT_APP/Contents/MacOS" "$PICO_CONTEXT_APP/Contents/Resources"
cp "$PICO_CONTEXT_BIN/ContextEvaluate" "$PICO_CONTEXT_APP/Contents/MacOS/ContextEvaluate"
shopt -s nullglob
for resource in "$PICO_CONTEXT_BIN/"*.bundle; do
    cp -R "$resource" "$PICO_CONTEXT_APP/Contents/Resources/"
done
cat > "$PICO_CONTEXT_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ContextEvaluate</string>
<key>CFBundleIdentifier</key><string>org.picocontext.evaluate</string>
<key>CFBundleExecutable</key><string>ContextEvaluate</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$PICO_CONTEXT_APP"
exec "$PICO_CONTEXT_APP/Contents/MacOS/ContextEvaluate" "$@"
