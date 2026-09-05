<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>InferenceBar — Local LLMs, native to your Mac menu bar</title>
<meta name="description" content="InferenceBar is a native SwiftUI menu-bar app for downloading, configuring, and running local language models on Apple Silicon Macs. GGUF and MLX inference, Hugging Face discovery, web search, vision support, and a built-in local chat client.">
<link rel="icon" href="assets/img/favicon-32.png" sizes="32x32">
<link rel="apple-touch-icon" href="assets/img/apple-touch-icon.png">
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>

<nav class="nav">
  <div class="wrap">
    <a class="brand" href="#top">
      <img src="assets/img/logo-256.png" alt="">
      InferenceBar
    </a>
    <div class="nav-links" id="nav-links">
      <a href="#features">Features</a>
      <a href="#showcase">Screenshots</a>
      <a href="#requirements">Requirements</a>
      <a href="#install">Install</a>
      <a class="nav-cta" href="https://github.com/kladhest-se/inferencebar" target="_blank" rel="noopener">GitHub ↗</a>
    </div>
    <button class="nav-toggle" id="nav-toggle" aria-label="Toggle navigation">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M3 6h18M3 12h18M3 18h18"/></svg>
    </button>
  </div>
</nav>

<main id="top">

  <section class="hero">
    <div class="wrap">
      <div>
        <span class="eyebrow"><span class="dot"></span>Apple Silicon · macOS 14+</span>
        <h1>Local LLMs, <span>native</span> to your Mac menu bar.</h1>
        <p class="lead">InferenceBar is a free, open-source SwiftUI app that lives in your menu bar. Discover models on Hugging Face, download and manage them, run GGUF or MLX inference, and chat with your local models — no terminal required.</p>
        <div class="hero-actions">
          <a class="btn btn-primary" href="https://github.com/kladhest-se/inferencebar" target="_blank" rel="noopener">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.09 3.29 9.4 7.86 10.93.57.1.79-.25.79-.55 0-.27-.01-1.16-.02-2.11-3.2.7-3.87-1.36-3.87-1.36-.53-1.33-1.28-1.69-1.28-1.69-1.05-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.76 2.7 1.25 3.36.96.1-.75.4-1.25.73-1.54-2.56-.29-5.25-1.28-5.25-5.7 0-1.26.45-2.29 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.79 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.8 1.19 1.83 1.19 3.09 0 4.43-2.7 5.4-5.27 5.69.42.36.78 1.07.78 2.17 0 1.57-.01 2.83-.01 3.22 0 .3.21.66.8.55A10.51 10.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>
            Get InferenceBar
          </a>
          <a class="btn btn-ghost" href="#showcase">
            See it in action
          </a>
        </div>
        <div class="hero-meta">
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 3 7v6c0 5 4 8 9 9 5-1 9-4 9-9V7l-9-5Z"/></svg>GPLv3 licensed</span>
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>100% local &amp; offline-capable</span>
          <span><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 4h16v16H4z"/><path d="M4 9h16M9 4v16"/></svg>Built with SwiftUI</span>
        </div>
      </div>

      <div class="hero-shot-frame">
        <div class="hero-shot">
          <img src="assets/screenshots/hero-chat.jpg" alt="InferenceBar local chat window showing a streamed answer with a formatted bash code block" loading="eager">
        </div>
      </div>
    </div>
  </section>

  <section id="features">
    <div class="wrap">
      <div class="section-head">
        <span class="kicker">Features</span>
        <h2>Everything you need to run models locally</h2>
        <p>From discovery to inference to conversation — InferenceBar handles the whole local-model lifecycle so you don't have to stitch it together yourself.</p>
      </div>

      <div class="grid">
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg></div>
          <h3>GGUF &amp; MLX inference</h3>
          <p>Run GGUF models with <code>llama-server</code>, or MLX and vLLM-MLX models tuned for Apple Silicon — InferenceBar drives the runtime for you.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg></div>
          <h3>Hugging Face discovery</h3>
          <p>Browse trending, most-downloaded, and curated collections — including Coding, Chat, Sysadmin, Home Automation, and Apple Silicon picks.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12"/><path d="m7 10 5 5 5-5"/><path d="M5 21h14"/></svg></div>
          <h3>Resumable downloads</h3>
          <p>Queue multiple downloads, pause and resume, and get checksum verification and provenance metadata for every model you pull.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6h16M4 12h10M4 18h7"/></svg></div>
          <h3>Model profiles &amp; presets</h3>
          <p>Save downloaded-model profiles with hardware presets and a custom system prompt or persona, pick a default profile, and launch it automatically at startup.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg></div>
          <h3>Local chat, done right</h3>
          <p>Streaming responses, Markdown and syntax-highlighted code, regenerate or edit-and-resend any message, a context-window usage indicator, attachments, drag &amp; drop, cancellation, and saved conversations.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.6 4.6l2.1 2.1M17.3 17.3l2.1 2.1M2 12h3M19 12h3M4.6 19.4l2.1-2.1M17.3 6.7l2.1-2.1"/></svg></div>
          <h3>Runtime health &amp; logs</h3>
          <p>Watch loading progress, request and context metrics, and full logs, with safe start/stop lifecycle handling for every runtime.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3c2.5 2.5 4 5.5 4 9s-1.5 6.5-4 9c-2.5-2.5-4-5.5-4-9s1.5-6.5 4-9Z"/></svg></div>
          <h3>Web search &amp; page fetching</h3>
          <p>Let the model search the web through your own SearXNG instance, or fetch and read a specific page — both optional, and each toggleable per chat.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="m21 15-5-5L5 21"/></svg></div>
          <h3>Vision-capable chat</h3>
          <p>Drop, paste, or pick a screenshot or photo for vision models like Qwen3-VL — InferenceBar detects the model's projector and wires it up automatically.</p>
        </div>
        <div class="card">
          <div class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3"/><path d="M13 15h4"/></svg></div>
          <h3>Scriptable from the terminal</h3>
          <p>A tiny <code>inferencebar</code> command-line tool pipes one-off prompts to whatever profile is running — install it with one click from Settings.</p>
        </div>
      </div>
    </div>
  </section>

  <section id="showcase">
    <div class="wrap">
      <div class="section-head">
        <span class="kicker">Screenshots</span>
        <h2>A menu-bar app that feels at home on macOS</h2>
        <p>No dashboards to self-host, no browser tabs to keep open. InferenceBar sits quietly in your menu bar until you need it.</p>
      </div>

      <div class="showcase">

        <div class="showcase-row">
          <div class="showcase-copy">
            <span class="tag">Local chat</span>
            <h3>Saved conversations, organized by project</h3>
            <p>Every chat is saved and searchable, grouped the way you actually work — by project, by topic, or just a running scratchpad.</p>
            <ul>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Streaming Markdown with syntax-highlighted code</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Text and image attachments, drag &amp; drop, and cancellation</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Regenerate a reply or edit-and-resend an earlier message</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Switch models mid-project without losing history</li>
            </ul>
          </div>
          <div class="showcase-shot">
            <img src="assets/screenshots/feature-chat-history.jpg" alt="InferenceBar chat sidebar showing saved conversations grouped by project" loading="lazy">
          </div>
        </div>

        <div class="showcase-row reverse">
          <div class="showcase-copy">
            <span class="tag">Model store</span>
            <h3>Curated discovery, built for real hardware</h3>
            <p>Browse curated collections and see, before you download, which quantizations are comfortable for your Mac's unified memory — not just what fits on disk.</p>
            <ul>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Trending, most-downloaded, and recently-updated feeds</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Per-quantization compatibility against your unified memory</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Curated picks for coding, chat, sysadmin, and home automation</li>
            </ul>
          </div>
          <div class="showcase-shot">
            <img src="assets/screenshots/feature-model-discovery.jpg" alt="InferenceBar Model Store showing curated Home Automation models with per-quantization compatibility" loading="lazy">
          </div>
        </div>

        <div class="showcase-row">
          <div class="showcase-copy">
            <span class="tag">Personalize</span>
            <h3>Themes that match your setup</h3>
            <p>Nine built-in themes — including Catppuccin, Nord, Dracula, and Solarized Dark — plus a menu-bar icon that can match the system, use your accent color, or stay monochrome.</p>
            <ul>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>System, light, dark, and community color schemes</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Optional OpenAI-compatible network endpoint for other devices</li>
            </ul>
          </div>
          <div class="showcase-shot">
            <img src="assets/screenshots/feature-themes.jpg" alt="InferenceBar server settings showing theme picker and network exposure options" loading="lazy">
          </div>
        </div>

        <div class="showcase-row reverse">
          <div class="showcase-copy">
            <span class="tag">Menu bar</span>
            <h3>Switch profiles in two clicks</h3>
            <p>Jump between favorite profiles, open chat, check logs, or tweak settings — all from the same menu-bar dropdown, without ever opening a full window.</p>
            <ul>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Favorite profiles for instant model switching</li>
              <li><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>Hourly update checks against the GitHub release tags</li>
            </ul>
          </div>
          <div class="showcase-shot">
            <img src="assets/screenshots/feature-menubar.jpg" alt="InferenceBar menu bar dropdown showing profile switching between local models" loading="lazy">
          </div>
        </div>

      </div>
    </div>
  </section>

  <section id="requirements">
    <div class="wrap">
      <div class="section-head">
        <span class="kicker">Requirements</span>
        <h2>What you'll need</h2>
        <p>InferenceBar is a thin, native layer over runtimes you already trust — it doesn't bundle or replace them.</p>
      </div>

      <div class="req-grid">
        <div class="req-card">
          <h4>To run the app</h4>
          <ul>
            <li>Apple Silicon Mac, macOS 14 or newer</li>
            <li><a href="https://brew.sh" target="_blank" rel="noopener">Homebrew</a>, for installing runtimes</li>
            <li>Enough unified memory and disk space for your chosen model</li>
          </ul>
        </div>
        <div class="req-card">
          <h4>At least one runtime</h4>
          <ul>
            <li><code>brew install llama.cpp</code> — for GGUF models</li>
            <li><code>brew install mlx-lm</code> — for MLX models</li>
            <li><code>brew install uv &amp;&amp; uv tool install vllm-mlx</code> — for vLLM-MLX</li>
          </ul>
        </div>
        <div class="req-card">
          <h4>To build from source</h4>
          <ul>
            <li>Xcode 16 or a compatible Swift 6 toolchain</li>
            <li>Git, if cloning the repository</li>
            <li>A runtime is only needed to test model execution, not to compile</li>
          </ul>
        </div>
      </div>
    </div>
  </section>

  <section id="install">
    <div class="wrap">
      <div class="section-head">
        <span class="kicker">Install</span>
        <h2>Build and run in a few commands</h2>
        <p>InferenceBar is a Swift package. Clone it, build it, and it's in your menu bar.</p>
      </div>

      <div class="install-panel">
        <div class="install-col">
          <h4>Build &amp; run from source</h4>
          <pre><span class="cm"># clone the repository</span>
