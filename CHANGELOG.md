# Changelog

## 0.6

- The OpenCode Settings card now has a "Default coding profile" picker: every "Coding"-tagged profile still syncs as a selectable model, but the chosen one is also written as opencode.json's top-level "model" field, so OpenCode opens with it selected instead of whatever it picked on its own. Clearing the picker removes InferenceBar's own default pointer without touching a "model" value set for some other provider.

- Added a "Session stats" button to the Chat window's header (next to the context badge) that opens a popover with the running server's memory, uptime, active requests and generation speed (the same figures already shown in the Profiles window's "Runtime health" section), plus this conversation's own message count and elapsed time.

- Removed the pause/cancel download controls from the Profile editor and the Model Store (both the per-file list and the selected-model progress panel) -- those windows now only show read-only download status, since pause/resume/cancel/remove are already one click away in the Downloads window and having a second, easy-to-miss copy of the same controls elsewhere invited confusion about which one was authoritative.
- Fixed several places that could report a model as already downloaded while it was still actively downloading: a GGUF download pre-allocates its destination file on disk before it finishes, so a plain file-existence check alone can't distinguish "done" from "in progress". This affected the Model Store's per-file "On disk" label, its version counts badge (which could show a version as both downloaded and downloading at once), and the Downloads window's "Downloaded" list (which could list the same file that was also shown actively downloading above it). All of these now check for an active download job first.

- The Profiles window's list now supports selecting multiple profiles (⌘-click/⇧-click) for bulk removal, with a single confirmation naming how many will be deleted. The running profile is skipped if it's part of the selection rather than blocking the rest. Selecting exactly one profile still opens its editor as before; selecting more than one shows a "N profiles selected" placeholder instead.

- Deleting a chat from the Chat window's conversation list now asks for confirmation first, the same as deleting a profile already did.
- Fixed background errors (a chat image attachment blocked or auto-fetching its projector, a failed Homebrew install, a failed chat export, and more) silently doing nothing unless the Model Store window happened to be the frontmost window — its alert was the only one wired up to show them. Every window now shows its own errors as they happen.

- Fixed the profile editor claiming "Model downloaded" (with Start server enabled) for a profile whose model is still actively downloading — GGUF downloads can pre-allocate the destination file on disk before they finish, so a plain file-existence check alone couldn't tell "downloaded" from "still downloading". Now shows "Downloading model…" and keeps Start server disabled until the download for that profile actually finishes, matching what the Profiles list's blue downloading-dot already knew.

- Each "Add preset" category submenu now lists its "Downloaded model presets" and "Not yet downloaded" presets sorted by hardware size then name, instead of in whatever order they happen to be declared in — a long category was hard to scan for a specific size tier before.
- Added an "OpenCode" card in Settings: install OpenCode (a terminal coding agent) via Homebrew, and sync every profile added from a "Coding" preset into its config (`~/.config/opencode/opencode.json`) as a local OpenAI-compatible provider named InferenceBar, so those models show up in OpenCode without hand-editing its config. Syncing happens automatically whenever a coding preset is added, and on demand via a "Sync now" button for presets added before this existed or after editing a profile by hand. Does nothing unless OpenCode is already installed or its config directory already exists, so InferenceBar users who don't use OpenCode never get a stray config file. When authentication is enabled, the synced config references the API key via `{env:INFERENCE_API_KEY}` rather than writing the key itself into the file.
- Fixed a crash on launch for any llama.cpp profile sharing the model folder with a different vision model's projector file: `--mmproj` matching used to accept *any* mmproj file in the folder, so once two different vision model families' projectors both existed there (e.g. after the auto-download fix above), an unrelated text-only model could get wired up with a projector built for a different model entirely and llama-server would abort on a tensor-shape mismatch instead of starting. Projector matching now requires the candidate to share the model's own family/size name (or be genuinely unnamed, like "mmproj-f16.gguf") before it's used.

- Fixed the Downloads window's layout breaking down (overlapping, garbled text) when resized down — its two-pane list+detail layout needs at least 780pt of width to show both panes at once, but the window's own minimum size still allowed shrinking well below that.
- Attaching or dropping an image onto a running profile that's missing its vision projector (see the mmproj fix below) now starts fetching just that file automatically, if it's one of this app's own vision presets, instead of only ever showing a dead-end "no vision support" alert.
- Moved "Downloaded" out of the Model Store entirely and into the Downloads window, which now has a "Downloading" and a "Downloaded" section instead of splitting that information across two windows; the Model Store's search results and the Downloads window's "Downloaded" list both now show a "Vision" tag when a model actually ships an mmproj projector file, instead of relying on Hugging Face's own tags (which are often missing or stale on a GGUF requant repo).
- Fixed "Add preset"/"Add all presets" never actually fetching the mmproj projector file for the Qwen3-VL, Mistral Small 3.1, and Gemma 3 12B vision presets -- the model downloaded and ran fine, but every image attachment was refused with "no vision support" since llama.cpp had nothing to wire up as `--mmproj`. Re-running "Add all presets" now backfills the missing projector for a preset that's already downloaded, too.
- Added a "Downloads" window (Manage → Downloads, badged with the active count) listing every in-progress GGUF or MLX download with pause/cancel controls -- previously the only place to see a download's progress was buried inside the Model Store's "Downloaded" section or the one profile that started it.
- GGUF model downloads over about 32 MB now split into 4 concurrent Range requests against the same file instead of one connection end to end, since Hugging Face's CDN serves several simultaneous ranged reads of the same object at full speed each — the earlier single-stream download stayed capped well under what the connection could otherwise do. Falls back to the original single connection (with its resumable-across-restarts behavior) for hosts that don't advertise range support, or files below that size.
- The "Add preset" menu now groups its ~38 hardware presets by use case (Coding, Chat, Chat with Images, Home Automation, Systems Management) instead of one long alphabetical-ish list; a preset can appear under more than one category, and this also surfaced that Mistral Small 3.1 24B and Gemma 3 12B both ship a real mmproj projector file on Hugging Face, so they're now tagged vision-capable too.
- "Add all presets" and the "Not yet downloaded" menu now skip presets sized for more unified memory than this Mac has, instead of offering (and, for confirmed ones, auto-downloading) a model that was never going to fit; a note says how many were hidden.
- The menu bar dropdown now names how many external requests (CLI tool, opencode, etc.) are active against the running server, not just the colored dot.
- The menu bar dropdown now shows an in-progress model download (and how many more are queued behind it), so it doesn't disappear the moment you navigate away from the profile that started it.
- Verified the remaining GGUF hardware presets' source repos, so "Add all presets" now auto-downloads all of them except Llama 3.3 70B's Q6_K/Q8_0 tiers, which every quantizer ships pre-split into two files that the current single-file downloader can't reassemble (those stay a manual download, with the preset now pointing at the correct first-part filename so a manual download actually works).
- Renamed the command-line tool from `inferencebar` to `inference` (env overrides are now `INFERENCE_HOST`/`INFERENCE_PORT`/`INFERENCE_API_KEY`) — it isn't a menu bar, so the old name never fit.
- The menu bar icon now turns indigo while any client (the CLI tool, opencode, etc.) is mid-request against the running server, not just InferenceBar's own chat.
- The Profiles list now shows a distinct dot for a profile that's downloading (blue) or has no model on disk yet (dim gray), instead of just gray either way.
- "Start server" is now disabled until the profile's model has actually finished downloading.
- Fixed downloads started from "Add all presets" stomping on each other's progress numbers by running them one at a time instead of concurrently.
- Added "Add all presets", which also auto-downloads any preset model not already on disk (GGUF presets need a confirmed source repo; all MLX presets qualify).
- "Chat with Images" now filters GGUF results by an actual mmproj file instead of Hugging Face's often-missing image tag.
- Added a curated "Chat with Images" model category and Qwen3-VL 8B/32B vision+text profile presets.
- The CLI installer now prefers /usr/local/bin (with an admin prompt if needed) instead of falsely warning it wasn't on PATH.
- The chat transcript and composer now scale with the window width instead of staying pinned to a fixed narrow column.
- Fixed a stuck-forever Send button: sending while a model was still loading (not yet "Running") could permanently block every later send until the app was restarted.
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
