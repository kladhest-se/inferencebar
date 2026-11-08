#!/usr/bin/env bash
# Everything that can be known to be wrong with a release BEFORE spending
# ten minutes on notarization, checked up front.
#
#   TAG=v0.7 VERSION=0.7 NOTARY_PROFILE=inferencebar tools/release-preflight.sh
#
# Run by `make release-all` (which supplies the variables); runnable by hand.
# Never touches git state or the network. Every problem is reported, not just
# the first, so one run is enough to fix them all.
#
#   TAG                  the release tag, normally v<VERSION>
#   VERSION              the app's version (CFBundleShortVersionString)
#   NOTARY_PROFILE       required, unless ALLOW_UNNOTARIZED=1: a build that
#                        was signed but not notarized trips Gatekeeper for
#                        everyone who downloads it
#   ALLOW_UNNOTARIZED    set to 1 to release without notarization anyway
#   GITLAB_TOKEN         required (environment only -- see tools/README.md)
#   GITHUB_TOKEN         required only when tools/release.env names GITHUB_REPO
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$TOOLS_DIR/lib/local-config.sh"

cd "$APP"
problems=0
bad() { fail "$*"; problems=$((problems + 1)); }

say ""
say "Release preflight"
dim "  tag ${TAG:-?}  version ${VERSION:-?}"
say ""

# --- Version, tag, changelog --------------------------------------------------
if [ -z "${VERSION:-}" ]; then
  bad "no app version -- work/Info.plist could not be read (PlistBuddy is macOS-only)"
elif [ -z "${TAG:-}" ]; then
  bad "no TAG given"
else
  # The app's update check compares the release tag with CFBundleShortVersionString,
  # so a tag that disagrees with it announces a different version than it ships.
  if [ "$TAG" != "v$VERSION" ]; then
    bad "tag $TAG does not match the app version $VERSION (expected v$VERSION); bump work/Info.plist or pass TAG=v$VERSION"
  else
    ok "tag $TAG matches app version $VERSION"
  fi
  if grep -qE "^## +$(printf '%s' "$VERSION" | sed 's/\./\\./g')([[:space:]]|$)" CHANGELOG.md 2>/dev/null; then
    ok "CHANGELOG.md has a $VERSION section"
  else
    bad "CHANGELOG.md has no '## $VERSION' section"
  fi
fi

# --- Git state ------------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
    ok "working tree is clean"
  else
    bad "uncommitted changes -- a release must be built from a committed state"
    git status --short | head -5 | sed 's/^/        /'
  fi

  head_sha="$(git rev-parse HEAD)"

  # A tag that already exists must point at what is being released.
  if [ -n "${TAG:-}" ] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    tag_sha="$(git rev-list -n1 "$TAG")"
    if [ "$tag_sha" = "$head_sha" ]; then
      ok "tag $TAG already exists, on this commit"
    else
      bad "tag $TAG already exists locally but points at a different commit than HEAD"
    fi
  fi

  # The Release is created from a ref on the remote, so HEAD has to be there.
  # Judged from the remote-tracking branches as of the last fetch.
  remotes="$(git remote)"
  if [ -z "$remotes" ]; then
    warn "no git remotes configured; nothing to check HEAD against"
  else
    for remote in $remotes; do
      if git branch -r --contains "$head_sha" 2>/dev/null | grep -qE "^[[:space:]]*$remote/"; then
        ok "HEAD is on remote '$remote'"
      else
        bad "HEAD is not on remote '$remote' (as of your last fetch) -- run: git push $remote $(git rev-parse --abbrev-ref HEAD)"
      fi
    done
  fi
else
  warn "not a git checkout, so the git checks were skipped"
fi

# --- Signing and notarization -----------------------------------------------------
if [ -n "${NOTARY_PROFILE:-}" ]; then
  ok "notarization profile '$NOTARY_PROFILE' will be used"
elif [ "${ALLOW_UNNOTARIZED:-0}" = "1" ]; then
  warn "ALLOW_UNNOTARIZED=1: this release will be signed but NOT notarized"
else
  bad "NOTARY_PROFILE is not set -- the build would not be notarized and Gatekeeper would warn every downloader (see 'make notarize-help'; ALLOW_UNNOTARIZED=1 overrides)"
fi

# --- Where it is going ---------------------------------------------------------------
local_config_refuse_secrets || problems=$((problems + 1))
host="$(local_config_get GITLAB_HOST)"; project="$(local_config_get GITLAB_PROJECT)"; github="$(local_config_get GITHUB_REPO)"
if [ -n "$host" ] && [ -n "$project" ]; then
  ok "release target is configured in tools/release.env"
else
  bad "GITLAB_HOST / GITLAB_PROJECT are not set in tools/release.env (copy tools/release.env.example)"
fi
if [ -n "${GITLAB_TOKEN:-}" ]; then
  ok "GITLAB_TOKEN is set"
else
  bad "GITLAB_TOKEN is not set (export it in your shell; it is never read from a file)"
fi
if [ -n "$github" ]; then
  if [ -n "${GITHUB_TOKEN:-}" ]; then ok "GITHUB_TOKEN is set"
  else bad "GITHUB_REPO is configured but GITHUB_TOKEN is not set"; fi
fi

# --- This machine ---------------------------------------------------------------------
if [ "$(uname -s)" = "Darwin" ]; then
  ok "running on macOS"
else
  bad "this must run on a Mac: codesign, notarytool and hdiutil are macOS-only"
fi

say ""
if [ "$problems" -eq 0 ]; then
  ok "preflight passed"
  exit 0
fi
fail "$problems problem(s) -- nothing was built"
exit 1
