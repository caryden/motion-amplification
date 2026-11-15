#!/bin/sh
# Builds a release binary and wraps it in the build/MotionAmp.app bundle.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/MotionAmp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MotionAmp "$APP/Contents/MacOS/MotionAmp"

# Bundle the synthetic demo clip. Generating it requires uv and ffmpeg. If
# either is missing, the app still builds, and the demo menu item reports
# that the clip isn't included.
DEMO=build/demo/synthetic-demo.mp4
if [ ! -f "$DEMO" ]; then
  mkdir -p build/demo
  uv run -q --with numpy reference/make_test_video.py "$DEMO" \
    || echo "warning: the synthetic demo clip wasn't generated" >&2
fi
if [ -f "$DEMO" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp "$DEMO" "$APP/Contents/Resources/"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Motion Amp</string>
  <key>CFBundleIdentifier</key><string>local.motionamp</string>
  <key>CFBundleExecutable</key><string>MotionAmp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "Built $APP"
