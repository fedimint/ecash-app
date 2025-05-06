# Carbine - A Fedimint Wallet

Carbine is a Fedimint wallet built using Flutter, Rust, and the Flutter Rust Bridge.

## Getting set up
Carbine uses nix and nix flakes to manage dependencies and build the project.

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
```

This will also build the rust library and place it in the appropriate location on Linux machines.

To run the app on Linux, simply run
```bash
just run
```

Done! This will launch Carbine on Linux. Android is currently not supported yet.
