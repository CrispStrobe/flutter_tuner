plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.flutter_tuner"
    compileSdk = 36  // Changed from 34 to 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        applicationId = "com.example.flutter_tuner"
        minSdk = flutter.minSdkVersion
        targetSdk = 36  // Also update targetSdk to 36
        versionCode = 2
        versionName = "2.0.0"
    }

    buildTypes {
        release {
            // Use debug keys for now (easy testing)
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {}
