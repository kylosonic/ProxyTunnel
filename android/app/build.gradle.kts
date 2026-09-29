// ---------------------------------------------------------------------------
//  Application module.
// ---------------------------------------------------------------------------

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "io.github.kylosonic.proxytunnel"
    compileSdk = 35

    defaultConfig {
        applicationId = "io.github.kylosonic.proxytunnel"
        // 29 because the bundled hev-socks5-tunnel AAR declares minSdk 29. The
        // manifest merger rejects anything lower, and the native library is only
        // built for API 29+.
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            // Debug builds are signed with the throwaway debug key, which is all
            // Android needs to sideload a VpnService app. There is no equivalent of
            // Apple's entitlement system here.
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // Deliberately not configured with a release signing config: this
            // project produces an unsigned-in-the-Apple-sense APK that you sign
            // with your own key, and no key material belongs in the repository.
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += setOf(
                "/META-INF/{AL2.0,LGPL2.1}",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE*"
            )
        }
    }

    // JVM unit tests. These cover everything that does not need Android: the
    // validators, the share-link round trip, the SOCKS5/HTTP codecs, the generated
    // tunnel config, and a real proxied round trip against a local SOCKS5 server.
    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

dependencies {
    // The tunnel engine. Pinned to a release whose AAR, SHA-256 and JNI contract
    // were all verified before this file was written:
    //   hev/htproxy/TProxyService with
    //     TProxyStartService(String, int): Boolean
    //     TProxyStopService(): Boolean
    //     TProxyIsRunning(): Boolean
    //     TProxyGetStats(): LongArray
    // The AAR carries arm64-v8a, armeabi-v7a, x86_64 and x86.
    //
    // The file is fetched by scripts/fetch-native-libs.sh so that no binary is
    // committed, and so the checksum is checked on every build.
    implementation(files("libs/hev-socks5-tunnel.aar"))

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")

    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}
