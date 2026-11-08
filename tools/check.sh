#!/usr/bin/env bash
# Is this working copy safe to push?
#
#   tools/check.sh              layout + privacy, then a build
#   tools/check.sh --no-build   layout + privacy only (nothing compiled)
#
# Run it before `git push`. It never touches git itself.
#
# The two fast suites (no toolchain needed) check that nothing generated
# would be committed and that nothing private is in the tree. The build is
# fatal when a Swift toolchain is present: a check that notices a broken
# build and carries on is worse than none, because it reads like assurance.
# With no toolchain it is only a note -- not every machine that pushes here
# has Xcode.
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$TOOLS_DIR/lib/swift-log.sh"

BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0; shift ;;
    -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          die "Unknown option: $1" ;;
  esac
done

say ""
say "InferenceBar pre-push checks"
dim "  $APP"

bash "$TOOLS_DIR/checks/run.sh" --fast || die "The fast checks do not pass; fix those before pushing."

if [ "$BUILD" = "1" ]; then
  head1 "build"
  if command -v swift >/dev/null 2>&1 && [ "$(uname -m)" = "arm64" ]; then
    log="$(mktemp "${TMPDIR:-/tmp}/ib-check-build.XXXXXX")"
    if (cd "$APP" && make macos-build) >"$log" 2>&1; then
      ok "swift build succeeds"
      rm -f "$log"
    else
      swift_failure "$log"
      die "Pushing anyway would put a known-broken commit on the remote."
    fi
  else
    warn "no Apple Silicon Swift toolchain here, so nothing was compiled"
  fi
fi

say ""
ok "checks passed"
