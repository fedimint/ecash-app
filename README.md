# Carbine - A Fedimint Wallet

Carbine is a Fedimint wallet built using Flutter, Rust, and the Flutter Rust Bridge.

There is currently no nix flake for installing dependencies, so setting up dependencies is currently a manual process.

Necessary dependencies
 - Flutter
 - Rust + Cargo
 - Flutter Rust Bridge

To build the rust code, navigate to `rust/carbine_fedimint` and run `./generate`. This script will parse the rust code and build the library so it is usable in Flutter.

Then to run the Flutter app, run `flutter run`.
