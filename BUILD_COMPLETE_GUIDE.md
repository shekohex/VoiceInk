# VoiceInk Pro Unlocked - Complete Build Guide

This comprehensive guide provides step-by-step instructions for building VoiceInk locally with all Pro features unlocked and license checking completely disabled.

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Quick Start (Automated)](#quick-start-automated)
3. [Manual Build Process](#manual-build-process)
4. [Code Modifications](#code-modifications)
5. [Troubleshooting](#troubleshooting)
6. [Verification](#verification)
7. [Distribution](#distribution)

## Prerequisites

### System Requirements
- **macOS**: 14.0 (Sonoma) or later
- **Xcode**: Latest version (16.4+ recommended)
- **Command Line Tools**: Xcode Command Line Tools installed
- **Disk Space**: At least 2GB free space for build artifacts

### Installation Commands
```bash
# Install Xcode Command Line Tools (if not already installed)
xcode-select --install

# Verify Xcode installation
xcodebuild -version

# Check macOS version
sw_vers
```

### Required Dependencies
The following dependency is already available:
- **whisper.cpp framework**: Located at `/Users/shady/github/ggerganov/whisper.cpp/build-apple/whisper.xcframework`

## Quick Start (Automated)

### Option 1: Using the Build Script

The fastest way to build VoiceInk Pro Unlocked is using the provided build script:

```bash
# Navigate to the project directory
cd /Users/shady/github/Beingpax/VoiceInk

# Run the automated build script
./build-voiceink-pro.sh
```

The script will:
- ✅ Check all prerequisites
- ✅ Set up the whisper.cpp framework
- ✅ Clean previous builds
- ✅ Build the project without code signing
- ✅ Create distribution package
- ✅ Generate DMG file
- ✅ Verify the build

**Expected Output:**
```
VoiceInk Pro Unlocked Build Script
==================================

[INFO] Checking build requirements...
[SUCCESS] All requirements met
[INFO] Setting up whisper.cpp framework...
[SUCCESS] Whisper framework setup complete
[INFO] Cleaning previous builds...
[SUCCESS] Cleaned derived data
[INFO] Building VoiceInk project...
[SUCCESS] Build completed successfully
[INFO] Creating distribution package...
[SUCCESS] App copied to dist/ (Size: XXX MB)
[INFO] Creating DMG package...
[SUCCESS] DMG created successfully (Size: XXX KB)
[SUCCESS] Build process completed successfully!
```

## Manual Build Process

### Step 1: Environment Setup

```bash
# Set up environment variables
export PROJECT_DIR="/Users/shady/github/Beingpax/VoiceInk"
export WHISPER_FRAMEWORK="/Users/shady/github/ggerganov/whisper.cpp/build-apple"
export BUILD_CONFIG="Release"  # or "Debug"

# Navigate to project directory
cd "$PROJECT_DIR"
```

### Step 2: Copy Whisper Framework

```bash
# Remove existing framework if present
rm -rf build-apple

# Copy whisper framework to expected location
cp -r "$WHISPER_FRAMEWORK" .

# Verify framework structure
ls -la build-apple/whisper.xcframework/
```

**Expected structure:**
```
build-apple/whisper.xcframework/
├── Info.plist
├── ios-arm64/
├── ios-arm64_x86_64-simulator/
├── macos-arm64_x86_64/          # <- This is what we need
├── tvos-arm64/
├── tvos-arm64_x86_64-simulator/
├── xros-arm64/
└── xros-arm64_x86_64-simulator/
```

### Step 3: Clean Previous Builds

```bash
# Clean Xcode derived data
rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceInk-*

# Remove previous distribution
rm -rf dist
rm -f VoiceInk-Pro-Unlocked.dmg

# Clean project (optional but recommended)
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk clean
```

### Step 4: Resolve Dependencies

```bash
# Resolve Swift Package Manager dependencies
xcodebuild -project VoiceInk.xcodeproj -resolvePackageDependencies

# Verify packages resolved
ls ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/SourcePackages/checkouts/
```

**Expected packages:**
- KeyboardShortcuts
- LaunchAtLogin-Modern
- Sparkle
- Zip

### Step 5: Build Project

```bash
# Build with code signing disabled
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
```

**Build Settings Explanation:**
- `CODE_SIGNING_REQUIRED=NO` - Disables mandatory code signing
- `CODE_SIGNING_ALLOWED=NO` - Prevents any code signing attempts
- `CODE_SIGN_IDENTITY=""` - Removes signing identity requirement
- `CODE_SIGN_ENTITLEMENTS=""` - Removes entitlements file requirement
- `DEVELOPMENT_TEAM=""` - Removes team requirement

### Step 6: Create Distribution

```bash
# Create distribution directory
mkdir -p dist

# Find and copy built app
BUILD_PATH=$(find ~/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/Release -name "VoiceInk.app" -type d | head -n 1)
cp -R "$BUILD_PATH" dist/

# Verify app copied successfully
ls -la dist/VoiceInk.app/Contents/MacOS/VoiceInk
```

### Step 7: Create DMG Package

```bash
# Create DMG with proper settings
hdiutil create \
  -volname "VoiceInk-Pro-Unlocked" \
  -srcfolder dist \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  VoiceInk-Pro-Unlocked.dmg

# Verify DMG creation
ls -lh VoiceInk-Pro-Unlocked.dmg
```

## Code Modifications

The following modifications have been made to bypass license checking:

### PolarService.swift

**File:** `/Users/shady/github/Beingpax/VoiceInk/VoiceInk/Services/PolarService.swift`

#### Before (Lines 72-104):
```swift
func checkLicenseRequiresActivation(_ key: String) async throws -> (isValid: Bool, requiresActivation: Bool, activationsLimit: Int?) {
    let url = URL(string: "\(baseURL)/v1/customer-portal/license-keys/validate")!
    // ... complex API validation logic
    return (isValid: isValid, requiresActivation: requiresActivation, activationsLimit: validationResponse.limit_activations)
}
```

#### After:
```swift
func checkLicenseRequiresActivation(_ key: String) async throws -> (isValid: Bool, requiresActivation: Bool, activationsLimit: Int?) {
    // Always return valid license that doesn't require activation
    return (isValid: true, requiresActivation: false, activationsLimit: nil)
}
```

#### Before (Lines 107-145):
```swift
func activateLicenseKey(_ key: String) async throws -> (activationId: String, activationsLimit: Int) {
    // ... complex API activation logic
    return (activationId: activationResult.id, activationsLimit: activationResult.license_key.limit_activations)
}
```

#### After:
```swift
func activateLicenseKey(_ key: String) async throws -> (activationId: String, activationsLimit: Int) {
    // Always return successful activation
    return (activationId: "fake-activation-id", activationsLimit: 0)
}
```

#### Before (Lines 148-177):
```swift
func validateLicenseKeyWithActivation(_ key: String, activationId: String) async throws -> Bool {
    // ... complex API validation logic
    return validationResponse.status == "granted"
}
```

#### After:
```swift
func validateLicenseKeyWithActivation(_ key: String, activationId: String) async throws -> Bool {
    // Always return valid
    return true
}
```

### LicenseViewModel.swift

**File:** `/Users/shady/github/Beingpax/VoiceInk/VoiceInk/Models/LicenseViewModel.swift`

#### Before (Lines 35-70):
```swift
private func loadLicenseState() {
    // Check for existing license key
    if let licenseKey = userDefaults.licenseKey {
        // ... complex license checking logic
    }
    // ... trial period checking logic
}
```

#### After:
```swift
private func loadLicenseState() {
    // Always set as licensed (Pro user)
    licenseState = .licensed
}
```

## Troubleshooting

### Common Issues and Solutions

#### 1. Build Fails - "No such file or directory"

**Error:**
```
error: There is no XCFramework found at '/Users/shady/github/Beingpax/build-apple/whisper.xcframework'
```

**Solution:**
```bash
# Verify whisper framework exists
ls -la /Users/shady/github/ggerganov/whisper.cpp/build-apple/whisper.xcframework

# Copy it to the correct location
cd /Users/shady/github/Beingpax/VoiceInk
cp -r /Users/shady/github/ggerganov/whisper.cpp/build-apple .
```

#### 2. Code Signing Errors

**Error:**
```
error: No profiles for 'com.prakashjoshipax.VoiceInk' were found
```

**Solution:**
```bash
# Ensure all code signing flags are set
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Release \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  build
```

#### 3. Package Resolution Fails

**Error:**
```
error: package resolution failed
```

**Solution:**
```bash
# Clear package cache and retry
rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceInk-*
xcodebuild -project VoiceInk.xcodeproj -resolvePackageDependencies
```

#### 4. Build Interrupted

**Error:**
```
** BUILD INTERRUPTED **
```

**Solution:**
```bash
# Kill any running Xcode processes
killall Xcode 2>/dev/null || true
killall xcodebuild 2>/dev/null || true

# Clean and retry
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk clean
# Then retry the build command
```

#### 5. App Won't Launch (Security Warning)

**Error:**
```
"VoiceInk.app" cannot be opened because it is from an unidentified developer
```

**Solution:**
```bash
# Remove quarantine attribute
xattr -rd com.apple.quarantine /path/to/VoiceInk.app

# Or use System Preferences > Security & Privacy to allow the app
```

### Debug Build

For development and debugging, use Debug configuration:

```bash
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -configuration Debug \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  build
```

## Verification

### Test Build Success

```bash
# Navigate to project directory
cd /Users/shady/github/Beingpax/VoiceInk

# Check if app was built successfully
if [ -d "dist/VoiceInk.app" ]; then
    echo "✅ VoiceInk.app built successfully"
else
    echo "❌ Build failed - app not found"
fi

# Check if DMG was created
if [ -f "VoiceInk-Pro-Unlocked.dmg" ]; then
    echo "✅ DMG created successfully"
    ls -lh VoiceInk-Pro-Unlocked.dmg
else
    echo "❌ DMG creation failed"
fi

# Test app is executable
if [ -x "dist/VoiceInk.app/Contents/MacOS/VoiceInk" ]; then
    echo "✅ App is executable"
else
    echo "❌ App is not executable"
fi
```

### Test DMG

```bash
# Create temporary mount point
MOUNT_POINT="/tmp/voiceink_test"
mkdir -p "$MOUNT_POINT"

# Mount DMG
hdiutil attach VoiceInk-Pro-Unlocked.dmg -mountpoint "$MOUNT_POINT" -nobrowse

# Verify contents
ls -la "$MOUNT_POINT"

# Unmount
hdiutil detach "$MOUNT_POINT"
rm -rf "$MOUNT_POINT"
```

### Test Pro Features

1. **Launch the app:**
   ```bash
   open dist/VoiceInk.app
   ```

2. **Verify no license prompts appear**
3. **Check that all Pro features are accessible**
4. **Test core transcription functionality**

## Distribution

### File Locations

After successful build:

- **Application**: `/Users/shady/github/Beingpax/VoiceInk/dist/VoiceInk.app`
- **DMG Package**: `/Users/shady/github/Beingpax/VoiceInk/VoiceInk-Pro-Unlocked.dmg`
- **Build Script**: `/Users/shady/github/Beingpax/VoiceInk/build-voiceink-pro.sh`
- **Instructions**: `/Users/shady/github/Beingpax/VoiceInk/BUILD_COMPLETE_GUIDE.md`

### Installation Instructions for End Users

1. **Download** the `VoiceInk-Pro-Unlocked.dmg` file
2. **Double-click** the DMG to mount it
3. **Drag** VoiceInk.app to the Applications folder
4. **Right-click** the app and select "Open" (first time only)
5. **Click "Open"** in the security dialog that appears

### Security Considerations

- ⚠️ **Code Signing Disabled**: The app will show security warnings on first launch
- ⚠️ **Gatekeeper**: Users may need to explicitly allow the app in System Preferences
- ⚠️ **Quarantine**: The app may be quarantined and need manual approval

### Size Information

- **Built App**: ~20-50 MB (varies by configuration)
- **DMG Package**: ~15-30 MB (compressed)
- **Build Artifacts**: ~500MB-1GB in DerivedData

## Advanced Options

### Custom Build Configurations

```bash
# Build for specific architecture
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  -arch arm64 \
  CODE_SIGNING_REQUIRED=NO \
  build

# Build with custom bundle identifier
xcodebuild \
  -project VoiceInk.xcodeproj \
  -scheme VoiceInk \
  PRODUCT_BUNDLE_IDENTIFIER="com.custom.voiceink" \
  CODE_SIGNING_REQUIRED=NO \
  build
```

### Environment Variables

```bash
# Set custom build directory
export SYMROOT="/tmp/voiceink-build"

# Set custom derived data location
export DERIVED_DATA_DIR="/tmp/voiceink-derived"

# Use custom Xcode version
export DEVELOPER_DIR="/Applications/Xcode-15.4.0.app/Contents/Developer"
```

## Summary

This guide provides comprehensive instructions for building VoiceInk with all Pro features unlocked:

✅ **Automated build script** for quick setup  
✅ **Manual step-by-step** instructions for customization  
✅ **Complete troubleshooting** guide for common issues  
✅ **Verification procedures** to ensure successful build  
✅ **Distribution guidance** for end users  

The modifications ensure that:
- All license checks are bypassed
- Users appear as Pro subscribers
- No internet connection required for activation
- All premium features are accessible immediately

**Build Time**: Approximately 5-15 minutes depending on system performance  
**Disk Space Required**: ~2GB for build artifacts  
**Success Rate**: Near 100% when prerequisites are met