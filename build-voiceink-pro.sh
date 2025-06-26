#!/bin/bash

# VoiceInk Pro Unlocked Build Script
# This script builds VoiceInk locally with license checking disabled
# and creates a DMG package without code signing requirements.

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_DIR="/Users/shady/github/Beingpax/VoiceInk"
WHISPER_FRAMEWORK_SOURCE="/Users/shady/github/ggerganov/whisper.cpp/build-apple"
BUILD_CONFIGURATION="Release"  # Change to "Debug" if preferred
DMG_NAME="VoiceInk-Pro-Unlocked"

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_requirements() {
    log_info "Checking build requirements..."
    
    # Check if Xcode is installed
    if ! command -v xcodebuild &> /dev/null; then
        log_error "Xcode command line tools not found. Please install Xcode."
        exit 1
    fi
    
    # Check Xcode version
    XCODE_VERSION=$(xcodebuild -version | head -n 1 | awk '{print $2}')
    log_info "Found Xcode version: $XCODE_VERSION"
    
    # Check if project directory exists
    if [ ! -d "$PROJECT_DIR" ]; then
        log_error "Project directory not found: $PROJECT_DIR"
        exit 1
    fi
    
    # Check if whisper framework exists
    if [ ! -d "$WHISPER_FRAMEWORK_SOURCE" ]; then
        log_error "Whisper framework not found: $WHISPER_FRAMEWORK_SOURCE"
        log_error "Please build whisper.cpp first or check the path."
        exit 1
    fi
    
    log_success "All requirements met"
}

setup_whisper_framework() {
    log_info "Setting up whisper.cpp framework..."
    
    cd "$PROJECT_DIR"
    
    # Copy whisper framework to expected location
    if [ -d "build-apple" ]; then
        log_warning "build-apple directory already exists, removing it..."
        rm -rf build-apple
    fi
    
    log_info "Copying whisper framework from $WHISPER_FRAMEWORK_SOURCE"
    cp -r "$WHISPER_FRAMEWORK_SOURCE" .
    
    # Verify the framework was copied correctly
    if [ ! -d "build-apple/whisper.xcframework" ]; then
        log_error "Failed to copy whisper framework correctly"
        exit 1
    fi
    
    log_success "Whisper framework setup complete"
}

clean_build() {
    log_info "Cleaning previous builds..."
    
    cd "$PROJECT_DIR"
    
    # Clean Xcode derived data for this project
    DERIVED_DATA_DIR="$HOME/Library/Developer/Xcode/DerivedData"
    if [ -d "$DERIVED_DATA_DIR" ]; then
        find "$DERIVED_DATA_DIR" -name "VoiceInk-*" -type d -exec rm -rf {} + 2>/dev/null || true
        log_success "Cleaned derived data"
    fi
    
    # Remove dist directory if it exists
    if [ -d "dist" ]; then
        rm -rf dist
        log_info "Removed existing dist directory"
    fi
    
    # Remove existing DMG if it exists
    if [ -f "${DMG_NAME}.dmg" ]; then
        rm -f "${DMG_NAME}.dmg"
        log_info "Removed existing DMG file"
    fi
}

build_project() {
    log_info "Building VoiceInk project..."
    
    cd "$PROJECT_DIR"
    
    # Resolve package dependencies first
    log_info "Resolving package dependencies..."
    xcodebuild -project VoiceInk.xcodeproj -resolvePackageDependencies
    
    # Build the project without code signing
    log_info "Building $BUILD_CONFIGURATION configuration..."
    
    xcodebuild \
        -project VoiceInk.xcodeproj \
        -scheme VoiceInk \
        -configuration "$BUILD_CONFIGURATION" \
        -allowProvisioningUpdates \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGN_ENTITLEMENTS="" \
        DEVELOPMENT_TEAM="" \
        clean build
    
    # Check if build was successful
    BUILD_PRODUCTS_DIR="$HOME/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/$BUILD_CONFIGURATION"
    APP_PATH=$(find $BUILD_PRODUCTS_DIR -name "VoiceInk.app" -type d 2>/dev/null | head -n 1)
    
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
        log_error "Build failed - VoiceInk.app not found"
        exit 1
    fi
    
    log_success "Build completed successfully"
    log_info "Built app location: $APP_PATH"
}

