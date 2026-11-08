#!/usr/bin/env bash
#
# Upload built files to a GitLab generic package registry and attach each
# one as an asset link on the Release for the same tag, so they show up
# under that Release's Assets list rather than sitting undiscoverable in
# the Package Registry (which is all a plain generic-package upload does).
# Optionally does the same on a GitHub repository's Release for that tag.
#
#   GITLAB_TOKEN=... tools/upload-release-assets.sh \
#       --host gitlab.example.com \
#       --project group/project \
#       --tag v0.7.1 --ref main \
#       --dir outputs/
#
# Add --github to also attach the same files to that tag's Release on
# GitHub (creating the Release there too, if one doesn't already exist):
#
#   GITLAB_TOKEN=... GITHUB_TOKEN=... tools/upload-release-assets.sh \
#       --host gitlab.example.com \
#       --project group/project \
#       --github owner/repo \
#       --tag v0.7.1 --ref main \
#       --dir outputs/
#
# --host, --project and --github may be left off when tools/release.env
# (gitignored; see tools/release.env.example) supplies them, so a release is
# just:  tools/upload-release-assets.sh --tag v0.7.1 --ref main --dir outputs/
# A flag always beats the file. This repository is public, which is why
# those values live in a local file and not in this one.
#
# --ref is the branch or commit a new Release's tag is created from, and is
# needed whenever the tag does not exist on the remote yet: GitLab answers
# "Ref is not specified" (422) otherwise, GitHub would silently tag the
# default branch. Not needed when the tag has already been pushed.
#
# Each token is read from its own environment variable, GITLAB_TOKEN and
# GITHUB_TOKEN, never a flag -- an argument shows up in `ps` output and
# shell history -- and never from a file: tools/release.env is refused if it
# contains one. GITHUB_TOKEN is only required when --github is given. Use a
# token scoped to this one project with the "api" scope, and revoke it when
# the release is out.
#
# --project accepts a numeric ID or a namespace path (group/subgroup/
# project) -- the path as in the project's clone URL, which is not always
# the display name shown in the breadcrumb. Given a path, the numeric ID is
# resolved once via the API, so nothing needs to be looked up by hand
# first. GitLab answers 404 (not 403) for a project the token cannot see,
# so a 404 here means "wrong path or wrong token", not necessarily "no such
# project". --github takes "owner/repo", the shape GitHub uses everywhere.
#
# --package-name defaults to the last path segment of --project (so pass
# it explicitly if --project is a bare numeric ID -- there is no path
# segment to take it from, and the default would just be that number).
# --package-version defaults to --tag with a leading "v" stripped. Neither
# applies to the GitHub side -- a GitHub release asset is just a file
# attached to a Release, with no separate package name or version.
#
# GITHUB_API and GITHUB_UPLOADS override the two GitHub hosts this talks
# to (default https://api.github.com and https://uploads.github.com) --
# for GitHub Enterprise Server, or to point this at a mock server in a
# test. There is no equivalent GitLab override: --host already is one.
#
#   -n, --dry-run   say what would happen; nothing is uploaded or created
#   --no-github     GitLab only, even when GITHUB_REPO is in tools/release.env
#
# Two things the naive version of this script (curl --upload-file in a
# find loop, printing "Uploaded: $file" unconditionally) gets wrong,
# fixed here:
#
#  1. It never looks at curl's response, only its exit code -- curl exits
#     0 on a 401 or 404 same as a 201, so an expired token or a typo'd
#     project ID still prints "Uploaded" for every file. Every request
#     here checks the actual HTTP status and prints the response body on
#     anything else.
#
#  2. GitLab's generic-package file_name segment does not accept "/" --
#     uploading a file from a subdirectory using its path relative to
#     --dir (as the naive version does) fails validation for anything not
#     directly inside --dir, silently, for the same reason as (1). Files
#     are uploaded under their basename instead; two files that share a
#     basename in different subdirectories are refused up front rather
#     than one silently overwriting the other -- on either GitLab or
#     GitHub, neither of which allows two same-named assets on one release.
set -euo pipefail

HOST=""
PROJECT=""
GITHUB=""
NO_GITHUB=0
TAG=""
REF=""
PACKAGE_NAME=""
PACKAGE_VERSION=""
DIR=""
DRY=0

