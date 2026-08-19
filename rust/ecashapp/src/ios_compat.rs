//! iOS-only link-time compatibility shims.
//!
//! `netdev` 0.45.0 (pulled in transitively by `iroh`, fedimint's guardian
//! transport, via `netwatch`) unconditionally calls
//! `nw_path_is_ultra_constrained` when it snapshots a network path — see
//! `netdev-0.45.0/src/os/ios/network.rs:206`. Apple declares that function
//! `API_AVAILABLE(macos(26.0), ios(26.0), ...)`, so it exists in the iOS 26 SDK
//! we compile against but is absent from every earlier OS. Nothing in Rust's
//! `extern "C"` declaration carries availability information, so the link
//! succeeds and dyld then refuses to load the app at launch:
//!
//! ```text
//! dyld: Symbol not found: _nw_path_is_ultra_constrained
//!   Referenced from: .../Runner.app/Runner.debug.dylib
//!   Expected in:     /System/Library/Frameworks/Network.framework/Network
//! ```
//!
//! That makes the app unlaunchable on anything below iOS 26 regardless of
//! `IPHONEOS_DEPLOYMENT_TARGET`. netdev removed the call entirely in 0.46.1,
//! but `netwatch` 0.19.1 — the newest release — pins `netdev ^0.45.0`, so no
//! version combination in our tree avoids it.
//!
//! Defining the symbol here resolves netdev's reference against this archive
//! instead of against Network.framework, so no import of it is recorded and
//! dyld has nothing to fail on. Returning `false` matches the behavior of
//! netdev 0.46, which dropped the notion of an "ultra constrained" path.
//!
//! Because Mach-O uses a two-level namespace, this only affects our own
//! binary's references — system frameworks calling the real API still bind to
//! Network.framework.
//!
//! Delete this once `netwatch` releases against `netdev` 0.46.

use std::os::raw::c_void;

/// See the module docs. Signature matches Apple's
/// `bool nw_path_is_ultra_constrained(nw_path_t path)`.
#[unsafe(no_mangle)]
pub extern "C" fn nw_path_is_ultra_constrained(_path: *const c_void) -> bool {
    false
}
