#!/usr/bin/env bash
# This repository has the files it is supposed to have, and
# nothing loose at its root.
#
# Needs nothing installed.
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

REQUIRED=(
  "Package.swift" "Makefile" "README.md" "CHANGELOG.md"
  "LICENSE" "LICENSE.md" ".gitignore"
  "Sources/InferenceBar" "Tests/InferenceBarTests"
  "work/Info.plist"
  "public-web/index.php"
  "bin/notarize-setup.sh"
  "tools/README.md" "tools/upload-release-assets.sh" "tools/check.sh"
  "tools/release.env.example" "tools/checks/run.sh"
)

# Only these at the root, plus the directories checked separately below.
#
# This is a public repository. Root files accumulate — architecture notes,
# scratch scripts, half-finished docs — before anyone notices; keeping the
# root to what has to be there (Makefile for `make`, .gitignore for git,
# README.md for GitHub, CHANGELOG.md as the second thing anyone opens) is
# what this loop is for.
ROOT_FILES_ALLOWED=("Package.swift" "Makefile" "README.md" "CHANGELOG.md" "LICENSE" "LICENSE.md" ".gitignore")
ROOT_DIRS_ALLOWED=("Sources" "Tests" "Assets" "work" "public-web" "bin" "tools" ".git" ".github")
# .github stays on the allowed-but-not-required list rather than being
# dropped outright: CI/CD is coming back at a later stage (see
# inferencebar's CHANGELOG), and when it does, the directory reappearing
# shouldn't need a matching change here.

# Anything a build produces. If the repository can generate it, .gitignore
# must cover it.
GENERATED=(".build/" "outputs/" "work/clang-cache/" "work/swift-cache/" "work/package/" "work/dmg/" "work/release/")

# Machine-local files that must never be committed. privacy.sh checks the
# tracked tree for secrets; this checks the .gitignore that keeps the
# local-only files out of it in the first place.
LOCAL_ONLY=("tools/release.env" "*.p12" "*.pem" "*.key" "*.mobileprovision" ".env")

fails=0

for file in "${REQUIRED[@]}"; do
  if [ ! -e "$APP/$file" ]; then
    fail "missing $file"
    fails=$((fails + 1))
  fi
done

while IFS= read -r entry; do
  name="$(basename "$entry")"
  allowed=0
  for permitted in "${ROOT_FILES_ALLOWED[@]}"; do
    [ "$name" = "$permitted" ] && allowed=1
  done
  if [ "$allowed" = "0" ]; then
    fail "$name is at the repository root; move it into a subdirectory (scripts belong in tools/)"
    fails=$((fails + 1))
  fi
done < <(find "$APP" -maxdepth 1 -type f)

while IFS= read -r entry; do
  name="$(basename "$entry")"
  allowed=0
  for permitted in "${ROOT_DIRS_ALLOWED[@]}"; do
    [ "$name" = "$permitted" ] && allowed=1
  done
  if [ "$allowed" = "0" ]; then
    # A top-level entry in GENERATED (".build/", "outputs/") is an expected,
    # gitignored build artifact — it exists only because something actually
    # got built, which is the normal state of this repository, not clutter.
    # .gitignore coverage of it is asserted separately above. Nested entries
    # like "work/clang-cache/" don't need this: "work" is already allowed.
    for pattern in "${GENERATED[@]}"; do
      [ "$name" = "${pattern%/}" ] && allowed=1
    done
  fi
  if [ "$allowed" = "0" ]; then
    fail "$name/ is at the repository root and is not on the allowed list"
    fails=$((fails + 1))
  fi
done < <(find "$APP" -maxdepth 1 -type d -not -path "$APP")

if [ -f "$APP/.gitignore" ]; then
  for pattern in "${GENERATED[@]}"; do
    want="${pattern%/}"
    if ! grep -qxF "$want" "$APP/.gitignore" && ! grep -qxF "$want/" "$APP/.gitignore"; then
      fail ".gitignore does not cover $pattern"
      fails=$((fails + 1))
    fi
  done
fi

if [ -f "$APP/.gitignore" ]; then
  for pattern in "${LOCAL_ONLY[@]}"; do
    if ! grep -qxF "$pattern" "$APP/.gitignore"; then
      fail ".gitignore does not cover $pattern"
      fails=$((fails + 1))
    fi
  done
fi

[ "$fails" -eq 0 ] && ok "the root holds only Makefile, README, CHANGELOG, LICENSE(.md), .gitignore, and the expected directories"

# Every Makefile verb the README documents actually exists, and vice versa.
#
# A verb added to one and not the other is invisible until somebody runs
# `make help` and gets a target that does nothing, or reads the README and
# gets "No rule to make target".
VERBS=(macos-build macos-run macos-open macos-test macos-app macos-install
       macos-release macos-package macos-archive signing-identities check release-all)
for verb in "${VERBS[@]}"; do
  grep -qE "^${verb}:" "$APP/Makefile" || {
    fail "Makefile has no $verb target"
    fails=$((fails + 1))
  }
  grep -q "make $verb" "$APP/README.md" || {
    warn "README does not mention 'make $verb'"
  }
done
for target in all help clean; do
  grep -qE "^${target}:" "$APP/Makefile" || {
    fail "Makefile has no $target target"
    fails=$((fails + 1))
  }
done

# The package name matches its declared executable target, and the
# directory SwiftPM actually builds is the one the manifest points at —
# this project has been through one rename already (LlamaDock -> the
# InferenceBar product), and a manifest naming a moved directory fails
# to resolve with an error that names neither.
manifest="$APP/Package.swift"
if [ -f "$manifest" ]; then
  grep -q 'name: "InferenceBar"' "$manifest" || {
    fail "Package.swift does not declare the InferenceBar product"
    fails=$((fails + 1))
  }
  path_line="$(sed -n 's/.*path: "\(Sources\/[^"]*\)".*/\1/p' "$manifest" | head -1)"
  if [ -n "$path_line" ] && [ ! -d "$APP/$path_line" ]; then
    fail "Package.swift points at $path_line, which does not exist"
    fails=$((fails + 1))
  fi
fi

# The version Makefile reads from work/Info.plist has to be there, or
# every archive/release/package target fails before it starts.
if [ -f "$APP/work/Info.plist" ]; then
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/work/Info.plist" >/dev/null 2>&1 || {
      fail "work/Info.plist has no CFBundleShortVersionString"
      fails=$((fails + 1))
    }
  else
    # PlistBuddy is macOS-only; a plain string search is the portable
    # fallback so this suite still runs somewhere with no Mac at all.
    grep -q "CFBundleShortVersionString" "$APP/work/Info.plist" || {
      fail "work/Info.plist has no CFBundleShortVersionString"
      fails=$((fails + 1))
    }
  fi
fi

# public-web is self-contained: no build step, and nothing it references
# reaches outside its own directory. A relative path escaping the folder,
# or a bare '/assets/...' root-absolute one, breaks the moment the site is
# served from a subpath rather than a domain root.
if [ -f "$APP/public-web/index.php" ]; then
  if grep -oE 'src="[^"]+"|href="[^"]+"' "$APP/public-web/index.php" \
      | grep -v '^\(src\|href\)="https\?://' \
      | grep -E '"/|\.\./' ; then
    fail "public-web/index.php references a path outside public-web/"
    fails=$((fails + 1))
  else
    ok "public-web/index.php only references relative, in-folder assets or external URLs"
  fi
fi

exit "$fails"
