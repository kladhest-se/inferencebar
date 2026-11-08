# Reading a swift build or swift test log. Sourced, never executed.
#
# `tail -20` shows the summary, which names the failure and not its cause:
# the compiler's own lines are usually well above it.
swift_failure() {
  local log="$1" shown=0

  # Any line announcing an error, with or without a path. Warnings excluded
  # explicitly rather than by hoping the pattern misses them.
  local errors
  errors="$(grep -E '(^|: )(error|fatal error): ' "$log" 2>/dev/null \
            | grep -v ': warning: ' | head -12)"
  if [ -n "$errors" ]; then
    printf '%s\n' "$errors" | sed 's/^/        /'
    shown=1
  fi

  # Failing assertions, from swift-testing or XCTest.
  local failures
  failures="$(grep -E '✘|Test Case .* failed|XCTAssert.* failed' "$log" 2>/dev/null | head -8)"
  if [ -n "$failures" ]; then
    printf '%s\n' "$failures" | sed 's/^/        /'
    shown=1
  fi

  # Nothing recognisable. The tail is a guess, so say that it is one.
  if [ "$shown" = "0" ]; then
    printf '        no error line recognised; last 15 lines follow\n'
    tail -15 "$log" | sed 's/^/        /'
  fi

  # Always. Whatever the heuristics did, the whole log is what gets pasted
  # into a bug report.
  printf '        full log: %s\n' "$log"

  # `grep -c` prints its count *and* exits non-zero when the count is zero, so
  # `|| echo 0` appends a second zero and the result is the two-line string
  # "0\n0" — which `[ -gt ]` then rejects as not an integer. The count alone
  # is already what is wanted; the fallback was the bug.
  local warnings
  warnings="$(grep -c ': warning: ' "$log" 2>/dev/null | head -1)"
  case "$warnings" in
    ''|*[!0-9]*) warnings=0 ;;
  esac
  [ "$warnings" -gt 0 ] && printf '        (%s warning(s) not shown)\n' "$warnings"
  return 0
}

# A one-line summary for a passing test log, e.g. "42 tests passed". Falls
# back to "tests passed" with no number rather than guessing wrong — swift
# and XCTest have phrased this differently across versions, and a summary
# line that is silently absent is safer than one that is silently mismatched.
test_count() {
  local log="$1" n
  n="$(grep -oE '[0-9]+ tests? passed' "$log" 2>/dev/null | tail -1)"
  [ -n "$n" ] || n="$(grep -oE 'Executed [0-9]+ tests?' "$log" 2>/dev/null | tail -1)"
  printf '%s' "${n:-tests passed}"
}
