// Galaxy Watch remote for Even Companion (docs/plans/watch-remote-spike.md).
// Standalone Gradle project; shares only the applicationId and signing key
// with the phone app, both of which the Wearable Data Layer requires to match.
// Toolchain versions follow android/ so the Gradle cache is shared.
plugins {
    id("com.android.application") version "8.6.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.10" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.1.10" apply false
}
