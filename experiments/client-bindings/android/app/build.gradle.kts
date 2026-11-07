plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "as.ason.syncstr.bindingprobe"
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    defaultConfig {
        applicationId = "as.ason.syncstr.bindingprobe"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
        testInstrumentationRunner = "as.ason.syncstr.bindingprobe.BindingTest"
    }
    sourceSets["main"].java.srcDir("../../generated/android")
    sourceSets["main"].jniLibs.srcDir("../../build/android-jni")
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    packaging { jniLibs.useLegacyPackaging = false }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11) } }

dependencies {
    implementation("androidx.annotation:annotation:1.9.1")
    implementation("net.java.dev.jna:jna:5.17.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
}
