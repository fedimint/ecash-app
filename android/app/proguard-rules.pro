# Proguard rules for F-Droid compatibility
# 
# IMPORTANT: Do NOT add -keep rules for io.flutter.** classes.
# This allows R8 to tree-shake unused Flutter embedding classes
# that reference Google Play Core (PlayStoreDeferredComponentManager,
# FlutterPlayStoreSplitApplication), which are not needed for this app.
#
# See: https://gitlab.com/fdroid/fdroiddata/-/issues/2949

# Suppress warnings about Play Core classes (they will be stripped by R8)
-dontwarn com.google.android.play.core.**