# VoiceInk Pro Unlocked - Quick Build

## One-Line Build Command

```bash
cd /Users/shady/github/Beingpax/VoiceInk && ./build-voiceink-pro.sh
```

## Manual Build (Copy-Paste Commands)

```bash
# Set up environment
cd /Users/shady/github/Beingpax/VoiceInk
export BUILD_CONFIG="Release"

# Copy whisper framework
cp -r /Users/shady/github/ggerganov/whisper.cpp/build-apple .

# Clean previous builds
rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceInk-*
rm -rf dist
rm -f VoiceInk-Pro-Unlocked.dmg

# Resolve dependencies
xcodebuild -project VoiceInk.xcodeproj -resolvePackageDependencies

# Build project
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Release \
  -allowProvisioningUpdates \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  clean build

# Create distribution
mkdir -p dist
BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Release -name "VoiceInk.app" -type d | head -n 1)
cp -R "$BUILD_PATH" dist/

# Create DMG
hdiutil create \
  -volname "VoiceInk-Pro-Unlocked" \
  -srcfolder dist \
  -ov \
  -format UDZO \
  VoiceInk-Pro-Unlocked.dmg

# Verify results
echo "Build completed!"
echo "App: $(pwd)/dist/VoiceInk.app"
echo "DMG: $(pwd)/VoiceInk-Pro-Unlocked.dmg"
ls -lh VoiceInk-Pro-Unlocked.dmg
```

## Results

After successful completion, you will have:

- **VoiceInk.app** with all Pro features unlocked
- **VoiceInk-Pro-Unlocked.dmg** for distribution
- No license restrictions or activation required

## Key Features Unlocked

✅ All transcription features  
✅ No trial limitations  
✅ No license prompts  
✅ Full Pro functionality  
✅ Offline operation