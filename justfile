generate:
  flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=$ROOT/rust/ecashapp --dart-output=$ROOT/lib/
  # `freezed_annotation` requires this build step, which gives us rust-like pattern matching in dart's codegen
  flutter pub run build_runner build --delete-conflicting-outputs
  # Generate localization files from ARB sources
  flutter gen-l10n

build-android-x86_64:
  $ROOT/scripts/build-android.sh

build-android-arm:
  $ROOT/scripts/build-arm-android.sh

build-linux:
  $ROOT/scripts/build-linux.sh release-dev

build-debug-android *args:
  $ROOT/docker/build-apk.sh debug {{args}}

build-release-android *args:
  $ROOT/docker/build-apk.sh release {{args}}

build-appimage:
  $ROOT/docker/build-appimage.sh

run-appimage-nixos path:
  # This is needed in NixOS, if you are on another OS you can simply open the AppImage
  appimage-run {{path}}

build-macos:
  $ROOT/scripts/build-macos.sh

run-macos: build-macos
  $ROOT/scripts/run-macos.sh

run: build-linux
  flutter run

test:
  flutter test

# Check translations/i18n for issues (missing keys, placeholders, hardcoded strings)
lint-translations:
  $ROOT/scripts/check-translations.sh

# Regenerate localization files from ARB sources
gen-l10n:
  flutter gen-l10n

# Scan the latest APK for F-Droid compatibility (checks for Google Play Services dependencies)
scan-apk:
  #!/usr/bin/env bash
  set -euo pipefail
  APK=$(ls -t build/app/outputs/flutter-apk/ecashapp-*.apk 2>/dev/null | head -1)
  if [ -z "$APK" ]; then
    echo "No APK found. Run 'just build-debug-android' first."
    exit 1
  fi
  echo "Scanning: $APK"
  fdroid scanner -v --exit-code "$APK"
