# Machine-local release settings. Sourced, never executed.
#
# The repository is public, so it cannot say where the private GitLab is, or
# which project path to upload to. Those live in tools/release.env, which is
# gitignored and which only ever exists on the machine that publishes. See
# tools/release.env.example for the keys.
#
# The file is READ, never sourced: it is parsed line by line for KEY=value,
# so nothing in it can run as code. And it is not a place for secrets:
# tokens come from the environment only, and a file that contains one is
# refused outright rather than used.

LOCAL_CONFIG="${INFERENCEBAR_RELEASE_ENV:-${TOOLS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/release.env}"

# local_config_get KEY  -> the value, or nothing
local_config_get() {
  [ -f "$LOCAL_CONFIG" ] || return 0
  # tr first: BSD sed (macOS) does not understand \r. Then: drop the key,
  # an inline "  # comment", trailing blanks, and one layer of quotes.
  grep -E "^[[:space:]]*$1[[:space:]]*=" "$LOCAL_CONFIG" 2>/dev/null | tail -1 | tr -d '\r' \
    | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/' || true
}

# local_config_refuse_secrets  -> exits 1 if the file looks like it holds one
local_config_refuse_secrets() {
  [ -f "$LOCAL_CONFIG" ] || return 0
  if grep -qiE '^[[:space:]]*[A-Z_]*(TOKEN|PASSWORD|SECRET|PASSPHRASE)[A-Z_]*[[:space:]]*=' "$LOCAL_CONFIG" 2>/dev/null \
     || grep -qE 'glpat-|gh[pousr]_[A-Za-z0-9]{20}|github_pat_' "$LOCAL_CONFIG" 2>/dev/null; then
    printf 'error: %s appears to contain a token or password.\n' "$LOCAL_CONFIG" >&2
    printf '       Remove it and export it in your shell instead (GITLAB_TOKEN / GITHUB_TOKEN);\n' >&2
    printf '       this file is for host and project names only.\n' >&2
    return 1
  fi
  return 0
}
