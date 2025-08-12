import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

// Load key.properties if it exists
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()

if (keystorePropertiesFile.exists()) {
    println("✅ key.properties FOUND at: ${keystorePropertiesFile.absolutePath}")
    keystoreProperties.load(keystorePropertiesFile.inputStream())

    val storeFilePath = keystoreProperties["storeFile"]?.toString()
    println("storeFile (from key.properties): $storeFilePath")

    // Check if storeFile exists relative to app/ directory
    if (storeFilePath != null) {
        val resolvedFile = file(storeFilePath)
        if (resolvedFile.exists()) {
            println("✅ Keystore FOUND at: ${resolvedFile.absolutePath}")
        } else {
            println("❌ Keystore NOT FOUND at: ${resolvedFile.absolutePath}")
        }
    } else {
        println("❌ storeFile is missing from key.properties")
    }
} else {
    println("❌ key.properties NOT found at: ${keystorePropertiesFile.absolutePath}")
}

android {
    namespace = "app.ecash"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "app.ecash"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeType = "pkcs12"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

