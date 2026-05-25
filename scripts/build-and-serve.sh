#!/usr/bin/env bash
#
# Build a release APK and serve it over HTTP for phone-side download via
# Tailscale. Phone must be joined to the same tailnet as this box.
#
# Usage:
#   scripts/build-and-serve.sh            # build then serve (default)
#   scripts/build-and-serve.sh build      # build only (cron-friendly)
#   scripts/build-and-serve.sh serve      # serve existing APK only
#
# Environment overrides:
#   PORT     listen port (default 8080)
#   JAVA_HOME / ANDROID_HOME / Flutter PATH are exported below so this works
#   from cron / fresh shells where ~/.bashrc has not been sourced.

set -euo pipefail

ACTION="${1:-all}"
# Default avoids 8080 (open_webui) and other common dev ports.
PORT="${PORT:-8421}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR="$REPO_ROOT/build/app/outputs/flutter-apk"
APK_FILE="$APK_DIR/app-release.apk"

export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"
export PATH="$HOME/dev/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$JAVA_HOME/bin:$PATH"

resolve_tailnet_target() {
  # Print one URL per line that the phone can hit. Prefers tailnet DNS name
  # over raw IP because Tailscale's MagicDNS makes the hostname stable.
  local host ip
  host="$(tailscale status --self --peers=false --json 2>/dev/null \
            | grep -oP '"DNSName"\s*:\s*"\K[^"]+' \
            | head -1 | sed 's/\.$//' || true)"
  ip="$(tailscale ip -4 2>/dev/null | head -1 || true)"

  if [[ -n "${host:-}" ]]; then
    echo "http://${host}:${PORT}/app-release.apk"
  fi
  if [[ -n "${ip:-}" ]]; then
    echo "http://${ip}:${PORT}/app-release.apk"
  fi
}

build_apk() {
  cd "$REPO_ROOT"
  echo "==> flutter build apk --release"
  flutter build apk --release

  if [[ ! -f "$APK_FILE" ]]; then
    echo "ERROR: expected APK at $APK_FILE — not found." >&2
    exit 1
  fi

  local size sha
  size="$(du -h "$APK_FILE" | cut -f1)"
  sha="$(sha256sum "$APK_FILE" | cut -d' ' -f1 | head -c 16)"
  echo
  echo "==> Built $APK_FILE ($size, sha256:${sha}…)"
}

serve_apk() {
  if [[ ! -f "$APK_FILE" ]]; then
    echo "ERROR: no APK at $APK_FILE — run '$0 build' first." >&2
    exit 1
  fi

  echo
  echo "==> Phone-side download URL(s) (open in Chrome on the phone):"
  resolve_tailnet_target | sed 's/^/    /'
  echo
  echo "==> Serving $APK_DIR on :$PORT (Ctrl+C to stop)"
  cd "$APK_DIR"
  exec python3 -m http.server "$PORT"
}

case "$ACTION" in
  build) build_apk ;;
  serve) serve_apk ;;
  all)   build_apk; serve_apk ;;
  *)
    echo "usage: $0 [all|build|serve]" >&2
    exit 2
    ;;
esac
