#!/usr/bin/env bash
set -e

# Release script for Ecash App
# Calculates versionCode, updates pubspec.yaml and Cargo.toml, commits, and tags.
#
# Usage:
#   ./scripts/release.sh <version>
#
# Examples:
#   ./scripts/release.sh 0.5.0        # → version: 0.5.0+50090, tag v0.5.0
#   ./scripts/release.sh 0.5.0-rc.1   # → version: 0.5.0-rc.1+50001, tag v0.5.0-rc.1
#
# Version code formula (matches CI in .github/actions/android-build/action.yml):
#   BASE_CODE = MAJOR * 1000000 + MINOR * 10000 + PATCH * 100
#   RC releases: BASE_CODE + RC_NUM
#   Final releases: BASE_CODE + 90

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="$1"

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo ""
    echo "Examples:"
    echo "  $0 0.5.0        # Final release"
    echo "  $0 0.5.0-rc.1   # Release candidate"
    exit 1
fi

# Extract base version (strip -rc.N, -alpha, etc.)
BASE_VERSION=$(echo "$VERSION" | sed 's/-rc\..*//' | sed 's/-alpha.*//')
MAJOR=$(echo "$BASE_VERSION" | cut -d. -f1)
MINOR=$(echo "$BASE_VERSION" | cut -d. -f2)
PATCH=$(echo "$BASE_VERSION" | cut -d. -f3)

if [[ -z "$MAJOR" || -z "$MINOR" || -z "$PATCH" ]]; then
    echo "Error: Invalid version format '$VERSION'. Expected X.Y.Z or X.Y.Z-rc.N"
    exit 1
fi

# Calculate version code
BASE_CODE=$((MAJOR * 1000000 + MINOR * 10000 + PATCH * 100))

if [[ "$VERSION" == *"-rc."* ]]; then
    RC_NUM=$(echo "$VERSION" | sed 's/.*-rc\.//')
    VERSION_CODE=$((BASE_CODE + RC_NUM))
else
    # Final release gets +90 to be above all RCs (room for 89 RCs)
    VERSION_CODE=$((BASE_CODE + 90))
fi

TAG="v$VERSION"

echo "Release: $VERSION"
echo "Version code: $VERSION_CODE"
echo "Tag: $TAG"
echo ""

# Check for uncommitted changes
if ! git -C "$PROJECT_ROOT" diff --quiet || ! git -C "$PROJECT_ROOT" diff --cached --quiet; then
    echo "Error: You have uncommitted changes. Please commit or stash them first."
    exit 1
fi

# Check if tag already exists
if git -C "$PROJECT_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Error: Tag '$TAG' already exists."
    exit 1
fi

# Update pubspec.yaml
sed -i "s/^version: .*/version: $VERSION+$VERSION_CODE/" "$PROJECT_ROOT/pubspec.yaml"
echo "Updated pubspec.yaml → version: $VERSION+$VERSION_CODE"

# Update Cargo.toml (without versionCode)
sed -i "s/^version = \".*\"/version = \"$VERSION\"/" "$PROJECT_ROOT/rust/ecashapp/Cargo.toml"
echo "Updated Cargo.toml → version: $VERSION"

# Add appstream release entry
APPSTREAM_FILE="$PROJECT_ROOT/linux/appstream/org.fedimint.app.appdata.xml"
RELEASE_DATE=$(date +%Y-%m-%d)
RELEASE_ENTRY="    <release version=\"$VERSION\" date=\"$RELEASE_DATE\" />"
sed -i "s|  <releases>|  <releases>\n$RELEASE_ENTRY|" "$APPSTREAM_FILE"
echo "Updated appstream → release $VERSION ($RELEASE_DATE)"

# Commit and tag
git -C "$PROJECT_ROOT" add pubspec.yaml rust/ecashapp/Cargo.toml "$APPSTREAM_FILE"
git -C "$PROJECT_ROOT" commit -m "chore: bump version to $TAG"
git -C "$PROJECT_ROOT" tag "$TAG"

echo ""
echo "Done! Created commit and tag '$TAG'."
echo ""
echo "To push:"
echo "  git push origin master && git push origin $TAG"
