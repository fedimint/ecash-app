# Security Policy

## Reporting a Vulnerability

Do **not** open a public GitHub issue for security bugs.

Send a report to **jumoell@protonmail.com** or message **`m1sterc001guy.97`** on
Signal.

Please include:

- What the bug is and where it is in the code.
- How to reproduce it, if possible.
- What an attacker can do with it (steal funds, drain a wallet, leak the seed
  phrase or user data, deanonymize a user, brick the app, etc.).
- Your name or handle, if you want credit in the fix announcement.

## Encrypted Reports

For sensitive reports, Signal is preferred. If you would rather use email,
encrypt it with PGP.

| Maintainer | Email | Key fingerprint |
| --- | --- | --- |
| m1sterc001guy | `jumoell@protonmail.com` | `C2FF 1CEB C073 29B9 5B51 CDE2 1D11 F134 0E22 A5D1` |

The key is hosted on the Proton Mail key server. To fetch it:

```sh
gpg --fetch-keys 'https://api.protonmail.ch/pks/lookup?op=get&search=jumoell@protonmail.com'
```

Check the fingerprint against the table above before you use the key.

Please keep the bug private until a fix is released and users have had time to
upgrade.

## Supported Versions

We only fix security bugs in the latest release. Older releases do not get
patches. Run a current release.

## Scope

In scope:

- All code in this repository: the Flutter UI (`lib/`), the Rust wallet core
  (`rust/`), and the Android, Linux, and macOS platform code.
- Fund safety, seed phrase and key handling, backup and recovery, transaction
  privacy, and anything that lets a third party spend or observe a user's
  funds without consent.
- The interfaces the app exposes to the outside world: Lightning Address,
  Nostr Wallet Connect (NWC), Nostr relay handling, QR/invoice and invite code
  parsing, and deep links or intents handled by the app.

Out of scope:

- Bugs in third-party software we depend on, including Fedimint itself
  (report them upstream, but tell us too if this app is affected). Fedimint
  vulnerabilities go to security@fedimint.org.
- Attacks that need a majority of a federation's guardians to be malicious.
  The Fedimint threat model assumes fewer than one third of guardians are
  faulty.
- Attacks that need physical access to an already unlocked device, or a
  rooted/jailbroken device compromised by other means.
- Malicious federations or gateways doing what they are trusted to do
  (e.g. a federation the user chose to join refusing to honor ecash).
