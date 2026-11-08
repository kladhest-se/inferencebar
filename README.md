# InferenceBar

InferenceBar is a native SwiftUI menu-bar application for downloading, configuring, and running local language models on Apple Silicon Macs.

[Website](https://inferencebar.kladhest.se) · [GitHub](https://github.com/kladhest-se/inferencebar) · [Changelog](CHANGELOG.md)

## Features

- GGUF inference with `llama-server` and MLX inference with `mlx-lm` or `vllm-mlx`.
- Hugging Face discovery, compatibility guidance, metadata, persistent queues, and resumable downloads.
- Downloaded-model profiles, hardware presets, default-profile startup, per-profile system prompts, runtime health, and logs.
- Local chat with streaming, Markdown, code highlighting, regenerate and edit-and-resend, a context-window usage indicator, text and image attachments (drop, pick, or paste a screenshot for vision-capable models), cancellation, and saved conversations — exportable to Markdown.
- Optional web search (against your own SearXNG instance) and single-page fetching, each toggleable per chat.
- Optional TLS (llama.cpp), a keychain-stored API key, crash notifications, opt-in auto-restart, and a global keyboard shortcut for the Chat window.
- Optional `inference` command-line tool (`inference ask "..."`) for scripting against whatever profile is currently running, installable from Settings or `make install-cli`.

## Requirements for running the app

- Apple Silicon Mac running macOS 14 or newer.
- [Homebrew](https://brew.sh) is required for installing and managing inference runtimes.
- At least one runtime:
  - `brew install llama.cpp` for GGUF models.
  - `brew install mlx-lm` for MLX models.
  - `brew install uv && uv tool install vllm-mlx` for vLLM-MLX.
- Enough unified memory and free disk space for the selected model and context size.

## Requirements for building from source

- Apple Silicon Mac running macOS 14 or newer.
- Xcode 16 or a compatible Swift 6 toolchain.
- Git, if cloning the repository.
- An inference runtime is only required when testing model execution; it is not needed to compile the app.

## Build and test

```sh
make
```

The release executable is written to `.build/release/InferenceBar`.

Additional commands:

```sh
make macos-run      # Compile and start the app
make macos-build    # Build without launching the app
make macos-app      # Build and assemble InferenceBar.app in place, unsigned
make macos-open     # Open the project in Xcode
make macos-test     # Run all tests
make macos-archive  # Create the source archive in outputs/
make macos-install  # Build, sign, and install in /Applications
make macos-release  # Build a signed release ZIP in outputs/
make macos-package  # Build a signed release DMG for a GitHub release
make cli            # Build just the inference-cli command-line tool
make install-cli    # Build the CLI and install it on your PATH as `inference`
make help           # Show all available commands
make clean          # Remove local build products
make check          # Pre-push checks: layout, no secrets in the tree, build
make release-all    # Preflight, checks, notarized DMG + ZIP, upload to the Release
```

Release tooling (pre-push checks, attaching built files to a GitLab/GitHub
Release) lives in [`tools/`](tools/README.md).

Signing falls back to an ad-hoc signature only when no Developer ID Application
identity is found in the keychain — if one is installed, it's picked up and used
automatically, so `CODESIGN_IDENTITY` rarely needs setting by hand. Run
`make signing-identities` to see what's available, and override explicitly only
if more than one Developer ID Application identity is installed and the wrong
one gets picked:

```sh
make macos-package CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

**A signature — even a real one — is not enough on its own.** A build
downloaded from anywhere (GitLab, a browser) carries a quarantine flag, and
Gatekeeper checking a quarantined, merely-*signed*-but-not-*notarized* build is
exactly the "Apple could not verify this app is free of malware" dialog. Getting
past that needs the build submitted to Apple's notary service and the resulting
ticket stapled to it — one-time setup, once you have a Developer ID Application
certificate in the keychain:

```sh
make notarize-setup
```

finds the team ID (from that certificate) and the Apple ID (from the account
this Mac is signed into, shown for confirmation) automatically, so the only
thing left to type is the app-specific password `notarytool` itself prompts
for — generate one at appleid.apple.com, under Sign-In and Security >
App-Specific Passwords, not your Apple ID password. Pass a different profile
name with `NOTARY_PROFILE=name`; `make notarize-help` explains what this is
doing and how to do it by hand instead. After that, once per Mac:

```sh
export NOTARY_PROFILE=inferencebar
make macos-package   # or macos-release — both notarize when this is set
```

Leave `NOTARY_PROFILE` unset to skip notarization (the default); `make` says so
plainly when it does. The install destination can be changed, for example with
`make macos-install APP_DEST="$HOME/Applications"`.

## Run from source

```sh
make macos-run
```

Application data is stored under `~/Library/Application Support/InferenceBar`. The model directory defaults to `~/ai-models` and can be changed in Settings.

## Command-line tool

`inference ask "<prompt>"` sends a one-off prompt to whatever profile is
currently running and prints the answer — handy for scripting against your
local model from a terminal or another script without opening the Chat
window. Install it from InferenceBar's Settings ("Command-line tool" →
Install), which copies the bundled binary onto your `PATH` (preferring
`/usr/local/bin`, with a one-time admin prompt if needed); building from
source instead, `make install-cli` does the same thing.

```sh
inference ask "what's 2 + 2?"
echo "summarize this" | inference ask
```

It reads the server's host, port, and (if enabled) API key from
InferenceBar's own settings automatically. `INFERENCE_HOST`,
`INFERENCE_PORT`, and `INFERENCE_API_KEY` override those — the last
one is also the reliable option for scripted or headless use, since a
keychain item created by InferenceBar.app can prompt for permission (or
fail silently with no GUI session to answer it in) the first time a
different binary reads it.

## License

InferenceBar is licensed under the [GNU General Public License v3 or later](LICENSE.md). The complete license text is in [LICENSE](LICENSE).
