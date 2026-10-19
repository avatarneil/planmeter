plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        // The app runs this code on Android; keep the bytecode Android can desugar.
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.add("-Xjdk-release=17")
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    api(libs.kotlinx.serialization.json)
    testImplementation(libs.junit)
}

tasks.test {
    // Shared golden fixtures (protocol/fixtures at the repository root) and an
    // optional live Swift server for interop runs (see android/interop).
    systemProperty("planmeter.fixtures", rootProject.layout.projectDirectory.dir("../protocol/fixtures").asFile.absolutePath)
    providers.environmentVariable("PLANMETER_INTEROP_PAIR_URL").orNull?.let { systemProperty("planmeter.interop.pairUrl", it) }
    testLogging {
        events("failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
