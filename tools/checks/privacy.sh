#!/usr/bin/env bash
# Nothing private is about to be published.
#
# This repository is public. The things that must never be in it are the
# things that identify the machine and the accounts it is built and released
# from: tokens and keys, the Developer ID signing identity and team ID, the
# Apple ID used for notarization, private hosts and project paths, and
# home-directory paths. Once a commit with one of them is pushed, deleting it
# afterwards does not take it back.
#
# Needs nothing installed. Scans every file git tracks, plus files that are
# new and not ignored (so it catches a secret BEFORE `git add`, not after).
# Outside a git checkout it scans the tree instead.
#
# A finding is reported as file:line and the rule that matched, never as the
# matching text: printing the secret into a terminal or a CI log is a leak
# of its own.
#
# Machine-local names (your GitLab host, project path, ...) are not written
# here -- this file is public too. They are read from tools/release.env, which
# is gitignored; with no such file the generic rules still run, and the
# suite says plainly that your own names were not checked.
set -uo pipefail
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
source "$TOOLS_DIR/lib/local-config.sh"

cd "$APP" || exit 1
fails=0

# --- What to scan -----------------------------------------------------------
list="$(mktemp "${TMPDIR:-/tmp}/ib-privacy.XXXXXX")"
trap 'rm -f "$list" "$list.hits"' EXIT

# core.quotepath=off: git otherwise prints a name with non-ASCII characters
# in quotes and escapes, which [ -f ] then cannot find -- so a file called
# "Ärende.txt" was silently never scanned.
#
# release.env is only excluded in the non-git fallback, where nothing can
# have been committed. In a checkout it is NOT excluded: if it is ever
# tracked (git add -f), rule 1 below has to see it.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -c core.quotepath=off ls-files --cached --others --exclude-standard
else
  find . -type f -not -path './.git/*' -not -path './.build/*' \
         -not -path './work/*' -not -path './outputs/*' \
         -not -path './tools/release.env' | sed 's|^\./||'
fi | grep -v -e '^tools/checks/privacy\.sh$' > "$list"

# --- 1. Files that should never be tracked at all ---------------------------
while IFS= read -r path; do
  base="${path##*/}"
  case "$base" in
    *.example|*.sample|*.template) continue ;;
    release.env|.env|.env.*|*.p12|*.pfx|*.pem|*.key|*.cer|*.mobileprovision|*.provisionprofile|*.keychain|*.keychain-db|id_rsa*|id_ed25519*|id_ecdsa*|*.token|credentials|credentials.*)
      fail "$path is a credential-type file and must not be committed"
      fails=$((fails + 1)) ;;
  esac
done < "$list"

# --- 2. Content rules -------------------------------------------------------
# scan <rule name> <ERE> [<ERE to exclude from the matches>] [<extra grep flags>]
scan() {
  local name="$1" pattern="$2" exclude="${3:-}" flags="${4:--}" hits
  : > "$list.hits"
  while IFS= read -r path; do
    [ -f "$path" ] || continue
    if [ -n "$exclude" ]; then
      grep -InE"${flags#-}" -- "$pattern" "$path" 2>/dev/null | grep -vE -- "$exclude" | cut -d: -f1 | sed "s|^|$path:|" >> "$list.hits" || true
    else
      grep -InE"${flags#-}" -- "$pattern" "$path" 2>/dev/null | cut -d: -f1 | sed "s|^|$path:|" >> "$list.hits" || true
    fi
  done < "$list"
  hits="$(wc -l < "$list.hits" | tr -d ' ')"
  if [ "$hits" -gt 0 ]; then
    fail "$name -- $hits place(s), contents withheld:"
    head -8 "$list.hits" | sed 's/^/        /'
    fails=$((fails + 1))
  fi
}

