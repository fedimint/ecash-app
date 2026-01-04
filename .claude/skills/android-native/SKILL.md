---
name: "android-native"
description: "Guide Claude on Android manifest configuration, permissions, deep linking intent filters (lightning://, lnurl://), platform channels, foreground services, NDK version management, and build settings"
allowed-tools: ["Read", "Grep"]
---

# Android Native Integration

This skill guides Android-specific integration patterns for the Ecash App.

## Build Configuration

### NDK Version Management

**Important:** There is a version mismatch to be aware of:

- **Target NDK** (android/app/build.gradle.kts): `27.3.13750724`
- **Nix NDK** (flake.nix): `27.0.12077973`

**Location:** `android/app/build.gradle.kts`
```kotlin
android {
    ndkVersion = "27.3.13750724"

    defaultConfig {
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }
}
```

**Key Points:**
- ABI filter is set to `arm64-v8a` **only**
- No support for x86, x86_64, or armeabi-v7a
- Keeps APK size smaller, targets modern devices

### Gradle Build Configuration

**File:** `android/app/build.gradle.kts`

**Key Settings:**
```kotlin
android {
    namespace = "org.fedimint.app.master"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }
}
```

**Signing Configuration:**
```kotlin
signingConfigs {
    create("release") {
        storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
        storePassword = keystoreProperties["storePassword"] as String?
        keyAlias = keystoreProperties["keyAlias"] as String?
        keyPassword = keystoreProperties["keyPassword"] as String?
        storeType = "pkcs12"
    }
}
```

Signing details stored in `key.properties` (not checked into git).

## Android Manifest Configuration

**File:** `android/app/src/main/AndroidManifest.xml`

### Deep Linking Intent Filters

For handling Bitcoin Lightning invoices and LNURL:

```xml
<activity
    android:name=".MainActivity"
    android:exported="true">

    <!-- Standard launcher intent -->
    <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter>

    <!-- Lightning invoice deep linking -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <category android:name="android.intent.category.BROWSABLE"/>
        <data android:scheme="lightning"/>
    </intent-filter>

    <!-- LNURL deep linking -->
    <intent-filter>
        <action android:name="android.intent.action.VIEW"/>
        <category android:name="android.intent.category.DEFAULT"/>
        <category android:name="android.intent.category.BROWSABLE"/>
        <data android:scheme="lnurl"/>
    </intent-filter>
</activity>
```

**Supported Schemes:**
- `lightning://` - Lightning invoices (BOLT11)
- `lnurl://` - Lightning URLs

### Permissions

**Required Permissions:**
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"/>
```

**Permission Purposes:**
- `INTERNET` - Network access for Fedimint, Lightning, Nostr
- `FOREGROUND_SERVICE` - Keep app alive for NWC connections
- `POST_NOTIFICATIONS` - Show payment notifications
- `WAKE_LOCK` - Keep device awake during operations
- `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` - Prevent system from killing NWC service

### Foreground Service Declaration

For Nostr Wallet Connect (NWC) reliability:

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="dataSync"
    android:exported="false"/>
```

**Service Type:** `dataSync` - Indicates service is syncing data (NWC events)

## Platform Channels

### Flutter-Android Communication

**Flutter Side (lib/):**
```dart
import 'package:flutter/services.dart';

class NativeChannel {
    static const platform = MethodChannel('org.fedimint.app/native');

    Future<String?> getInitialIntent() async {
        try {
            final String? result = await platform.invokeMethod('getInitialIntent');
            return result;
        } catch (e) {
            print('Error getting initial intent: $e');
            return null;
        }
    }
}
```

**Android Side (android/app/src/main/kotlin/):**
```kotlin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "org.fedimint.app/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialIntent" -> {
                    val intentData = intent?.data?.toString()
                    result.success(intentData)
                }
                else -> result.notImplemented()
            }
        }
    }
}
```

### Intent Handling Pattern

