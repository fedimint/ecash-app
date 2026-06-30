//! Android-only JNI bootstrap.
//!
//! Since the hickory-resolver 0.26 / netdev 0.44 upgrade (pulled in transitively
//! by `iroh`, fedimint's guardian transport), the crates that read the device's
//! network configuration do so through the Android framework. They reach the
//! `JavaVM` and the `Context` via the `ndk_context` crate's global
//! `AndroidContext` — e.g. `hickory-resolver`'s `system_conf/android.rs` calls
//! `ndk_context::android_context()` to read DNS servers from `ConnectivityManager`.
//! Older hickory (0.25.2) used `resolv-conf` instead and never touched this.
//!
//! On a normal `ndk-glue` app `ndk_context` is initialized before `main`, but
//! here Flutter owns the activity and loads our `.so` with `dlopen` from Dart —
//! which never runs `JNI_OnLoad` — so nobody initializes it. The first DNS lookup
//! then panics with "android context was not initialized", which surfaces on the
//! Dart side as `PanicException` (e.g. when fetching a federation's metadata).
//!
//! Fix: `MainActivity` calls `System.loadLibrary("ecashapp")`, which DOES run
//! `JNI_OnLoad` below. We grab the `JavaVM`, look up the process-wide
//! `Application` via `ActivityThread.currentApplication()` (so we need no help
//! from Kotlin and stay independent of the dev/prod application id), and hand
//! both to `ndk_context`. This module is compiled only on Android; desktop reads
//! `/etc/resolv.conf` and never touches `ndk_context`.

use std::ffi::c_void;

use jni::sys::{jint, JNI_VERSION_1_6};
use jni::JavaVM;

/// Invoked by the JVM when `System.loadLibrary("ecashapp")` loads this library.
#[no_mangle]
pub extern "system" fn JNI_OnLoad(vm: JavaVM, _reserved: *mut c_void) -> jint {
    if let Err(e) = init_android_context(&vm) {
        // The Flutter event bus isn't wired up this early, so this only reaches
        // logcat — but a failure here means networking will panic later anyway.
        eprintln!("ecashapp: failed to initialize Android context for native networking: {e:?}");
    }
    JNI_VERSION_1_6
}

fn init_android_context(vm: &JavaVM) -> anyhow::Result<()> {
    // `JNI_OnLoad` runs on a thread that is already attached to the JVM.
    let mut env = vm.get_env()?;

    // android.app.ActivityThread.currentApplication() -> Application (a Context).
    let activity_thread = env.find_class("android/app/ActivityThread")?;
    let application = env
        .call_static_method(
            activity_thread,
            "currentApplication",
            "()Landroid/app/Application;",
            &[],
        )?
        .l()?;

    if application.is_null() {
        anyhow::bail!("ActivityThread.currentApplication() returned null");
    }

    // Promote to a global ref and leak it so the jobject stays valid for the
    // whole process lifetime — `ndk_context` only stores the raw pointer.
    let application = env.new_global_ref(&application)?;
    let context_ptr = application.as_obj().as_raw();
    std::mem::forget(application);

    // SAFETY: the pointers are valid, and `JNI_OnLoad` runs once per library
    // load so `initialize_android_context` (which asserts it is called once) is
    // not invoked twice.
    unsafe {
        ndk_context::initialize_android_context(
            vm.get_java_vm_pointer().cast::<c_void>(),
            context_ptr.cast::<c_void>(),
        );
    }

    Ok(())
}
