#!/bin/bash

cargo build
flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=./ --dart-output=../../lib/