git clone https://github.com/kladhest-se/inferencebar.git
cd inferencebar

<span class="cm"># build and launch</span>
<span class="fn">make</span> macos-run</pre>
        </div>
        <div class="install-col">
          <h4>Other useful targets</h4>
          <pre><span class="fn">make</span> macos-test      <span class="cm"># run all tests</span>
<span class="fn">make</span> macos-install   <span class="cm"># build, sign, install</span>
<span class="fn">make</span> macos-package   <span class="cm"># signed release DMG</span>
<span class="fn">make</span> help           <span class="cm"># show every command</span></pre>
        </div>
      </div>
    </div>
  </section>

  <section class="cta">
    <div class="wrap">
      <h2>Your models. Your Mac. Your menu bar.</h2>
      <p>InferenceBar is free and open source under the GPLv3. Clone it, build it, and start running local models today.</p>
      <div class="cta-actions">
        <a class="btn btn-primary" href="https://github.com/kladhest-se/inferencebar" target="_blank" rel="noopener">
          <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 .5C5.65.5.5 5.65.5 12c0 5.09 3.29 9.4 7.86 10.93.57.1.79-.25.79-.55 0-.27-.01-1.16-.02-2.11-3.2.7-3.87-1.36-3.87-1.36-.53-1.33-1.28-1.69-1.28-1.69-1.05-.71.08-.7.08-.7 1.16.08 1.77 1.19 1.77 1.19 1.03 1.76 2.7 1.25 3.36.96.1-.75.4-1.25.73-1.54-2.56-.29-5.25-1.28-5.25-5.7 0-1.26.45-2.29 1.19-3.09-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.79 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.8 1.19 1.83 1.19 3.09 0 4.43-2.7 5.4-5.27 5.69.42.36.78 1.07.78 2.17 0 1.57-.01 2.83-.01 3.22 0 .3.21.66.8.55A10.51 10.51 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5z"/></svg>
          View on GitHub
        </a>
        <a class="btn btn-ghost" href="https://github.com/kladhest-se/inferencebar/blob/main/CHANGELOG.md" target="_blank" rel="noopener">Read the changelog</a>
      </div>
    </div>
  </section>

</main>

<footer>
  <div class="wrap">
    <div class="foot-brand">
      <img src="assets/img/logo-256.png" alt="">
      InferenceBar — licensed under GPLv3
    </div>
    <div class="foot-links">
      <a href="https://github.com/kladhest-se/inferencebar" target="_blank" rel="noopener">GitHub</a>
      <a href="https://github.com/kladhest-se/inferencebar/blob/main/CHANGELOG.md" target="_blank" rel="noopener">Changelog</a>
      <a href="https://github.com/kladhest-se/inferencebar/blob/main/LICENSE.md" target="_blank" rel="noopener">License</a>
    </div>
  </div>
</footer>

<script src="assets/js/main.js"></script>
</body>
</html>
