# Setup — Linux (Pop!_OS / Ubuntu) Development Environment

> **Document type:** Dev environment brief
> **Audience:** Eddie + AI agents working on this repo from a Linux box
> **Status:** Live — update as the toolchain shifts

This file documents what needs to be in place on a Linux dev box to build, run,
test, and analyse the Even G1 Companion app. It is the canonical reference for
fresh-machine onboarding (or "why does this not build" debugging).

The repo's primary target is **Android on Samsung Galaxy S24 Ultra**. iOS,
macOS, Linux desktop and Windows desktop Flutter targets exist in the tree
but are not actively built or tested.

---

## Version matrix (cross-referenced from project files)

| Component               | Required version                | Source of truth                          |
|-------------------------|---------------------------------|------------------------------------------|
| Flutter SDK             | stable channel, ≥ 3.24          | `pubspec.yaml` (Dart `^3.5.3`)           |
| Dart SDK                | bundled with Flutter            | `pubspec.yaml`                           |
| JDK                     | 17 (Temurin or OpenJDK)         | Gradle 8.7 + AGP 8.6.1 compatibility     |
| Android Gradle Plugin   | 8.6.1                           | `android/settings.gradle`                |
| Kotlin                  | 2.1.10                          | `android/settings.gradle`                |
| Gradle                  | 8.7 (via wrapper, no install)   | `android/gradle/wrapper/gradle-wrapper.properties` |
| Android `compileSdk`    | Flutter default (currently 35)  | `android/app/build.gradle`               |
| Android `minSdk`        | 21                              | `pubspec.yaml` (flutter_launcher_icons)  |
| Android `targetSdk`     | Flutter default (currently 35)  | `android/app/build.gradle`               |
| Android NDK             | Flutter default (currently 27.x)| `android/app/build.gradle`               |
| CMake                   | 3.22.1                          | `android/app/build.gradle` (pinned)      |
| ABI filters             | `armeabi-v7a`, `arm64-v8a`      | `android/app/build.gradle`               |

The Flutter SDK ships its own pinned values for `compileSdkVersion`,
`targetSdkVersion`, `ndkVersion`, and `versionCode` — the gradle files reference
them as `flutter.compileSdkVersion` etc. Upgrading Flutter is the way to bump
those; do not hand-edit the gradle files.

---

## Install steps

### 1. JDK 17

```bash
sudo apt update
sudo apt install -y openjdk-17-jdk
java -version   # expect: openjdk version "17.x.x"
```

Set `JAVA_HOME` in `~/.bashrc`:

```bash
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH="$JAVA_HOME/bin:$PATH"
```

### 2. Flutter SDK

Install via the official tarball (avoid `snap` — its sandboxing breaks
`adb` device detection and writes to a non-standard prefix):

```bash
mkdir -p ~/dev
cd ~/dev
# Replace VERSION with the current stable from https://docs.flutter.dev/release/archive
curl -O https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_<VERSION>-stable.tar.xz
tar xf flutter_linux_<VERSION>-stable.tar.xz
```

Add to `~/.bashrc`:

```bash
export PATH="$HOME/dev/flutter/bin:$PATH"
```

Verify:

```bash
flutter --version
dart --version    # bundled with Flutter
```

### 3. Android SDK command-line tools

Flutter does not bundle the Android SDK. Install command-line tools manually:

```bash
mkdir -p ~/Android/Sdk/cmdline-tools
cd ~/Android/Sdk/cmdline-tools
# Latest URL: https://developer.android.com/studio#command-line-tools-only
curl -O https://dl.google.com/android/repository/commandlinetools-linux-<BUILD>_latest.zip
unzip commandlinetools-linux-<BUILD>_latest.zip
mv cmdline-tools latest    # final layout: ~/Android/Sdk/cmdline-tools/latest/
```

Add to `~/.bashrc`:

```bash
export ANDROID_HOME="$HOME/Android/Sdk"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$PATH"
```

Install platform components:

```bash
yes | sdkmanager --licenses
sdkmanager "platform-tools" \
           "platforms;android-35" \
           "build-tools;35.0.0" \
           "ndk;27.0.12077973" \
           "cmake;3.22.1"
```

> Adjust `android-35`, `27.0.12077973`, `3.22.1` to match what `flutter doctor`
> later asks for if Flutter has moved on. The Flutter SDK is the source of
> truth for the NDK and `compileSdk` defaults.

### 4. `flutter doctor` and Android licences

```bash
flutter doctor
flutter doctor --android-licenses    # accept everything
```

Target state: green ticks for **Flutter**, **Android toolchain**, and (when a
device is plugged in) **Connected device**. The iOS, macOS desktop, Chrome
and Linux desktop checks can stay red — none of those targets are built here.

### 5. Project bootstrap

Inside the repo:

```bash
cd ~/projects/EvenDemoApp
flutter pub get
```

Create `android/local.properties` pointing at the Linux paths (the existing
file on this box was carried over from Windows and still says `C:\Android`):

```properties
sdk.dir=/home/eddie/Android/Sdk
flutter.sdk=/home/eddie/dev/flutter
flutter.buildMode=release
flutter.versionName=1.2.1
flutter.versionCode=11
```

