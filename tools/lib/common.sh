# Shared helpers. Sourced, never executed.
#
# Every script here needs the same two things: where the repository is, and
# how to say something to a terminal that may or may not be one. Two copies
# of that is how they drift.

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# tools/ lives inside the repository it checks, so the app root is its
# parent. (This used to be a sibling checkout; it no longer is.)
APP="$(cd "$TOOLS_DIR/.." && pwd)"

if [ -t 1 ]; then
  C_OK=$'\033[0;32m'; C_WARN=$'\033[0;33m'; C_ERR=$'\033[0;31m'
  C_DIM=$'\033[0;90m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_BOLD=""; C_OFF=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s  ok%s    %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s  note%s  %s\n' "$C_WARN" "$C_OFF" "$*"; }
fail() { printf '%s  fail%s  %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }
die()  { printf '%s  error%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; exit 1; }
dim()  { printf '%s%s%s\n'         "$C_DIM"  "$*"     "$C_OFF"; }
head1() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_OFF"; }
