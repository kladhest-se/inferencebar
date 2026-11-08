# Release tooling

Scripts for checking that a working copy is safe to push, and for attaching
built files to a Release. They live in this repository so they version with the
code they check.

This repository is public, so nothing in here names a private host, an account,
a signing identity, or a token. Everything that is specific to one machine is
supplied at run time — see [Local settings](#local-settings).

```
check.sh                      pre-push checks: layout, privacy, build
upload-release-assets.sh      attach built files to a tag's GitLab (and GitHub) Release
bootstrap.sh                  what this machine is missing — reported, never installed
release.env.example           the machine-local settings file, with placeholders
checks/run.sh                 run every check suite
checks/layout.sh              the repository has the files it should, and nothing loose
checks/privacy.sh             no credential, signing identity, private host or home path
checks/build.sh               swift build + swift test
lib/                          shared helpers, sourced and never run
```

Signing and notarization are in the Makefile (`make macos-package`,
`make notarize-setup`) and [`bin/notarize-setup.sh`](../bin/notarize-setup.sh);
they find the Developer ID identity in the keychain at run time and write no
credential to disk.

## Local settings

```sh
cp tools/release.env.example tools/release.env
$EDITOR tools/release.env        # GITLAB_HOST, GITLAB_PROJECT, GITHUB_REPO
```

`tools/release.env` is gitignored and exists only on the machine that
publishes. It holds host and project **names**, never secrets: a file that
contains a token or password is refused by every script that reads it, and it
is parsed as `KEY=value` lines, never executed.

Tokens come from the environment, one variable each, and are never a flag
(an argument shows up in `ps` output and shell history) and never a file:

```sh
export GITLAB_TOKEN=...      # project-scoped, "api" scope; revoke after the release
export GITHUB_TOKEN=...      # only needed with --github / GITHUB_REPO
```

## Before pushing

```sh
make check                 # tools/check.sh: layout + privacy + build
tools/check.sh --no-build  # the two fast suites only, no Swift needed
```

`check.sh` never touches git. The privacy suite scans every tracked file **and**
every new, un-ignored file, so it catches a secret before `git add` rather than
after. It looks for access tokens, private-key blocks, a `Developer ID …
(TEAMID)` identity, a literal Apple ID or password on a `notarytool` command
line, real `/Users/<name>/` paths, credential-type files (`*.p12`, `*.pem`,
`.env`, …), and any string you list in `release.env` (the GitLab host and
project are checked automatically; add more with `PRIVATE_STRINGS`). Findings
are reported as `file:line` and the rule — never the matching text, so the check
itself cannot leak what it found.

## Attaching built files to a release

```sh
make macos-package NOTARY_PROFILE=inferencebar     # outputs/InferenceBar-X.Y-macos.dmg
git tag v0.7 && git push origin v0.7               # or pass --ref instead of pushing the tag first

make release-upload TAG=v0.7 REF=main              # everything in outputs/
# or directly:
tools/upload-release-assets.sh --tag v0.7 --ref main --dir outputs/
tools/upload-release-assets.sh --tag v0.7 --ref main --dir outputs/ --dry-run
```

With `release.env` filled in, `--host`, `--project` and `--github` are optional;
a flag always wins over the file. For a Release whose tag doesn't exist on the
remote yet, `--ref` (a branch or commit) is required — GitLab otherwise answers
`422 Ref is not specified`.

It uploads each file to GitLab's generic package registry, then attaches it as
an asset link on the Release so it appears under the Release's Assets list; with
a GitHub repo configured it attaches the same files to that Release too. It
creates a Release if there is none, and re-running after a partial failure is
safe on both sides. Files upload under their basename, and two files sharing a
basename are refused before anything is uploaded.

Troubleshooting what the status codes mean:

| Status | Usually |
|---|---|
| `404` looking up the project | wrong project path (use the path from the clone URL, not the display name in the breadcrumb), or a token that cannot see the project — GitLab answers 404, not 403 |
| `401` | expired or mistyped token, or a token without the `api` scope |
| `422` creating the Release | the tag doesn't exist yet — pass `--ref` |

## Checks

```sh
bash tools/checks/run.sh          everything that can run here
bash tools/checks/run.sh --fast   only the suites that need no toolchain
bash tools/checks/run.sh --list
```

| Suite | Needs | Covers |
|---|---|---|
| `layout` | nothing | required files exist, nothing loose at the root, generated and local-only paths are gitignored, Makefile and README agree, `public-web/` is self-contained |
| `privacy` | nothing | the tree contains nothing that identifies your machine or accounts (above) |
| `build` | Swift 6, Apple Silicon | `swift build` and `swift test` succeed |

The exit code is non-zero if any suite that ran failed. A skip (no toolchain) is
not a failure, but it is always named — a check that quietly does not run reads
as a pass.

The scripts target the bash 3.2 that macOS ships: no associative arrays, no
`mapfile`, no `${var,,}`.
