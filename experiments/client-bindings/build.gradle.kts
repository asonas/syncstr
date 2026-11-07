plugins {
    kotlin("jvm") version "2.2.21"
    application
}
repositories { mavenCentral() }
dependencies {
    implementation("net.java.dev.jna:jna:5.17.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11) } }
sourceSets.main { kotlin.srcDirs("generated/kotlin", "kotlin") }
application {
    mainClass.set("ProbeKt")
    applicationDefaultJvmArgs = listOf("-Djna.library.path=${projectDir.resolve("target/debug")}")
}
