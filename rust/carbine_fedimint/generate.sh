#!/bin/bash

flutter_rust_bridge_codegen generate --rust-input=crate::src --rust-root=./ --dart-output=../../lib/
