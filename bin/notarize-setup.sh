#!/usr/bin/env bash
#
# One-time notarization setup for this Mac. `make notarize-help` explains
# what `xcrun notarytool store-credentials` needs: a profile name, the
# Apple ID, the team ID, and an app-specific password. The team ID is
# already sitting in whatever "Developer ID Application" certificate is in
# this Mac's keychain (the same one CODESIGN_IDENTITY in the Makefile
# auto-detects), and the Apple ID is usually the one this Mac is signed
# into -- so this script fills both in and asks to confirm them, leaving
# only the one thing nothing here can know: the app-specific password.
# `notarytool` prompts for that itself, masked -- it is never typed as an
# argument, seen by this script, or written anywhere.
#
#   bin/notarize-setup.sh                 profile name defaults to "inferencebar"
#   bin/notarize-setup.sh my-profile-name
#
# An app-specific password is not your Apple ID password. Generate one at
# appleid.apple.com, under Sign-In and Security > App-Specific Passwords
# (this needs two-factor authentication already turned on for the Apple ID).
set -uo pipefail

case "${1:-}" in
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

PROFILE="${1:-inferencebar}"

command -v security >/dev/null 2>&1 || { echo "error: 'security' not found -- this only runs on macOS." >&2; exit 1; }
command -v xcrun     >/dev/null 2>&1 || { echo "error: 'xcrun' not found -- install Xcode or the Command Line Tools." >&2; exit 1; }

# --- Team ID, from an installed Developer ID Application certificate -------
#
# Same identity, same extraction, as the Makefile's own DETECTED_IDENTITY --
# this asks the keychain the same question CODESIGN_IDENTITY already does,
# not a second thing that could disagree with it.
ALL_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
IDENTITY_LINE="$(printf '%s\n' "$ALL_IDENTITIES" | grep -m1 'Developer ID Application' || true)"
if [ -z "$IDENTITY_LINE" ]; then
  echo "error: no 'Developer ID Application' certificate found in this Mac's keychain." >&2
  OTHER="$(printf '%s\n' "$ALL_IDENTITIES" | grep -oE '"[^"]+"' || true)"
  if [ -n "$OTHER" ]; then
    echo "" >&2
    echo "       Found instead:" >&2
    printf '%s\n' "$OTHER" | sed 's/^/         /' >&2
    echo "" >&2
    if printf '%s\n' "$OTHER" | grep -qi 'Apple Development'; then
      echo "       'Apple Development' certificates are for building and running on" >&2
      echo "       your own Mac from Xcode -- they don't work for this. Notarization" >&2
      echo "       needs 'Developer ID Application' specifically: a separate" >&2
      echo "       certificate type, and it requires an active (paid) Apple Developer" >&2
      echo "       Program membership -- 'Apple Development' certificates don't." >&2
    else
      echo "       None of those are a 'Developer ID Application' certificate either." >&2
    fi
  fi
  echo "" >&2
  echo "       To get one: Xcode > Settings > Accounts, select your team, click" >&2
  echo "       'Manage Certificates...', then '+' > 'Developer ID Application'." >&2
  echo "       If Xcode doesn't offer that option, the account isn't enrolled in" >&2
  echo "       the paid Developer Program yet (or enrollment hasn't finished" >&2
  echo "       propagating -- that can take a while after enrolling or renewing)." >&2
  exit 1
fi

IDENTITY_NAME="$(printf '%s' "$IDENTITY_LINE" | sed -E 's/.*"(.*)".*/\1/')"
TEAM_ID="$(printf '%s' "$IDENTITY_NAME" | sed -nE 's/.*\(([A-Z0-9]+)\)[[:space:]]*$/\1/p')"

if [ -z "$TEAM_ID" ]; then
  echo "error: found identity '$IDENTITY_NAME' but couldn't read a team ID out of it" >&2
  echo "       (expected one in parentheses at the end, e.g. \"...(ABCDE12345)\")." >&2
  exit 1
fi

echo "identity   $IDENTITY_NAME"
echo "team id    $TEAM_ID"

# --- Apple ID, from the account this Mac is signed into, if any ------------
#
# Best-effort: this reads the Apple ID a signed-in Mac keeps locally, which
# is usually -- not always -- the same one the Developer Program membership
# is under. Always shown and confirmable, never assumed silently.
APPLE_ID=""
if command -v defaults >/dev/null 2>&1; then
  APPLE_ID="$(defaults read MobileMeAccounts Accounts 2>/dev/null \
    | sed -nE 's/.*AccountID = "?([^";]+)"?;?/\1/p' \
    | head -1 || true)"
fi

if [ -n "$APPLE_ID" ]; then
  read -rp "apple id   $APPLE_ID -- press enter to use this, or type a different one: " OVERRIDE
  [ -n "$OVERRIDE" ] && APPLE_ID="$OVERRIDE"
else
  read -rp "apple id   (could not auto-detect; type it): " APPLE_ID
fi

[ -n "$APPLE_ID" ] || { echo "error: an Apple ID is required." >&2; exit 1; }

echo ""
echo "Storing a notarization keychain profile named '$PROFILE' for $APPLE_ID / $TEAM_ID."
echo "notarytool will now ask for the one thing that can't be found automatically:"
echo "an app-specific password from appleid.apple.com (Sign-In and Security >"
echo "App-Specific Passwords) -- not your Apple ID password."
echo ""

if xcrun notarytool store-credentials "$PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID"; then
  echo ""
  echo "Done. Build with:"
  echo "  NOTARY_PROFILE=$PROFILE make macos-package"
  echo "or export NOTARY_PROFILE=$PROFILE once per shell so every build picks it up."
else
  echo "error: storing credentials failed; see notarytool's message above." >&2
  exit 1
fi
