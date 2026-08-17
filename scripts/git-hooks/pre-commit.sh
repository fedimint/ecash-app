#!/usr/bin/env bash

set -eo pipefail

# Pass the directory, not a glob. `**` only works with `shopt -s globstar`,
# which bash 3.2 — what macOS ships — does not have, so `lib/**/*.dart`
# degraded to `lib/*/*.dart` and skipped all 50 top-level files (app.dart,
# scan.dart, utils.dart, nwc.dart …) plus anything nested three deep. This is
# also exactly what CI runs.
dart format -o none --set-exit-if-changed lib/ > /dev/null \
  || {
       echo >&2 "
✖  Dart files aren’t formatted!
Please run:

    dart format lib/

and then try committing again.
";
       exit 1;
     }

