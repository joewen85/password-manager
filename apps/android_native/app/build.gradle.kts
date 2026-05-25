plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val releaseStoreFilePath = providers.gradleProperty("PASSWORD_MANAGER_RELEASE_STORE_FILE")
    .orNull
    ?.takeIf { it.isNotBlank() }
val releaseStorePassword = providers.gradleProperty("PASSWORD_MANAGER_RELEASE_STORE_PASSWORD")
    .orNull
    ?.takeIf { it.isNotBlank() }
val releaseKeyAlias = providers.gradleProperty("PASSWORD_MANAGER_RELEASE_KEY_ALIAS")
    .orNull
    ?.takeIf { it.isNotBlank() }
val releaseKeyPassword = providers.gradleProperty("PASSWORD_MANAGER_RELEASE_KEY_PASSWORD")
    .orNull
    ?.takeIf { it.isNotBlank() }
val hasReleaseSigningConfig = listOf(
    releaseStoreFilePath,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it != null }

android {
    namespace = "com.example.passwordmanagernative"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.passwordmanagernative"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    signingConfigs {
        if (hasReleaseSigningConfig) {
            create("release") {
                storeFile = rootProject.file(releaseStoreFilePath!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseSigningConfig) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_21)
    }
}

dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.window:window:1.4.0")
    testImplementation(kotlin("test"))
    testImplementation("org.json:json:20250517")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
