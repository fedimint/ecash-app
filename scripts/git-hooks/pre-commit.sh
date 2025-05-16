#!/usr/bin/env bash

set -eo pipefail

dart format -o none --set-exit-if-changed lib/*.dart > /dev/null \
  || {
       echo >&2 "
✖  Dart files aren’t formatted!
Please run:

    dart format lib/*.dart

and then try committing again.
";
       exit 1;
     }

