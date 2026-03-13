# Proguard rules for F-Droid compatibility
#
# We selectively keep Flutter plugin/util/view classes (needed for platform
# channels and networking) but do NOT keep io.flutter.app.** — this allows R8
# to strip PlayStoreDeferredComponentManager, FlutterPlayStoreSplitApplication,
# and other Google Play Core embedding classes.
#
# See: https://gitlab.com/fdroid/fdroiddata/-/issues/2949

# Suppress warnings about Play Core classes (they will be stripped by R8)
-dontwarn com.google.android.play.core.**

# Keep Flutter plugin classes (needed for platform channels, including networking)
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }

# Keep OkHttp (Android's HTTP stack, used via reflection)
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-dontwarn okhttp3.**
-dontwarn okio.**

# Keep SSL/TLS classes needed for HTTPS connections
-keep class javax.net.ssl.** { *; }
-dontwarn javax.net.ssl.**

# Keep Cronet if used by Flutter
-keep class org.chromium.net.** { *; }
-dontwarn org.chromium.net.**