`android/local.properties` is git-ignored — each machine maintains its own.

The `gradlew` wrapper script must be executable; `core.filemode=false` in this
clone hides that, so set it explicitly the first time:

```bash
chmod +x android/gradlew
```

### 6. Device permissions for `adb`

Pop!_OS / Ubuntu hides USB devices behind udev rules. Without the rule, `adb
devices` shows `???????????? no permissions`:

```bash
sudo apt install -y android-sdk-platform-tools-common   # ships the udev rules
sudo udevadm control --reload-rules
# Replug the phone; on-device popup will ask to trust this host's RSA key.
adb devices    # expect: <serial>  device
```

---

## API keys and runtime configuration

Several services read keys at compile time via `String.fromEnvironment`:

| Env name              | Used in                                              | Notes                                   |
|-----------------------|------------------------------------------------------|-----------------------------------------|
| `OPENAI_API_KEY`      | `lib/services/assistant_backend_config.dart`         | Quick Ask / Chat fallback key           |
| `OPENAI_API_BASE_URL` | `lib/services/assistant_backend_config.dart`         | Optional override (defaults to OpenAI)  |
| `DASHSCOPE_API_KEY`   | `lib/services/api_services{,_deepseek}.dart`         | Aliyun fallback path (legacy)           |

Pass them at build time:

```bash
flutter run --dart-define=OPENAI_API_KEY=sk-... --dart-define=OPENAI_API_BASE_URL=https://...
```

Runtime settings UI also accepts an API key; that overrides the compile-time
fallback. Day-to-day development can rely on the in-app settings without
rebuilding.

> **Security note:** `lib/services/api_services{,_deepseek}.dart` carry
> hard-coded DASHSCOPE keys as `defaultValue` in `String.fromEnvironment`. These
> are committed to the repo. Treat as already-leaked and rotate before any
> public push.

---

## Build, run, test

| Goal                    | Command                                                       |
|-------------------------|---------------------------------------------------------------|
| Static analysis         | `flutter analyze`                                             |
| Unit tests              | `flutter test`                                                |
| Run debug on device     | `flutter run`                                                 |
| Hot-restart only        | press `R` in the `flutter run` console                        |
| Build release APK       | `flutter build apk --release`                                 |
| Build split APKs        | `flutter build apk --release --split-per-abi`                 |
| Logs from device        | `adb logcat \| grep -E 'com.eddie.evencompanion\|flutter'`    |

The first `flutter run` after a clean checkout will fetch Gradle 8.7, the AGP
8.6.1 plugin, all Kotlin/Android dependencies, and trigger CMake to build the
bundled `liblc3` (LC3 audio codec) and `rnnoise` (RNN noise suppression) C
libraries from `android/app/src/main/cpp/`. Expect the first build to take
several minutes; subsequent incremental builds are fast.

---

## Cross-platform housekeeping

This repo is developed across Windows and Linux via Syncthing. To keep it
healthy:

- **Line endings:** `.gitattributes` declares `* text=auto eol=lf`. Index
  stores LF on every platform. Windows checkout (with `core.autocrlf=true`)
  sees CRLF on disk; Linux checkout sees LF. Do not commit `.bat` / `.cmd` /
  `.ps1` with LF endings — `.gitattributes` overrides to CRLF for those.
- **Worktrees:** Claude Code's worktree-isolation feature creates dirs under
  `.claude/worktrees/`. Those must never be staged — `.gitignore` covers
  `.claude/`, but check before `git add -A`.
- **`android/local.properties`:** machine-specific. Already git-ignored.
- **Git identity on this box:** `cheddies1 <iwantyourtshirt@gmail.com>`
  (set via `git config user.{name,email}`; check with `git config --get
  user.email`).

---

## Verification checklist

A fresh clone is ready to develop on this box when:

- [ ] `flutter doctor` shows green Flutter + green Android toolchain.
- [ ] `flutter analyze` reports zero issues in `lib/`.
- [ ] `flutter test` runs the test suite to completion.
- [ ] `adb devices` lists the Samsung S24 Ultra as `device` (not
      `unauthorized` and not `no permissions`).
- [ ] `flutter run` builds and installs the app on the phone.

---

## Reference layout (where things live)

```
~/dev/flutter/                      # Flutter SDK
~/Android/Sdk/                      # Android SDK
  cmdline-tools/latest/             # sdkmanager, avdmanager
  platform-tools/                   # adb, fastboot
  platforms/android-35/             # SDK platform
  build-tools/35.0.0/               # aapt, dx, etc.
  ndk/27.0.12077973/                # NDK for native builds
  cmake/3.22.1/                     # CMake bundled by NDK install
~/projects/EvenDemoApp/             # repo
  android/local.properties          # Linux SDK paths (machine-local)
  android/app/src/main/cpp/         # C/C++ sources (liblc3, rnnoise)
```

---

## Related docs

- `AGENTS.md` — app implementation context, protocol knowledge, key files
- `README.md` — product overview
- `docs/current-worklist.md` — active work and backlog
- `docs/current-architecture.md` — runtime architecture
- `docs/protocol-reference.md` — G1 BLE protocol notes
