# Changelog

## 0.6 (Unreleased / dev)

- Fixed mmproj detection matching a projector file for a model that doesn't exist on disk.
- Fixed a wrong expected value in a tall-image downscaling test.
- Added image attachments for vision-capable models (drop, pick, or paste a screenshot/photo); llama.cpp now launches with `--mmproj` automatically when a projector file is present.
- Fixed a scoping bug in `sendPrompt`'s unexpected-HTML detection.
- Removed the GitHub Actions CI workflow.
- Added an optional `inferencebar` command-line tool (`inferencebar ask "..."`), installable from Settings or `make install-cli`.
- Added "Regenerate" and "Edit and resend" for chat messages.
- Added a context-usage indicator ("N% context" badge plus a near-full warning).
- Made the system prompt editable in Settings, with per-profile overrides.
- Stopped logging a "Chat isolation" error on every message.
- Added an optional "fetch URL" tool alongside web search.
- Added a per-chat toggle to turn web search off without changing the Settings default.
- Added optional web search via a configured SearXNG instance.
- Fixed the Profiles window shrinking to a broken layout once the last profile is deleted.
- Fixed the Apple menu's "About InferenceBar"/"Settings…" items to open the app's real windows instead of the generic macOS ones.
- Added a shortcut recorder in Settings so the global hotkey (⌥⌘Space by default) can be changed.
- Fixed a test that treated an unrecognized MLX architecture as an error instead of a warning.
- Removed `InferenceBarUITests` (SwiftPM can't run `XCUIApplication`) and rewrote it as logic tests in `Tests/InferenceBarTests`.
- Fixed a Swift 6 `@MainActor` compile error in the (now-removed) `InferenceBarUITests`.
- Renamed the menu bar's "About InferenceBar" item to "About".
- Fixed `InferenceBarUITests` launching `XCUIApplication()` with no target app configured.
- Fixed a Swift 6 concurrency compile error in the hotkey event-matching code.
- `make clean` now also clears the Swift/Clang module caches.
- Deleting a profile now asks for confirmation first.
- The profile editor now notes when you're editing the currently running profile.
- Removed unused `ServerProfile.host`/`.port` fields.
- Stopping the server now force-kills it after 5 seconds if it won't exit on its own.
- Removed a leftover duplicate Settings window that was never reachable through the UI.
- Unrecognized GGUF/MLX architectures are now a warning instead of a hard block.
- Renamed the old `LlamaDock` source paths to `InferenceBar`.
- Engine logs are now saved to disk, capped in memory, with a "Reveal log file" button.
- The update notice now links straight to the specific release page.
- Added accessibility labels to icon-only controls throughout the app.
- Starting a profile with network access on and auth off now asks for confirmation.
- Added `NewFeaturesTests.swift` and fixed Settings/Logs test mismatches it turned up.
- Removed hard-coded flags that disabled llama.cpp prompt-cache reuse on every profile.
- Raised the Qwen 3.6 35B preset's context size from 65536 to 131072.
- The update checker now compares against the app's real version instead of a hard-coded string.
- Added the `InferenceBarUITests` test target.
- Moved the server API key out of a JSON file and into the keychain.
- Fixed two crashes from force-unwraps in the Hugging Face model lookup.
- Added an "Only used by InferenceBar" profile flag so its own chat benefits from prompt-cache reuse too.
- Added optional cache-reuse and swa-full controls in a new profile Cache section.
- Added optional TLS support for the llama.cpp backend.
- Added local notifications for crashes and completed downloads.
- Added an opt-in auto-restart-on-crash setting.
- Added an opt-in global keyboard shortcut (⌥⌘Space) to show/hide the Chat window.
- Added "Export as Markdown…" for saved chats.
- Added an "About InferenceBar" item to the menu bar.
- Added a GitHub Actions CI workflow.
- Clarified in the Makefile that `--disable-sandbox` is SwiftPM's build sandbox, not the app's runtime sandbox.

## 0.5

- Added GGUF, MLX, and vLLM-MLX runtime support with Homebrew dependency checks.
- Added Hugging Face discovery, curated collections, Apple Silicon recommendations, compatibility validation, and model provenance.
- Added persistent resumable downloads, multiple queued downloads, pause/resume/cancel controls, checksums, and metadata manifests.
- Added downloaded-model profiles, runtime-filtered selection, hardware presets, default profiles, and optional startup launch.
- Added runtime health, loading progress, request/context metrics, logs, and safe starting/stopping lifecycle states.
- Added saved local chats with streaming, Markdown tables and formatting, syntax-highlighted code blocks, copy controls, attachments, drag and drop, cancellation, and follow-tail scrolling.
- Added themes, menu-bar controls, hourly GitHub tag checks, update indication, project links, and GPL licensing.
- `macos-package`/`macos-release` now notarize and staple the build when configured.
- `CODESIGN_IDENTITY` now auto-detects a Developer ID certificate instead of always falling back to ad-hoc signing.
- Added `make notarize-setup` to auto-fill notarization credentials.
- Improved the error message when no Developer ID certificate is found.
