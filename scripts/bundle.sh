#!/bin/bash
set -euo pipefail

APP_NAME="MDViewer"
BUILD_DIR=".build/release"

echo "Building $APP_NAME (release)..."
swift build -c release

echo "Creating app bundle..."
APP_DIR="$APP_NAME.app/Contents"
rm -rf "$APP_NAME.app"
mkdir -p "$APP_DIR/MacOS"
mkdir -p "$APP_DIR/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/MacOS/"

# Copy resource bundle (SwiftPM bundles resources as <Package>_<Target>.bundle)
# The exact name depends on the package/target names. Find it dynamically.
RESOURCE_BUNDLE=$(find -L "$BUILD_DIR" -maxdepth 1 -name "*.bundle" -type d | head -1)
if [ -n "$RESOURCE_BUNDLE" ]; then
    # SwiftPM's generated Bundle.module accessor resolves via:
    #   Bundle.main.bundleURL + "<target>.bundle"
    # For .app bundles, Bundle.main.bundleURL is the .app directory itself,
    # so we place the resource bundle alongside Contents/ in the .app root.
    cp -r "$RESOURCE_BUNDLE" "$APP_NAME.app/"
    echo "Copied resource bundle: $(basename "$RESOURCE_BUNDLE")"
else
    echo "Warning: No resource bundle found in $BUILD_DIR"
fi

# Create Info.plist
cat > "$APP_DIR/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MDViewer</string>
    <key>CFBundleIdentifier</key>
    <string>com.mdviewer.app</string>
    <key>CFBundleName</key>
    <string>MDViewer</string>
    <key>CFBundleDisplayName</key>
    <string>MDViewer</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string>
                <string>markdown</string>
                <string>mdown</string>
                <string>mkd</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
                <string>public.plain-text</string>
            </array>
        </dict>
    </array>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <true/>
</dict>
</plist>
PLIST

# Copy app icon from resource bundle into Resources/
if [ -n "$RESOURCE_BUNDLE" ] && [ -f "$RESOURCE_BUNDLE/Resources/AppIcon.icns" ]; then
    cp "$RESOURCE_BUNDLE/Resources/AppIcon.icns" "$APP_DIR/Resources/"
    echo "Copied app icon"
fi

# Ad-hoc code sign
# Note: --deep signing requires all sub-bundles to have Info.plist files.
# SwiftPM resource bundles lack this, so we sign without --deep.
# The app will still run; use right-click > Open on first launch if Gatekeeper blocks it.
codesign --force --sign - "$APP_NAME.app" 2>/dev/null || echo "Note: Code signing skipped (resource bundle lacks Info.plist). App will still run."

echo ""
echo "Done! Built: $APP_NAME.app"
echo "To install: cp -r $APP_NAME.app /Applications/"
echo "To run:     open $APP_NAME.app"
