---
description: "Build debug APK using Docker with optional clean build"
argument-hint: "[clean] [rebuild-image]"
allowed-tools: ["Bash"]
---

Build Android APK using Docker:

! $ARGUMENTS ./docker/build-apk.sh debug

Options:
- Add 'clean' for: CLEAN=1 ./docker/build-apk.sh debug
- Add 'rebuild-image' for: REBUILD_IMAGE=1 ./docker/build-apk.sh debug
- Add both for full clean: CLEAN=1 REBUILD_IMAGE=1 ./docker/build-apk.sh debug
