#!/usr/bin/env bash
# Does inferencebar compile.
#
#   bash tests/build.sh          swift build (debug) + swift test
#   bash tests/build.sh --build  build only, no tests
#
# Exits 78 (EX_CONFIG) when there is no Swift toolchain here, so run.sh
# counts that as skipped rather than failed — this machine cannot be wrong
# about a thing it never checked.
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$TOOLS_DIR/lib/swift-log.sh"

BUILD_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --build) BUILD_ONLY=1; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

if ! command -v swift >/dev/null 2>&1; then
  warn "no Swift toolchain here; install Xcode 16+ or a compatible Swift 6 toolchain"
  exit 78
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  warn "inferencebar is Apple Silicon only; this host is $(uname -m) and cannot build it"
  exit 78
fi

log="/tmp/it-build-$$.log"
if (cd "$APP" && make macos-build) >"$log" 2>&1; then
  ok "swift build succeeds"
else
  swift_failure "$log"
  exit 1
fi

if [ "$BUILD_ONLY" = "1" ]; then
  exit 0
fi

log="/tmp/it-test-$$.log"
if (cd "$APP" && make macos-test) >"$log" 2>&1; then
  ok "$(test_count "$log")"
else
  swift_failure "$log"
  exit 1
fi
