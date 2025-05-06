#!/bin/bash

flutter_rust_bridge_codegen generate --rust-input=crate --rust-root=./ --dart-output=../../lib/
#cargo build --release