log()  { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host)            HOST="$2"; shift 2 ;;
    --project)         PROJECT="$2"; shift 2 ;;
    --github)          GITHUB="$2"; shift 2 ;;
    --no-github)       NO_GITHUB=1; shift ;;
    --tag)             TAG="$2"; shift 2 ;;
    --ref)             REF="$2"; shift 2 ;;
    --package-name)    PACKAGE_NAME="$2"; shift 2 ;;
    --package-version) PACKAGE_VERSION="$2"; shift 2 ;;
    --dir)             DIR="$2"; shift 2 ;;
    -n|--dry-run)      DRY=1; shift ;;
    -h|--help)         awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *)                 die "Unknown option: $1" ;;
  esac
done

# Anything not given as a flag comes from tools/release.env, if present.
source "$(cd "$(dirname "$0")" && pwd)/lib/local-config.sh"
local_config_refuse_secrets || exit 1
[ -n "$HOST" ]    || HOST="$(local_config_get GITLAB_HOST)"
[ -n "$PROJECT" ] || PROJECT="$(local_config_get GITLAB_PROJECT)"
[ "$NO_GITHUB" = "1" ] && GITHUB=""
[ "$NO_GITHUB" = "1" ] || [ -n "$GITHUB" ] || GITHUB="$(local_config_get GITHUB_REPO)"

[ -n "$HOST" ]    || die "--host is required (or GITLAB_HOST in tools/release.env), e.g. gitlab.example.com"
[ -n "$PROJECT" ] || die "--project is required (or GITLAB_PROJECT in tools/release.env): a numeric ID or a namespace path"
[ -n "$TAG" ]     || die "--tag is required"
[ -n "$DIR" ]     || die "--dir is required"
[ -d "$DIR" ]     || die "no such directory: $DIR"
[ -n "${GITLAB_TOKEN:-}" ] || die "GITLAB_TOKEN is not set; export it rather than passing it as an argument"
if [ -n "$GITHUB" ]; then
  [ -n "${GITHUB_TOKEN:-}" ] || die "GITHUB_TOKEN is not set; export it rather than passing it as an argument (needed because --github was given)"
fi
command -v python3 >/dev/null 2>&1 || die "python3 is required (JSON in, JSON out)"

API="https://$HOST/api/v4"
GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITHUB_UPLOADS="${GITHUB_UPLOADS:-https://uploads.github.com}"

# Splits a curl response into a status code and a body without needing
# --fail (which discards the body that would explain a failure). Handles
# curl itself failing to connect explicitly, rather than leaning on `set
# -e` inside a command substitution, whose behaviour there differs across
# bash versions.
api_call() {
  local method="$1" url="$2"; shift 2
  local response status
  if ! response="$(curl -sS --location --request "$method" \
                     --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
                     -w '\n%{http_code}' "$@" "$url")"; then
    printf '000\tcould not reach %s' "$url"
    return 0
  fi
  status="${response##*$'\n'}"
  printf '%s\t%s' "$status" "${response%$'\n'"$status"}"
}

# Same shape as api_call, GitHub's auth and headers instead of GitLab's.
gh_api_call() {
  local method="$1" url="$2"; shift 2
  local response status
  if ! response="$(curl -sS --location --request "$method" \
                     --header "Authorization: Bearer $GITHUB_TOKEN" \
                     --header "Accept: application/vnd.github+json" \
                     --header "X-GitHub-Api-Version: 2022-11-28" \
                     -w '\n%{http_code}' "$@" "$url")"; then
    printf '000\tcould not reach %s' "$url"
    return 0
  fi
  status="${response##*$'\n'}"
  printf '%s\t%s' "$status" "${response%$'\n'"$status"}"
}

json_get() { python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
url_encode() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }

# --- Resolve the numeric project ID -----------------------------------------
if [[ "$PROJECT" =~ ^[0-9]+$ ]]; then
  PROJECT_ID="$PROJECT"
else
  result="$(api_call GET "$API/projects/$(url_encode "$PROJECT")")"
  status="${result%%$'\t'*}"; body="${result#*$'\t'}"
  [ "$status" = "200" ] || die "looking up project '$PROJECT' failed ($status): $(printf '%s' "$body" | head -c 200)"
  PROJECT_ID="$(printf '%s' "$body" | json_get id)"
  log "resolved $PROJECT -> project ID $PROJECT_ID"
fi

