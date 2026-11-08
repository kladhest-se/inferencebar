#!/usr/bin/env bash
# Run every suite that can run here, and say plainly which were skipped.
#
#   bash tools/checks/run.sh          everything that can run
#   bash tools/checks/run.sh --fast   only the suites that need no toolchain
#   bash tools/checks/run.sh --list
#
# Exit code is non-zero if any suite that ran reported a failure. A skip is
# not a failure, but it is always named and explained — a suite that
# quietly does not run is worse than one that fails, because it reads as a
# pass.
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

TESTS_DIR="$TOOLS_DIR/checks"

SUITES=(
  "layout:the repository has the files it should, and nothing loose"
  "privacy:no credential, signing identity, private host or home path in the tree"
  "build:inferencebar compiles and its tests pass"
)
FAST_SUITES=(layout privacy)

FAST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fast) FAST=1; shift ;;
    --list)
      for entry in "${SUITES[@]}"; do
        printf '  %-14s %s\n' "${entry%%:*}" "${entry#*:}"
      done
      exit 0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

ran=0
failed=0
skipped=0

# Notes are newline-delimited strings, not arrays: macOS ships bash 3.2,
# where an *empty* array expanded under `set -u` is an unbound-variable
# error rather than nothing. This runner is the one thing that must never
# fall over.
skip_notes=""
fail_notes=""

for entry in "${SUITES[@]}"; do
  suite="${entry%%:*}"
  blurb="${entry#*:}"

  if [ "$FAST" = "1" ]; then
    case " ${FAST_SUITES[*]} " in *" $suite "*) ;; *) continue ;; esac
  fi

  script="$TESTS_DIR/$suite.sh"
  # A suite that is simply missing is a failure, not a skip: a check that
  # quietly does not run reads as a pass. (It used to be skipped when its exec
  # bit was lost -- zip extraction does that -- so `check.sh` reported "checks
  # passed" having run nothing.) Run through bash, so the bit does not matter.
  if [ ! -f "$script" ]; then
    failed=$((failed + 1))
    fail_notes="$fail_notes$suite: $script is missing"$'\n'
    continue
  fi

  head1 "$suite — $blurb"
  bash "$script"
  status=$?

  case "$status" in
    0)
      ran=$((ran + 1))
      ;;
    78)
      # EX_CONFIG. The suite decided it could not run and said why on its
      # own output; it is not a failure and must not be counted as one.
      skipped=$((skipped + 1))
      skip_notes="$skip_notes$suite: nothing installed to run it"$'\n'
      ;;
    *)
      ran=$((ran + 1))
      failed=$((failed + 1))
      fail_notes="$fail_notes$suite: $status failure(s)"$'\n'
      ;;
  esac
done

head1 "Summary"
say "  ran      $ran"
say "  failed   $failed"
say "  skipped  $skipped"

[ -n "$skip_notes" ] && printf '%s' "$skip_notes" | while IFS= read -r note; do
  [ -n "$note" ] && dim "    skipped  $note"
done
[ -n "$fail_notes" ] && printf '%s' "$fail_notes" | while IFS= read -r note; do
  [ -n "$note" ] && fail "$note"
done

if [ "$failed" -eq 0 ] && [ "$skipped" -gt 0 ]; then
  say ""
  dim "  Skips are not passes. On an Apple Silicon Mac with Xcode the whole set"
  dim "  runs; tools/bootstrap.sh says what is missing here."
fi

[ "$failed" -eq 0 ]
