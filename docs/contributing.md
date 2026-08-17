# Contributing

## Linux Development
Ecash App uses nix and nix flakes to manage dependencies and build the project.

First, install nix

```bash
curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install
```

Then enter the nix developer environment.

```bash
nix develop
```

To generate the Flutter bindings for the rust code, simply run
```bash
just generate
just build-linux
```

To run the app on Linux, simply run
```bash
just run
```

Done! This will launch Ecash App on Linux.

## Testing

Both suites run on every pull request via `.github/workflows/test.yml` and
`.github/workflows/checks.yml`. Run them locally before opening one:

```bash
just test                          # Flutter/Dart tests in test/
cd rust/ecashapp && cargo test     # Rust tests, in #[cfg(test)] modules
```

The same workflows also gate `cargo fmt --check`, `cargo clippy -- -D warnings`,
`dart format --set-exit-if-changed lib/`, and `./scripts/check-translations.sh`.
Together these are much faster than a platform build, so prefer them for
verifying a change.

- [LNURLw testing guide](lnurlw-testing.md) — automated coverage plus manual end-to-end steps
- [QA checklist](qa-checklist.md) — manual pre-release test matrix