[ -n "$PACKAGE_NAME" ]    || PACKAGE_NAME="${PROJECT##*/}"
[ -n "$PACKAGE_VERSION" ] || PACKAGE_VERSION="${TAG#v}"

log "project    $PROJECT_ID ($PROJECT)"
[ -n "$GITHUB" ] && log "github     $GITHUB"
log "tag        $TAG"
[ -n "$REF" ] && log "ref        $REF"
log "package    $PACKAGE_NAME / $PACKAGE_VERSION"
log "from       $DIR"
[ "$DRY" = "1" ] && warn "dry run: nothing will be uploaded or created"
log ""

# Flatten to basenames up front, and refuse a collision before anything is
# uploaded rather than after one file has silently overwritten another's
# package entry.
files=""
seen_basenames=""
while IFS= read -r file; do
  base="$(basename "$file")"
  if printf '%s\n' "$seen_basenames" | grep -qxF "$base"; then
    die "two files share the basename '$base' (neither GitLab's generic package nor a GitHub release can hold two assets with the same name); rename one"
  fi
  seen_basenames="$seen_basenames$base"$'\n'
  files="$files$file"$'\n'
done < <(find "$DIR" -type f | sort)
[ -n "$files" ] || die "no files under $DIR"

# --- Ensure a Release exists for this tag, on GitLab ------------------------
#
# An asset link attaches to a Release object, not to a tag by itself -- a
# `git tag` with no matching Release has nowhere for the link to go.
result="$(api_call GET "$API/projects/$PROJECT_ID/releases/$(url_encode "$TAG")")"
status="${result%%$'\t'*}"
case "$status" in
  200) log "release $TAG already exists" ;;
  404)
    log "no release for $TAG yet; creating one"
    if [ "$DRY" = "0" ]; then
      payload="$(python3 -c 'import json,sys; tag=sys.argv[1]; ref=sys.argv[2]; d={"tag_name": tag, "name": tag}; d.update({"ref": ref} if ref else {}); print(json.dumps(d))' "$TAG" "$REF")"
      result="$(api_call POST "$API/projects/$PROJECT_ID/releases" \
                  --header "Content-Type: application/json" --data "$payload")"
      status="${result%%$'\t'*}"; body="${result#*$'\t'}"
      if [ "$status" != "201" ]; then
        if [ -z "$REF" ] && printf '%s' "$body" | grep -qi "Ref is not specified"; then
          die "creating release $TAG failed ($status): the tag does not exist on GitLab yet -- push it, or pass --ref <branch-or-commit> to create it from one"
        fi
        die "creating release $TAG failed ($status): $(printf '%s' "$body" | head -c 200)"
      fi
      log "created release $TAG"
    fi
    ;;
  *)
    body="${result#*$'\t'}"
    die "checking release $TAG failed ($status): $(printf '%s' "$body" | head -c 200)"
    ;;
esac

# --- Same, on GitHub, only when --github was given --------------------------
#
# A GitHub release asset attaches to a numeric release ID, not to the tag
# name directly -- fetched from the existing release, or from the one just
# created.
# A GitHub problem here (bad token, no access, outage) must not stop the
# GitLab upload below: it is recorded, GitHub is skipped, and the run still
# ends non-zero so the failure is not missed.
GH_RELEASE_ID=""
GH_SKIPPED=""
if [ -n "$GITHUB" ]; then
  result="$(gh_api_call GET "$GITHUB_API/repos/$GITHUB/releases/tags/$(url_encode "$TAG")")"
  status="${result%%$'\t'*}"; body="${result#*$'\t'}"
  case "$status" in
    200)
      GH_RELEASE_ID="$(printf '%s' "$body" | json_get id)"
      log "github release $TAG already exists"
      ;;
    404)
      log "no github release for $TAG yet; creating one"
      if [ "$DRY" = "0" ]; then
        payload="$(python3 -c 'import json,sys; tag=sys.argv[1]; ref=sys.argv[2]; d={"tag_name": tag, "name": tag}; d.update({"target_commitish": ref} if ref else {}); print(json.dumps(d))' "$TAG" "$REF")"
        result="$(gh_api_call POST "$GITHUB_API/repos/$GITHUB/releases" \
                    --header "Content-Type: application/json" --data "$payload")"
        status="${result%%$'\t'*}"; body="${result#*$'\t'}"
        if [ "$status" = "201" ]; then
          GH_RELEASE_ID="$(printf '%s' "$body" | json_get id)"
          log "created github release $TAG"
        else
          GH_SKIPPED="creating the github release failed ($status): $(printf '%s' "$body" | head -c 200)"
        fi
      fi
      ;;
    *)
      GH_SKIPPED="checking the github release failed ($status): $(printf '%s' "$body" | head -c 200)"
      ;;
  esac
  if [ -n "$GH_SKIPPED" ]; then
    warn "github skipped -- $GH_SKIPPED"
    [ "$status" = "401" ] && warn "401 means GitHub rejected GITHUB_TOKEN itself (expired, mistyped, or revoked)"
    warn "continuing with gitlab; re-run later to add the github assets"
  fi
