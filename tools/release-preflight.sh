#!/usr/bin/env bash
# Everything that can be known to be wrong with a release BEFORE spending
# ten minutes on notarization, checked up front.
#
#   TAG=v0.7.1 VERSION=0.7.1 NOTARY_PROFILE=inferencebar tools/release-preflight.sh
#
# Run by `make release-all` (which supplies the variables); runnable by hand.
# Never changes git state. The only network use is one read-only request per
# access token, to catch a token the host rejects BEFORE a ten-minute
# notarization instead of after it (PREFLIGHT_OFFLINE=1 skips them). Every
# problem is reported, not just the first, so one run is enough to fix them.
#
#   TAG                  the release tag, normally v<VERSION>
#   VERSION              the app's version (CFBundleShortVersionString)
#   NOTARY_PROFILE       required, unless ALLOW_UNNOTARIZED=1: a build that
#                        was signed but not notarized trips Gatekeeper for
#                        everyone who downloads it
#   ALLOW_UNNOTARIZED    set to 1 to release without notarization anyway
#   GITLAB_TOKEN         required (environment only -- see tools/README.md)
#   GITHUB_TOKEN         required only when tools/release.env names GITHUB_REPO
#   PREFLIGHT_OFFLINE    set to 1 to skip the token checks that call the hosts
set -uo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"
source "$TOOLS_DIR/lib/local-config.sh"

cd "$APP" || exit 1
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

# --- Signing identity ------------------------------------------------------------
# macos-package signs with ad-hoc ("-") when no Developer ID Application
# certificate is in the keychain, and Apple rejects an ad-hoc build at
# notarization -- after the ten-minute build. (Whether the notarytool profile
# exists is not checked: it can only be tested over the network.)
if [ "$(uname -s)" = "Darwin" ]; then
  identity="${CODESIGN_IDENTITY:-}"
  if [ -z "$identity" ] || [ "$identity" = "-" ]; then
    if [ "${ALLOW_UNNOTARIZED:-0}" = "1" ]; then
      warn "no Developer ID Application certificate: the build will be ad-hoc signed"
    else
      bad "no 'Developer ID Application' certificate in the keychain, so the build would be ad-hoc signed and Apple would reject it (see 'make signing-identities'; ALLOW_UNNOTARIZED=1 overrides)"
    fi
  else
    ok "signing with a Developer ID Application certificate"
  fi
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

# --- Do the hosts accept the tokens? -----------------------------------------
# "Set" is not "valid": an expired or mistyped token only shows up as a 401
# after the build and notarization. One read-only request each. A host that
# cannot be reached is a warning (offline is not a bad token); a rejection
# is a failure.
http_status() {  # http_status <url> <curl header args...>  -> prints the HTTP status, 000 if unreachable
  local url="$1"; shift
  # curl prints 000 itself when it cannot connect, so a non-zero exit is not an error here.
  curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}
if [ "${PREFLIGHT_OFFLINE:-0}" = "1" ]; then
  warn "PREFLIGHT_OFFLINE=1: not checking the tokens against GitLab/GitHub"
else
  if [ -n "$host" ] && [ -n "$project" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
    case "$project" in *[!0-9]*) project_ref="$(printf '%s' "$project" | sed 's|/|%2F|g')" ;; *) project_ref="$project" ;; esac
    st="$(http_status "https://$host/api/v4/projects/$project_ref" -H "PRIVATE-TOKEN: $GITLAB_TOKEN")"
    case "$st" in
      200) ok "GitLab accepts GITLAB_TOKEN and can see the project" ;;
      401) bad "GitLab rejected GITLAB_TOKEN (401): expired, mistyped or revoked" ;;
      404) bad "GitLab answers 404 for '$project': wrong project path, or the token cannot see it (GitLab never says 403 here)" ;;
      000) warn "could not reach https://$host to check GITLAB_TOKEN (offline? set PREFLIGHT_OFFLINE=1 to silence)" ;;
      *)   warn "GitLab answered $st when checking GITLAB_TOKEN; not treated as a failure" ;;
    esac
  fi
  if [ -n "$github" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    gh_api="${GITHUB_API:-https://api.github.com}"
    gh_body="$(mktemp "${TMPDIR:-/tmp}/ib-preflight.XXXXXX")"
    st="$(curl -sS -o "$gh_body" --max-time 10 -w '%{http_code}' -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$gh_api/repos/$github" 2>/dev/null || true)"
    case "$st" in
      200)
        # The response lists what this token may do on the repository.
        if grep -q '"permissions"' "$gh_body" && ! grep -Eq '"push": *true' "$gh_body"; then
          bad "GITHUB_TOKEN can read $github but not write to it (a Release needs Contents: read and write)"
        else
          ok "GitHub accepts GITHUB_TOKEN for $github"
        fi ;;
      401) bad "GitHub rejected GITHUB_TOKEN (401 Bad credentials): expired, mistyped or revoked" ;;
      404) bad "GitHub answers 404 for $github: wrong repository name, or the token has no access to it" ;;
      000) warn "could not reach GitHub to check GITHUB_TOKEN (offline? set PREFLIGHT_OFFLINE=1 to silence)" ;;
      *)   warn "GitHub answered $st when checking GITHUB_TOKEN; not treated as a failure" ;;
    esac
    rm -f "$gh_body"
  fi
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
