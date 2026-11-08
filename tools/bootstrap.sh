#!/usr/bin/env bash
# Checks the machine has what inferencebar needs, and reports what is
# missing rather than installing it.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ok=0
check() {
    local label="$1" cmd="$2" hint="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '  %-14s %s\n' "$label" "$("$cmd" --version 2>&1 | head -1)"
    else
        printf '  %-14s missing — %s\n' "$label" "$hint"
        ok=1
    fi
}

say "Toolchain"
check swift swift "install Xcode 16 or a compatible Swift 6 toolchain"
check python3 python3 "used by upload-release-assets.sh (JSON in, JSON out)"
say ""

say "At least one inference runtime (only needed to run the app, not to build it)"
check llama-server llama-server "brew install llama.cpp"
check mlx_lm.server mlx_lm.server "brew install mlx-lm"
say ""

say "Shell"
printf '  %-14s %s\n' "bash" "${BASH_VERSION:-unknown}"
case "${BASH_VERSION:-}" in
  3.*)
    dim "         macOS bash 3.2 - the version everything here is written for" ;;
  4.*|5.*)
    dim "         newer than macOS ships; 3.2 is the floor these target" ;;
esac
say ""

say "Architecture"
arch="$(uname -m)"
printf '  host           %s\n' "$arch"
if [[ "$arch" != "arm64" ]]; then
    printf '  %-14s inferencebar is Apple Silicon only; this host cannot build or run it\n' "warning"
    ok=1
fi
say ""

say "Next"
dim "  tools/check.sh              pre-push checks (layout, privacy, build)"
dim "  bash tools/checks/run.sh    every suite this machine can run"
exit $ok
