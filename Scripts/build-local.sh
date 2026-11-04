#!/bin/zsh
# Builds the fork into Codenotch.app with the Command Line Tools alone. Pass --install
# to replace /Applications/Codenotch.app with it.
set -e
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=build-local/Codenotch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Codenotch" "$APP/Contents/MacOS/Codenotch"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Sources/Resources/* "$APP/Contents/Resources/"

# actool ships only with Xcode, so catalog images go in loose; NSImage(named:) finds them by name.
for set in Sources/Assets.xcassets/*.imageset; do
    name="$(basename "$set" .imageset)"
    for file in "$set"/*.svg(N) "$set"/*.png(N); do
        cp "$file" "$APP/Contents/Resources/$name.${file:e}"
        break
    done
done
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp Sources/Assets.xcassets/AppIcon.appiconset/*.png "$ICONSET/" 2>/dev/null || true
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true

PLIST="$APP/Contents/Info.plist"
sed -e 's/$(EXECUTABLE_NAME)/Codenotch/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/local.codenotch.system/' \
    -e 's/$(PRODUCT_NAME)/Codenotch/' \
    -e 's/$(MARKETING_VERSION)/1.24.0/' \
    -e 's/$(CURRENT_PROJECT_VERSION)/26/' \
    -e 's/$(MACOSX_DEPLOYMENT_TARGET)/15.0/' \
    -e 's/$(DEVELOPMENT_LANGUAGE)/en/' \
    Sources/Info.plist > "$PLIST"
for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUAutomaticallyUpdate SUScheduledCheckInterval; do
    plutil -remove "$key" "$PLIST" 2>/dev/null || true
done
plutil -replace CFBundleIconFile -string AppIcon "$PLIST"

codesign --force --deep --sign - "$APP"

if [[ "$1" == "--install" ]]; then
    pkill -x Codenotch || true
    sleep 2
    # Only this fork's own earlier build is replaced outright; anything else goes to the Trash.
    if [[ -d /Applications/Codenotch.app ]]; then
        if [[ "$(defaults read /Applications/Codenotch.app/Contents/Info CFBundleIdentifier)" == local.codenotch.system ]]; then
            rm -rf /Applications/Codenotch.app
        else
            mv /Applications/Codenotch.app "$HOME/.Trash/Codenotch $(date +%H%M%S).app"
        fi
    fi
    ditto "$APP" /Applications/Codenotch.app
fi