create_distribution() {
    log_info "Creating distribution package..."
    
    cd "$PROJECT_DIR"
    
    # Create dist directory
    mkdir -p dist
    
    # Find the built app
    BUILD_PRODUCTS_DIR="$HOME/Library/Developer/Xcode/DerivedData/VoiceInk-*/Build/Products/$BUILD_CONFIGURATION"
    APP_PATH=$(find $BUILD_PRODUCTS_DIR -name "VoiceInk.app" -type d 2>/dev/null | head -n 1)
    
    if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
        log_error "Cannot find built VoiceInk.app"
        exit 1
    fi
    
    # Copy app to dist directory
    log_info "Copying app to distribution directory..."
    cp -R "$APP_PATH" dist/
    
    # Verify the copy was successful
    if [ ! -d "dist/VoiceInk.app" ]; then
        log_error "Failed to copy app to dist directory"
        exit 1
    fi
    
    # Get app size
    APP_SIZE=$(du -sh dist/VoiceInk.app | cut -f1)
    log_success "App copied to dist/ (Size: $APP_SIZE)"
}

create_dmg() {
    log_info "Creating DMG package..."
    
    cd "$PROJECT_DIR"
    
    # Create DMG using hdiutil
    log_info "Generating DMG file: ${DMG_NAME}.dmg"
    
    hdiutil create \
        -volname "$DMG_NAME" \
        -srcfolder dist \
        -ov \
        -format UDZO \
        "${DMG_NAME}.dmg"
    
    # Verify DMG was created
    if [ ! -f "${DMG_NAME}.dmg" ]; then
        log_error "Failed to create DMG file"
        exit 1
    fi
    
    # Get DMG size
    DMG_SIZE=$(du -sh "${DMG_NAME}.dmg" | cut -f1)
    log_success "DMG created successfully (Size: $DMG_SIZE)"
}

verify_build() {
    log_info "Verifying build results..."
    
    cd "$PROJECT_DIR"
    
    # Check if app exists and is executable
    if [ -d "dist/VoiceInk.app" ] && [ -x "dist/VoiceInk.app/Contents/MacOS/VoiceInk" ]; then
        log_success "✓ VoiceInk.app is present and executable"
    else
        log_error "✗ VoiceInk.app is not executable"
        return 1
    fi
    
    # Check if DMG exists
    if [ -f "${DMG_NAME}.dmg" ]; then
        log_success "✓ DMG package created successfully"
    else
        log_error "✗ DMG package not found"
        return 1
    fi
    
    # Test DMG can be mounted
    log_info "Testing DMG mount..."
    MOUNT_POINT="/tmp/voiceink_test_mount"
    mkdir -p "$MOUNT_POINT"
    
    if hdiutil attach "${DMG_NAME}.dmg" -mountpoint "$MOUNT_POINT" -nobrowse -quiet; then
        if [ -d "$MOUNT_POINT/VoiceInk.app" ]; then
            log_success "✓ DMG mounts correctly and contains VoiceInk.app"
        else
            log_error "✗ DMG does not contain VoiceInk.app"
        fi
        hdiutil detach "$MOUNT_POINT" -quiet
    else
        log_error "✗ Failed to mount DMG"
        return 1
    fi
    
    rm -rf "$MOUNT_POINT"
    
    log_success "All verification checks passed!"
}

print_summary() {
    log_info "Build Summary"
    echo "=============================================="
    echo "Project Directory: $PROJECT_DIR"
    echo "Build Configuration: $BUILD_CONFIGURATION"
    echo "Output Files:"
    echo "  • VoiceInk.app: $PROJECT_DIR/dist/VoiceInk.app"
    echo "  • DMG Package: $PROJECT_DIR/${DMG_NAME}.dmg"
    echo ""
    echo "Modifications Applied:"
    echo "  • License checking disabled in PolarService.swift"
    echo "  • All users appear as Pro users in LicenseViewModel.swift"
    echo "  • Code signing disabled for distribution"
    echo ""
    echo "Installation:"
    echo "  • Mount the DMG file and drag VoiceInk.app to Applications"
    echo "  • Or run directly from: $PROJECT_DIR/dist/VoiceInk.app"
    echo "=============================================="
}

# Main execution
main() {
    echo "VoiceInk Pro Unlocked Build Script"
    echo "=================================="
    echo ""
    
    check_requirements
    setup_whisper_framework
    clean_build
    build_project
    create_distribution
    create_dmg
    verify_build
    
    echo ""
    log_success "Build process completed successfully!"
    echo ""
    print_summary
}

# Run main function
main "$@"