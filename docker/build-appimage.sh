#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGE_NAME="ecash-app-builder"

# Show build configuration
echo "Build configuration:"
if [[ "${REBUILD_IMAGE:-}" == "1" ]]; then
    echo "  - REBUILD_IMAGE=1: Rebuilding Docker image"
fi
if [[ "${CLEAN:-}" == "1" ]]; then
    echo "  - CLEAN=1: Wiping cargo cache"
    rm -rf "$PROJECT_ROOT/.docker-cache/cargo"
else
    echo "  - Using incremental cargo cache (set CLEAN=1 to wipe)"
fi
echo ""

# Build Docker image if needed
if ! docker image inspect $IMAGE_NAME &> /dev/null || [[ "${REBUILD_IMAGE:-}" == "1" ]]; then
    echo "Building Docker image..."
    docker build --build-arg FLUTTER_VERSION=$(cat "$PROJECT_ROOT/.flutter-version") -t $IMAGE_NAME "$SCRIPT_DIR"
fi

# Create cache directories (owned by current user)
mkdir -p "$PROJECT_ROOT/.docker-cache/cargo"

# Backup host's .dart_tool to avoid path conflicts
if [[ -d "$PROJECT_ROOT/.dart_tool" ]]; then
    mv "$PROJECT_ROOT/.dart_tool" "$PROJECT_ROOT/.dart_tool.host"
fi

# Run AppImage build in container
docker run --rm \
    --user "$(id -u):$(id -g)" \
    -v "$PROJECT_ROOT:/workspace" \
    -v "$PROJECT_ROOT/.docker-cache/cargo:/cargo-cache" \
    -w /workspace \
    -e CARGO_HOME="/cargo-cache" \
    -e HOME="/workspace" \
    $IMAGE_NAME \
    bash -c '
        rm -rf build/linux AppDir *.AppImage
        cargo build --release --manifest-path rust/ecashapp/Cargo.toml --target-dir rust/ecashapp/target
        flutter pub get
        flutter build linux --release
        cp rust/ecashapp/target/release/libecashapp.so build/linux/x64/release/bundle/lib/
        mkdir -p AppDir/usr/share/icons/hicolor/512x512/apps
        mkdir -p AppDir/usr/share/metainfo
        cp -r build/linux/x64/release/bundle/* AppDir/
        cp linux/runner/ecash-app.png AppDir/usr/share/icons/hicolor/512x512/apps/
        cp linux/runner/ecash-app.png AppDir/ecash-app.png
        cp linux/runner/ecash-app.desktop AppDir/
        cp linux/appstream/ecash-app.appdata.xml AppDir/usr/share/metainfo/
        ln -sf ecashapp AppDir/AppRun
        VERSION=$(grep "^version:" pubspec.yaml | cut -d" " -f2)
        ARCH=x86_64 appimagetool AppDir "ecash-app-${VERSION}-x86_64.AppImage"
    '

# Restore host's .dart_tool
rm -rf "$PROJECT_ROOT/.dart_tool"
if [[ -d "$PROJECT_ROOT/.dart_tool.host" ]]; then
    mv "$PROJECT_ROOT/.dart_tool.host" "$PROJECT_ROOT/.dart_tool"
fi

echo "Built: $(ls *.AppImage)"
