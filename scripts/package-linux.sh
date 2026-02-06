#!/bin/bash
set -e

# Clean previous build artifacts
rm -rf build/linux AppDir *.AppImage

# Build Rust library
cargo build --release --manifest-path rust/ecashapp/Cargo.toml --target-dir rust/ecashapp/target

# Build Flutter app
flutter pub get
flutter build linux --release

# Copy Rust library AFTER flutter build (flutter build wipes bundle/lib/)
cp rust/ecashapp/target/release/libecashapp.so build/linux/x64/release/bundle/lib/

# Create AppDir structure
mkdir -p AppDir/usr/share/icons/hicolor/512x512/apps
mkdir -p AppDir/usr/share/metainfo
mkdir -p AppDir/usr/share/applications

# Copy bundle and assets
cp -r build/linux/x64/release/bundle/* AppDir/
cp linux/runner/ecash-app.png AppDir/usr/share/icons/hicolor/512x512/apps/
cp linux/runner/ecash-app.png AppDir/ecash-app.png
cp linux/runner/org.fedimint.app.desktop AppDir/
cp linux/runner/org.fedimint.app.desktop AppDir/usr/share/applications/
cp linux/appstream/org.fedimint.app.appdata.xml AppDir/usr/share/metainfo/
ln -sf ecashapp AppDir/AppRun

# Package AppImage
VERSION=$(grep "^version:" pubspec.yaml | cut -d" " -f2)
ARCH=x86_64 appimagetool AppDir "ecash-app-${VERSION}-x86_64.AppImage"