fi

if [ "$DRY" = "1" ]; then
  log ""
  printf '%s' "$files" | while IFS= read -r file; do
    if [ -n "$file" ]; then
      if [ -n "$GITHUB" ] && [ -z "$GH_SKIPPED" ]; then
        log "  would upload and link: $(basename "$file")  (gitlab + github)"
      else
        log "  would upload and link: $(basename "$file")"
      fi
    fi
  done
  exit 0
fi

# --- Upload every file, then attach it to the release(s) --------------------
uploaded=0
failed=0
gh_uploaded=0
gh_failed=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  name="$(basename "$file")"
  url="$API/projects/$PROJECT_ID/packages/generic/$PACKAGE_NAME/$PACKAGE_VERSION/$(url_encode "$name")"

  result="$(api_call PUT "$url" --upload-file "$file")"
  status="${result%%$'\t'*}"; body="${result#*$'\t'}"
  if [ "$status" != "200" ] && [ "$status" != "201" ]; then
    warn "uploading $name to gitlab failed ($status): $(printf '%s' "$body" | head -c 200)"
    failed=$((failed + 1))
  else
    payload="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "url": sys.argv[2], "link_type": "package"}))' "$name" "$url")"
    result="$(api_call POST "$API/projects/$PROJECT_ID/releases/$(url_encode "$TAG")/assets/links" \
                --header "Content-Type: application/json" --data "$payload")"
    status="${result%%$'\t'*}"; body="${result#*$'\t'}"
    if [ "$status" = "201" ]; then
      log "uploaded and linked to gitlab: $name"
      uploaded=$((uploaded + 1))
    elif printf '%s' "$body" | grep -qi "has already been taken"; then
      # Re-running after a partial failure: the package overwrites fine on
      # its own version, but a link with the same name can't be created
      # twice -- which just means it is already there.
      warn "gitlab link for $name already exists; left as is"
      uploaded=$((uploaded + 1))
    else
      warn "linking $name to the gitlab release failed ($status): $(printf '%s' "$body" | head -c 200)"
      failed=$((failed + 1))
    fi
  fi

  if [ -n "$GITHUB" ] && [ -z "$GH_SKIPPED" ]; then
    gh_url="$GITHUB_UPLOADS/repos/$GITHUB/releases/$GH_RELEASE_ID/assets?name=$(url_encode "$name")"
    result="$(gh_api_call POST "$gh_url" --header "Content-Type: application/octet-stream" --data-binary "@$file")"
    status="${result%%$'\t'*}"; body="${result#*$'\t'}"
    if [ "$status" = "201" ]; then
      log "uploaded to github release: $name"
      gh_uploaded=$((gh_uploaded + 1))
    elif printf '%s' "$body" | grep -qi "already_exists"; then
      # Same idea as the GitLab link case: re-running after a partial
      # failure re-uploads a file GitHub already has under this release,
      # which it refuses rather than replacing -- already there is fine.
      warn "github asset $name already exists; left as is"
      gh_uploaded=$((gh_uploaded + 1))
    else
      warn "uploading $name to github failed ($status): $(printf '%s' "$body" | head -c 200)"
      gh_failed=$((gh_failed + 1))
    fi
  fi
done <<< "$files"

log ""
log "gitlab: uploaded $uploaded, failed $failed"
if [ -n "$GITHUB" ]; then
  if [ -n "$GH_SKIPPED" ]; then
    log "github: SKIPPED ($GH_SKIPPED)"
  else
    log "github: uploaded $gh_uploaded, failed $gh_failed"
  fi
fi
total_failed=$((failed + gh_failed))
[ -z "$GH_SKIPPED" ] || total_failed=$((total_failed + 1))
[ "$total_failed" -eq 0 ]