**For deep links (lightning://, lnurl://):**

1. Android receives intent with URI
2. MainActivity extracts URI from intent
3. Flutter requests URI via platform channel
4. Flutter parses URI and routes to appropriate screen

**Example Flow:**
1. User clicks `lightning:lnbc...` link
2. Android opens Ecash App with intent
3. Flutter calls `getInitialIntent()`
4. Receives `lightning:lnbc...`
5. Routes to send payment screen

## Foreground Service Integration

### flutter_foreground_task Package

**Purpose:** Keep app alive for NWC connections

**Configuration (lib/):**
```dart
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'nwc_service',
        channelName: 'NWC Service',
        channelDescription: 'Keeps Nostr Wallet Connect active',
        channelImportance: NotificationChannelImportance.LOW,
    ),
);
```

**Starting Service:**
```dart
FlutterForegroundTask.startService(
    notificationTitle: 'NWC Active',
    notificationText: 'Connected to Nostr Wallet Connect',
    callback: foregroundTaskCallback,
);
```

**Callback Function:**
```dart
@pragma('vm:entry-point')
void foregroundTaskCallback() {
    FlutterForegroundTask.setTaskHandler(NWCTaskHandler());
}

class NWCTaskHandler extends TaskHandler {
    @override
    Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
        // Initialize NWC listener
    }

    @override
    Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
        // Called periodically (e.g., every 5 seconds)
        // Check NWC connection status
    }

    @override
    Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
        // Cleanup
    }
}
```

**Key Points:**
- Runs in separate Isolate (different from main app)
- Must use platform channels to communicate with Rust
- Cannot directly call Rust FFI from foreground task isolate
- Needs proper lifecycle management (start/stop)

## Build Variants and Flavors

**Current Setup:** Single flavor (production)

**Build Types:**
- `debug` - Development builds with debugging enabled
- `release` - Production builds with optimizations

**Build Commands:**
- Debug APK: `just build-debug-apk` or `./docker/build-apk.sh debug`
- Clean build: `CLEAN=1 ./docker/build-apk.sh debug`
- Rebuild image: `REBUILD_IMAGE=1 ./docker/build-apk.sh debug`

## Common Android Patterns for Ecash App

### Pattern 1: Deep Link Handling

**When:** User clicks lightning:// or lnurl:// link

**Steps:**
1. Check if app launched from deep link
2. Extract URI from intent
3. Parse URI type (invoice, LNURL, etc.)
4. Route to appropriate payment screen
5. Pre-fill payment details

### Pattern 2: Foreground Service for NWC

**When:** User enables NWC connection

**Steps:**
1. Request battery optimization exemption
2. Start foreground service
3. Show persistent notification
4. Initialize NWC listener in service
5. Keep service alive until user disconnects

### Pattern 3: Permission Handling

**When:** App needs runtime permissions

**Steps:**
1. Check permission status
2. Show rationale if needed
3. Request permission
4. Handle grant/deny
5. Update UI accordingly

## Troubleshooting

### Issue: Deep Links Not Working

**Check:**
- Intent filter in AndroidManifest.xml
- Exported attribute set to `true`
- Correct scheme (lightning, lnurl)
- Platform channel implementation

### Issue: Foreground Service Killed by System

**Check:**
- Battery optimization exemption requested
- Service type set correctly (`dataSync`)
- Wake lock acquired if needed
- Notification channel created

### Issue: NDK Version Mismatch

**Check:**
- android/app/build.gradle.kts (target NDK)
- flake.nix (Nix NDK)
- Docker build NDK version
- Ensure consistency or document differences

### Issue: ABI Compatibility

**Check:**
- Only arm64-v8a is supported
- Device architecture matches
- No x86/x86_64 builds attempted

## Best Practices

1. **Intent Handling:**
   - Always validate intent data
   - Handle null/invalid URIs gracefully
   - Don't trust external input

2. **Permissions:**
   - Request only when needed
   - Explain why permission is needed
   - Degrade gracefully if denied

3. **Foreground Services:**
   - Show clear notification
   - Allow user to stop service
   - Clean up resources on destroy

4. **Build Configuration:**
   - Keep NDK versions documented
   - Use Docker for reproducible builds
   - Test on real devices, not just emulators

5. **Platform Channels:**
   - Use clear method names
   - Handle errors on both sides
   - Document channel contract

## File Locations

- **Manifest:** `android/app/src/main/AndroidManifest.xml`
- **Build Config:** `android/app/build.gradle.kts`
- **Settings:** `android/settings.gradle.kts`
- **MainActivity:** `android/app/src/main/kotlin/org/fedimint/app/master/MainActivity.kt`
- **Signing:** `android/key.properties` (not in git)

## Resources

- [Android Intent Filters](https://developer.android.com/guide/components/intents-filters)
- [Foreground Services](https://developer.android.com/guide/components/foreground-services)
- [Platform Channels](https://flutter.dev/docs/development/platform-integration/platform-channels)
- [NDK Documentation](https://developer.android.com/ndk)
