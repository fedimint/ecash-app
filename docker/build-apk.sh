#!/usr/bin/env bash
set -e

# This script builds the Docker image and then builds the APK or AAB
# Run from the project root: ./docker/build-apk.sh [debug|release] [--aab]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_MODE="${1:-debug}"
shift || true

# Parse flags
BUILD_FORMAT="apk"
for arg in "$@"; do
    case "$arg" in
        --aab) BUILD_FORMAT="aab" ;;
        *) echo "Unknown flag: $arg"; exit 1 ;;
    esac
done

if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
    echo "Error: Build mode must be 'debug' or 'release'"
    echo "Usage: $0 [debug|release] [--aab]"
    exit 1
fi

echo "==================================="
echo "Ecash App Docker Build"
echo "==================================="
echo "Project root: $PROJECT_ROOT"
echo "Build mode: $BUILD_MODE"
echo "Build format: $BUILD_FORMAT"
echo ""

# Show build configuration
echo "Build configuration:"
if [[ "${REBUILD_IMAGE}" == "1" ]]; then
    echo "  - REBUILD_IMAGE=1: Rebuilding Docker image"
else
    echo "  - Using existing Docker image (set REBUILD_IMAGE=1 to rebuild)"
fi

if [[ "${CLEAN}" == "1" ]]; then
    echo "  - CLEAN=1: Wiping all build caches (Rust, Flutter, Gradle)"
    rm -rf "$PROJECT_ROOT/.docker-cache/gradle"
    rm -rf "$PROJECT_ROOT/.docker-cache/cargo"
else
    echo "  - Using incremental build caches (set CLEAN=1 to wipe)"
fi
echo ""

# Create cache directories (owned by current user)
mkdir -p "$PROJECT_ROOT/.docker-cache/gradle"
mkdir -p "$PROJECT_ROOT/.docker-cache/cargo"
mkdir -p "$PROJECT_ROOT/.docker-cache/android"

# Build the Docker image if it doesn't exist or if forced
IMAGE_NAME="ecash-app-builder"

# The NDK toolchain installed in the image is linux-x86_64, so the container
# must always be linux/amd64. On amd64 hosts that's the natural default; on
# arm64 hosts (Apple Silicon, arm64 Linux) we force amd64 emulation via
# Rosetta/qemu. We only pass --platform when needed to avoid BuildKit's
# FromPlatformFlagConstDisallowed warning and any unnecessary platform
# mismatch noise on amd64 hosts.
PLATFORM_ARGS=()
if [[ "$(uname -m)" != "x86_64" ]]; then
    PLATFORM_ARGS=(--platform=linux/amd64)
    echo "Host arch $(uname -m) detected; forcing linux/amd64 emulation."
    echo ""
fi

if ! docker image inspect $IMAGE_NAME &> /dev/null || [[ "${REBUILD_IMAGE}" == "1" ]]; then
    echo "Building Docker image..."
    docker build "${PLATFORM_ARGS[@]}" --build-arg FLUTTER_VERSION=$(cat "$PROJECT_ROOT/.flutter-version") -t $IMAGE_NAME "$SCRIPT_DIR"
    echo ""
else
    echo "Using existing Docker image: $IMAGE_NAME"
    echo ""
fi

# Backup host's .dart_tool (docker will overwrite with container paths)
if [ -d "$PROJECT_ROOT/.dart_tool" ]; then
    mv "$PROJECT_ROOT/.dart_tool" "$PROJECT_ROOT/.dart_tool.host"
fi

echo "Starting build in Docker container..."
docker run --rm \
    "${PLATFORM_ARGS[@]}" \
    --user "$(id -u):$(id -g)" \
    -v "$PROJECT_ROOT:/workspace" \
    -v "$PROJECT_ROOT/.docker-cache/gradle:/gradle-cache" \
    -v "$PROJECT_ROOT/.docker-cache/cargo:/cargo-cache" \
    -v "$PROJECT_ROOT/.docker-cache/android:/android-home" \
    -w /workspace \
    -e CLEAN="${CLEAN}" \
    -e GRADLE_USER_HOME="/gradle-cache" \
    -e CARGO_HOME="/cargo-cache" \
    -e ANDROID_USER_HOME="/android-home" \
    -e HOME="/workspace" \
    -e FLUTTER_SUPPRESS_ANALYTICS=true \
    -e BUILD_FORMAT="$BUILD_FORMAT" \
    $IMAGE_NAME \
    bash /workspace/docker/entrypoint.sh "$BUILD_MODE"

# Restore host's .dart_tool
rm -rf "$PROJECT_ROOT/.dart_tool"
if [ -d "$PROJECT_ROOT/.dart_tool.host" ]; then
    mv "$PROJECT_ROOT/.dart_tool.host" "$PROJECT_ROOT/.dart_tool"
fi

# Remove .dart-tool telemetry directory created by unified_analytics
rm -rf "$PROJECT_ROOT/.dart-tool"

