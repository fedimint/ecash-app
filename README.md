# e-cash app - A Fedimint Wallet

e-cash app is a Fedimint wallet built using Flutter, Rust, and the Flutter Rust Bridge.

## Linux Development
e-cash app uses nix and nix flakes to manage dependencies and build the project.

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

Done! This will launch e-cash app on Linux.
