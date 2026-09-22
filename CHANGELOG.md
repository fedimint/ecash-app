# Changelog

## [0.11.0]

- iOS support - Ecash App now runs on iPhone, distributed through TestFlight
- Upgraded to fedimint v0.12
- lnurlw:// links now open directly in the app on Android and iOS
- Nostr Wallet Connect is hidden on iOS, where no background listener can keep a pairing alive
- Wallet data and logs are excluded from Android cloud backup and device-to-device transfer
- Recovery progress is now reported correctly for federations with newer modules
- Fixed a panic during recovery
- Leaving a federation now shuts down its background tasks, including the NWC listener
- LNURL server error responses are now detected instead of relying on the HTTP status alone
- Faster startup and lower memory use with a long transaction history - the event log is no longer read in full
- On-chain fee calculation is now overflow-safe
- BTC Map now credits OpenStreetMap and the other map providers

## [0.10.0]

- Guardian dashboard - federation health, audit, backup, and Lightning Gateway membership
- Federation meta module support
- Max button when sending over Lightning and LNURL
- Nostr Wallet Connect hardening - client authorization gate, daily budget, and max invoice cap
- PIN hardening - PIN is now salted and key-derived, attempts are throttled, and the PIN is required to view your mnemonic
- Confirmation prompt before contacting an LNURL-withdraw server
- Validation of scanned QR code input
- Transaction id and fee shown for pending on-chain receives
- Balance is shown when leaving a federation
- Recovery now tells you when no backup was found on Nostr
- Invoice expiration picker
- Thousands separator for fiat amounts
- Timeouts on network calls
- Ecash from a Mint V2 federation you have not joined now offers to join and redeem

## [0.9.0]

- Wallet V2 Module Support
- Mint V2 Module Support
- LNURL-Withdraw Support
- NFC support for reading Lightning invoices
- Full fee estimation and accounting
- BTCMap added as a feature - find spots to spend Bitcoin!
- Fedimint Observer has been added as another source for public federations
- More control over Lightning invoice creation
- macOS support
- More user-friendly error messages
- Federation picker when making a Lightning payment
- Gateway picker when creating a Lightning invoice

## [0.7.0]

- Dashboard UI overhaul
- Adds My Wallet screen
- Recovery UI overhaul
- Lightning Addresses are now recovered from seed
