# Versioning

## Source of truth

`pubspec.yaml`'s `version:` field is the single source of truth. Flutter splits it on the `+`:

- Left of `+` → Android `versionName` (the human-readable string shown in Settings → Apps).
- Right of `+` → Android `versionCode` (the integer Android uses internally for upgrade ordering).

The Gradle build pulls both via `flutter.versionName` / `flutter.versionCode` in `android/app/build.gradle`. Do not set version numbers anywhere else.

Form: `MAJOR.MINOR.PATCH+BUILD` — semantic version followed by a build number.

## When to bump each part

- **MAJOR** — A genuinely breaking change. For a personal sideload this is likely never. Stays at `1`.
- **MINOR** — A new user-visible feature lands. Examples that *would have* been minor bumps: QuickNote v1, Glance, Navigate.
- **PATCH** — A bug fix or behavioural correction. Examples that *would have* been patch bumps: the BLE reconnect-pacing fix, the 0x18 ghost-screen fix.
- **BUILD (`+N`)** — Increments on **every APK built and installed**, regardless of what semver changed. Monotonic — never reused, never decremented. Lets you tell two `1.0.1` APKs apart later.

## Rules

1. Bump *with* the change, in the same commit as the code. Do not batch version bumps separately.
2. The build number always moves forward, even if the semver part stays the same (e.g. two builds of `1.0.1` go `1.0.1+5` → `1.0.1+6`).
3. When semver moves forward, the build number still moves forward — never reset it to `+1`.
4. The currently-installed APK on the device is `1.0.0+1`. The next code change bumps to at least `+2`.

## Examples

| Change | Bump |
|---|---|
| Fix a typo in a log line | none (no APK ship) |
| Fix a bug, build, install | `1.0.0+1` → `1.0.1+2` |
| Add a feature | `1.0.1+2` → `1.1.0+3` |
| Two fixes in a row | `1.1.0+3` → `1.1.1+4` → `1.1.2+5` |
| Rebuild same code (no semver change) | `1.1.2+5` → `1.1.2+6` |