scan "GitLab access token"            'glpat-[A-Za-z0-9_-]{20,}'
scan "GitHub access token"            'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}'
scan "private key block"              '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "literal PRIVATE-TOKEN header"   'PRIVATE-TOKEN: *[A-Za-z0-9_-]{16,}'
scan "hard-coded API key or secret"   '(api|access|secret)[-_]?(key|token) *[:=] *"?[A-Za-z0-9_-]{15,}'
# The same, case-insensitively (apiKey = "..."), but only for a quoted literal:
# matching a bare value would flag every `apiKey = someExpression` in Swift.
scan "quoted API key literal"         '(api|access|secret|auth)[-_]?(key|token)[A-Za-z_]* *[:=] *"[A-Za-z0-9_./+=-]{16,}"' '\{env:|fake|dummy|example|placeholder|changeme|super-secret' i
scan "Hugging Face token"             'hf_[A-Za-z0-9]{30,}'
scan "OpenAI/Anthropic-style API key" '(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{24,}'
scan "AWS access key ID"              'AKIA[0-9A-Z]{16}'
scan "Google API key"                 'AIza[0-9A-Za-z_-]{35}'
scan "Slack token"                    'xox[baprs]-[A-Za-z0-9-]{10,}'
scan "JSON Web Token"                 'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.'
# user:password@host inside a URL (a pasted `git clone` line, a proxy setting).
# Placeholders and local hosts are not findings.
scan "credentials embedded in a URL"  '[A-Za-z][A-Za-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]{3,}@' 'example\.|localhost|127\.0\.0\.1|:(pass(word)?|secret|token|x{3,}|\*+|<[^>]*>|\$[{(A-Za-z_]|\\\()[^@]*@'
scan "Developer ID identity with team ID" 'Developer ID (Application|Installer): [^"]*\([A-Z0-9]{10}\)'
scan "notarytool password on a command line" '--password[ =]+[^ $"'"'"'\\]{6,}'
scan "literal Apple ID on a command line" '--apple-id[ =]+[A-Za-z0-9._%+-]+@' 'example\.(com|org)'
# /Users/<name>/ other than obvious placeholders (the Swift tests use /Users/alex).
scan "home-directory path of a real account" '/Users/[A-Za-z0-9._-]+/' '/Users/(alex|you|your-?name|name|user|username|me|Shared|Guest|example)/'

# --- 3. Names specific to this machine, from tools/release.env --------------
if [ -f "$LOCAL_CONFIG" ]; then
  local_config_refuse_secrets || { fails=$((fails + 1)); }
  n=0
  : > "$list.hits"
  # The private GitLab host and project path, plus anything listed in
  # PRIVATE_STRINGS. GITHUB_REPO is deliberately NOT searched for: the
  # GitHub repository is public by design and the app links to it.
  extras="$(local_config_get GITLAB_HOST),$(local_config_get GITLAB_PROJECT),$(local_config_get PRIVATE_STRINGS)"
  # set -f: a needle like "host*" must not be expanded as a pathname glob.
  set -f
  OLDIFS="$IFS"; IFS=','
  for needle in $extras; do
    IFS="$OLDIFS"
    needle="$(printf '%s' "$needle" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    if [ -n "$needle" ]; then
      n=$((n + 1))
      while IFS= read -r path; do
        [ -f "$path" ] || continue
        grep -IniF -- "$needle" "$path" 2>/dev/null | cut -d: -f1 | sed "s|^|$path:|" >> "$list.hits" || true
      done < "$list"
    fi
    IFS=','
  done
  IFS="$OLDIFS"
  set +f
  hits="$(wc -l < "$list.hits" | tr -d ' ')"
  if [ "$hits" -gt 0 ]; then
    fail "a name from tools/release.env appears in the tracked tree -- $hits place(s), contents withheld:"
    sort -u "$list.hits" | head -8 | sed 's/^/        /'
    fails=$((fails + 1))
  else
    ok "none of the $n private name(s) in tools/release.env appear in the tree"
  fi
else
  warn "no tools/release.env on this machine, so your own host and project names were not checked (generic rules above still ran)"
fi

# --- Result -----------------------------------------------------------------
if [ "$fails" -eq 0 ]; then
  ok "no credential, signing identity, private host or home path is in the tree"
fi
exit "$fails"
