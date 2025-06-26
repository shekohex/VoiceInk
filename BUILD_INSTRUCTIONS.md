# VoiceInk Pro Unlocked - Build Instructions

This document provides step-by-step instructions for building VoiceInk locally with license checking disabled, creating a DMG package without code signing requirements.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.0 or later
- Xcode (latest version recommended)
- Command Line Tools for Xcode
- whisper.cpp framework (already provided at `/Users/shady/github/ggerganov/whisper.cpp/build-apple/whisper.xcframework`)

## Modifications Made

The following modifications have been made to disable license checking and make everyone appear as a Pro user:

### 1. PolarService.swift Changes

The `PolarService` class has been modified to bypass all license validation:

- `checkLicenseRequiresActivation()` - Always returns valid license that doesn't require activation
- `activateLicenseKey()` - Always returns successful activation with fake ID
- `validateLicenseKeyWithActivation()` - Always returns true

### 2. LicenseViewModel.swift Changes

The `LicenseViewModel` class has been modified:

- `loadLicenseState()` - Always sets license state to `.licensed` (Pro user)

## Build Process

### Step 1: Set up whisper.cpp framework

The whisper.cpp framework is already built and available. Copy it to the expected location:

```bash
cp -r /Users/shady/github/ggerganov/whisper.cpp/build-apple /Users/shady/github/Beingpax/
```

### Step 2: Build the project

Navigate to the VoiceInk directory and build with code signing disabled:

```bash
cd /Users/shady/github/Beingpax/VoiceInk

# Build Release version without code signing
xcodebuild -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Release \
  -allowProvisioningUpdates \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  clean build
```

### Step 3: Create distribution directory

Create a distribution folder and copy the built app:

```bash
mkdir -p dist
cp -R /Users/shady/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Release/VoiceInk.app dist/
```

### Step 4: Create DMG package

Create a DMG file for distribution:

```bash
hdiutil create -volname "VoiceInk-Pro-Unlocked" -srcfolder dist -ov -format UDZO VoiceInk-Pro-Unlocked.dmg
```

## Verification

After building, verify the modifications work:

1. Launch the app from `dist/VoiceInk.app`
2. Check that no license prompts appear
3. Verify all Pro features are accessible
4. Test core functionality to ensure the app works properly

## Build Artifacts

After successful completion, you will have:

- **VoiceInk.app** - The built application in `dist/VoiceInk.app`
- **VoiceInk-Pro-Unlocked.dmg** - DMG package for distribution
- **Build logs** - Available in Xcode DerivedData directory

## Notes

- **Code Signing**: All code signing has been disabled to avoid team/certificate requirements
- **License Check**: All license validation has been bypassed
- **Pro Features**: All features are unlocked by default
- **Security**: The app may show security warnings on first launch due to lack of code signing

## Troubleshooting

If you encounter build issues:

1. **Clean build folder**: `rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceInk-*`
2. **Verify whisper framework**: Check that `/Users/shady/github/Beingpax/build-apple/whisper.xcframework` exists
3. **Check Xcode version**: Ensure you're using the latest Xcode version
4. **Dependencies**: Run `xcodebuild -resolvePackageDependencies` if needed

## Alternative Build Commands

For Debug builds:

```bash
xcodebuild -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Debug \
  -allowProvisioningUpdates \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

## Success

If all steps complete successfully, you will have a fully functional VoiceInk application with all Pro features unlocked and no license restrictions.