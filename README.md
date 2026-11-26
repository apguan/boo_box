# boo_box

A native macOS terminal built on **`libghostty` (`GhosttyKit`)** where every tab runs inside an isolated sandbox — built for safely running AI coding agents and untrusted dev workflows without exposing your Mac.

<p align="center">
  <img src="docs/screenshots/workspace-overlay.png" alt="boo_box macOS terminal running an isolated ~20 ms CoW overlay sandbox with Seatbelt isolation and opt-in pinned folders" width="960" />
</p>

---

## Why `boo_box`?

Running autonomous coding agents directly on your host shell gives them full access to `~/Desktop`, `~/Documents`, `~/.ssh`, your real git checkouts, and host API keys.

`boo_box` gives every session its own isolated sandbox while keeping native Ghostty GPU performance and zero-friction developer ergonomics:

- **Three execution modes in one terminal:**
  1. **macOS Sandbox (default, `⌘T` / `boo .`):** Kernel-enforced macOS Seatbelt (`sandbox-exec`) with a per-session `$HOME` (`~/boo_box/sessions/<id>/`) and **~20 ms $O(1)$ Instant CoW Overlay** (`boobox-overlay`) — or optional APFS `clonefile(2)` snapshot (`boobox-clone`). Agents can edit or `rm -rf` freely without ever modifying your real repo or host files.
  2. **Private Linux MicroVM (`⇧⌘N`):** Ephemeral Apple Silicon `arm64` Linux microVM via Apple's `Virtualization.framework` (`vmlinux-arm64` + APFS-cloned Alpine `rootfs.ext4`, 1-slot warm VM pool, multi-PTY over `vsock` via `boobox-attach`). Zero Mac filesystem access by default; wiped on close.
  3. **Raw Host Shell (`⌥⌘T`):** Explicit unsandboxed escape hatch with an unmistakable red warning header.
- **Seatbelt-Denied Host Vault & Egress Proxy Sidecar (`boobox-proxy`):**
  - Real API keys, GitHub tokens, and OAuth credentials stay **only on the host** in the Seatbelt-denied **Host Vault** (`~/boo_box/vault/`, `0700`/`0600`, zero Keychain ACL prompts across rebuilds/updates) or **1Password (`op://`)** — never written to `config.json` or sandbox files.
  - Sandboxes only receive worthless phantom tokens (`bbx_ph_...`) and Base-URL routes swapped at `boobox-proxy` strictly for bound hosts, with response scrubbing and active exfiltration blocking (`403 leak_blocked`).
  - Three outbound network policies (`Full (Vault Protected)`, `Dev Allowlist`, `Offline (Air-gapped)`), enforced at the kernel level via Seatbelt + direct DNS (`/var/run/mDNSResponder`) blocking.
- **Per-Sandbox Overrides (`⌥⌘,` or sidebar `…` popup):** Override network policy, Vault secret subsets, env vars, shared toolchains, host capabilities, per-process kernel `rlimit` / `nice` caps, and Private VM vCPU / RAM / NAT-or-Offline / VirtioFS `/mnt/host` shares individually per session.
- **Global Sandbox Environment (`~/boo_box/env`):** Run arbitrary install scripts (`curl … | sh`, `npm i -g`, `bun add -g`, `uv tool install`, `go install`, `cargo install`, etc.) inside Seatbelt targeting `~/boo_box/env`, with automatic executable directory discovery added to sandbox `PATH` across all sessions.
- **O(1) Instant CoW Overlay (`boobox-overlay`) & Zero-Hang Lifecycle:**
  - Default workspace engine (`boobox-overlay`) mounts any folder — even multi-million-file monorepos or multi-repo directories — in **`~20 ms`** via unprivileged localhost NFSv3 Copy-on-Write (`O_RDONLY | O_NOFOLLOW` host lower layer + isolated `.overlay/upper/` + whiteouts, pipelined TCP RPCs, `READDIR` caching, Git `core.checkStat=minimal`, Seatbelt-blocked localhost port, 128-bit HMAC handles, zero `sudo`/kexts).
  - Optional **APFS Full Clone** (`--clone` / `--full` / `--slim`, or in `Settings → General`) uses `boobox-clone` + kernel `clonefile(2)` + warm pool + Git delta sync for a frozen point-in-time snapshot.
  - Persistent detached PTYs (`booboxd`) keep running shells and coding agents alive across app quits and auto-updates, with 128 KiB scrollback replay on reattach.
  - Deleting saved/active sessions and running `rm -rf <dir>` inside sandboxes both use atomic move-aside + detached background reaping (`<5 ms`).


## First-Time Setup (Recommended: Let Your Agent Do It)

Because `boo_box` runs every tab inside a strict macOS Seatbelt sandbox (kernel-blocking macOS Keychain, `~/.ssh`, host `/opt/homebrew` writes, and files outside your cloned workspace), there is a bit of one-time setup to wire your GitHub login, API keys, cloud CLIs, global toolchains, and MCP servers so you never have to re-authenticate per tab.

**Fastest way to get set up:** open your coding agent (Claude Code, OMP, Codex, OpenCode, etc.) in a host terminal and paste:

> **Read `SETUP_COOKBOOK.md` in this repo, walk me through the setup questions, and configure `boo_box` for my Mac.**

You can also sign into **GitHub** (for sandbox `git` / `gh` with live `preexec` hot-reload) and **Notion, Linear, Vercel, Supabase, Stripe, Sentry, Cloudflare, Figma, and Slack** (1-click Browser OAuth 2.1 + PKCE + DCR) inside **`Settings (⌘,) → Connections`** — tokens stay in the Seatbelt-denied Host Vault (`~/boo_box/vault/`) and sync directly into OMP, OpenCode, Claude Code, Codex, and Gemini CLI — or read **[`SETUP_COOKBOOK.md`](./SETUP_COOKBOOK.md)** for every recipe and sandbox gotcha.
---

## Architecture

```mermaid
flowchart TB
  CLI["~/.local/bin/boo + boobox-env<br/>(CLI launcher · --overlay / --clone / --no-env)"] -->|"Unix socket IPC (~/boo_box/run/app.sock)"| APP

  subgraph APP["boo_box.app (Swift 6 · AppKit + SwiftUI)"]
    UI["Sidebar · Header · Settings · Connections · Per-Sandbox Sheet"]
    STAGE["TerminalStageView (persistent NSViews · occlusion pause)"]
    GK["GhosttyKit 1.4.0 (libghostty · Metal GPU)"]
    UI --> STAGE --> GK
  end

  subgraph PERSIST["Persistent Host Daemons (Survive App Quits & Auto-Updates)"]
    PTYD["booboxd<br/>(Detached PTY host · 128 KiB replay)"]
    OVL["boobox-overlay<br/>(O(1) ~20 ms NFSv3 CoW · O_RDONLY host lower · .overlay/upper/)"]
    PROXY["boobox-proxy<br/>(Domain Firewall · Base-URL Phantom Tokens · Leak Blocker)"]
    VAULT["Host Vault (~/boo_box/vault/ 0700 · Seatbelt-Denied)<br/>+ 1Password (op://)"]
    VAULT -->|"0600 proxy-ctl.sock"| PROXY
  end

  GK -->|"Mode 1: ⌘T / boo ."| PTYD -->|"sandbox-exec (.sandbox.sb)"| SB["macOS Seatbelt Sandbox<br/>Per-session HOME + .boobox-bin shims (git/gh/rm/cp/mktemp)<br/>Per-process rlimits/nice + preexec hot-reload"]
  GK -->|"Mode 2: ⇧⌘N"| VM["Private Linux MicroVM (Virtualization.framework)<br/>arm64 Linux + APFS-cloned rootfs.ext4<br/>boobox-attach ↔ vsock:5123"]
  GK -->|"Mode 3: ⌥⌘T"| RAW["Raw Host Shell (red warning chrome)"]

  SB <-->|"Kernel NFSv3 mount (localhost port Seatbelt-blocked)"| OVL
  SB -.->|"Optional --clone / --slim"| CLONE["boobox-clone<br/>(APFS clonefile(2) + warm pool + Git delta sync)"]
  SB <-->|"Loopback proxy + bbx_ph_… phantom tokens"| PROXY
  SB --- CACHE["~/boo_box/cache (shared pkg caches)"]
  SB --- ENV["~/boo_box/env (sandboxed global toolchains)"]
```

### Components

| Component | Path | Responsibility |
|---|---|---|
| `boo_box` | `Sources/BooBox/` | Native macOS Swift 6 / AppKit + SwiftUI terminal embedding `GhosttyKit 1.4.0`, managing Seatbelt sessions, Private VMs, Host Vault, OAuth 2.1, and IPC |
| `boobox-overlay` | `Sources/BooBoxOverlay/` | Persistent userspace RFC 1813 NFSv3 Copy-on-Write daemon (`~20 ms` $O(1)$ mounts, pipelined TCP RPCs, `READDIR` cache, HMAC handles, `.env` filtering, whiteouts) |
| `booboxd` | `Sources/BooBoxDaemon/` | Persistent detached PTY daemon (`~/boo_box/run/booboxd.sock`) keeping live shells & coding agents running across app quits and updates |
| `boobox-proxy` | `Sources/BooBoxProxy/` | Host-side HTTP/CONNECT egress firewall, per-session policy engine, Base-URL phantom-token injector, SSE streamer, and exfiltration blocker |
| `boobox-clone` | `Sources/BooBoxClone/` | Optional APFS `clonefile(2)` project cloner, lock-free warm-pool popper, Git delta sync, and Unix socket IPC client |
| `boobox-attach` | `Sources/BooBoxAttach/` | Lightweight PTY ↔ Unix-socket ↔ guest `vsock` multiplexer for detached `booboxd` panes and Private Linux MicroVMs |
| `sbox-init` | `guest/sbox-init.c` | Minimal static PID 1 vsock PTY daemon running inside the Alpine Linux microVM |
| `boo` / `boobox-env` | `scripts/boo`, `scripts/boobox-env` | CLI session launcher and sandboxed global environment installer |

## Screenshots

| Per-Sandbox Overrides (`⌥⌘,`) | Connections (GitHub Auth & OAuth 2.1 MCPs) |
|---|---|
| ![Per-Sandbox Configuration](docs/screenshots/sandbox-config.png) | ![Connections Settings](docs/screenshots/settings-connections.png) |

| Host Vault & Egress Firewall (`boobox-proxy`) |
|---|
| ![Secrets and Network Settings](docs/screenshots/settings-secrets-network.png) |
---

## Requirements

- **Apple Silicon Mac** running **macOS 15+**
- **Swift 6** (Xcode or Apple Command Line Tools)
- **Ghostty.app** installed at `/Applications/Ghostty.app` (for bundled `terminfo` and shell integration assets copied by `bundle-app.sh`)
- **Docker** *(optional, build-time only)* if you want to build the Private Linux MicroVM guest assets (`Resources/vm/vmlinux-arm64` and `Resources/vm/rootfs.ext4`)

---

## Build & Install

```bash
git clone https://github.com/apguan/boo_box.git
cd boo_box

# Optional: build the arm64 Linux microVM kernel + Alpine rootfs for Private VM mode (⇧⌘N)
./scripts/build-guest-image.sh

# Build release boo_box.app, sign with Virtualization.framework entitlement, and install `~/.local/bin/boo`
./scripts/bundle-app.sh release

# Launch boo_box
open build/boo_box.app
```

Make sure `~/.local/bin` is on your host shell `PATH` to use the `boo` CLI from anywhere.

---

## CLI Usage (`boo`)

```bash
# Open an instant O(1) ~20 ms CoW overlay sandbox for the current directory (works on 1M+ file trees)
boo
boo .
boo /path/to/repo

# Workspace isolation options
boo --no-env .            # Hide host .env / .env.* secret files (keeps .env.example)
boo --overlay .           # Force instant O(1) ~20 ms CoW overlay mount (default)
boo --clone / --full .    # Force frozen APFS full clone (including node_modules)
boo --slim .              # Force frozen APFS slim clone (skip node_modules & caches)
boo --scratch             # Open an empty scratch sandbox session
# Global Sandbox Environment (~/boo_box/env — shared across all sandboxes)
boo env run '<script>'    # Run any install script inside Seatbelt with HOME=~/boo_box/env
boo env shell             # Open an interactive sandboxed shell targeting ~/boo_box/env
boo tools [--json]        # List auto-discovered toolchain directories & binaries
boo env rm <dir-path>     # Remove a toolchain directory inside ~/boo_box/env
boo env reset             # Wipe and recreate ~/boo_box/env cleanly

# One-time Git + GitHub Host Vault setup for all sandboxes (also in Settings -> Connections)
boo setup-github                # Interactive wizard (fine-grained PAT or host `gh` login)
boo setup-github --token <pat>  # Store a repo-scoped fine-grained PAT in ~/boo_box/vault/
boo setup-github --from-gh      # Import current host `gh auth token` into ~/boo_box/vault/
boo setup-github --status       # Inspect current Git + GitHub sandbox setup
boo setup-github --remove       # Delete GitHub token from Host Vault & disable connection
```
---

## Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| `⌘T` | New macOS Sandbox session |
| Sidebar `📁` / `Pin Folder…` | Pick any host directory to open in an isolated sandbox, or explicitly pin favorite folders to the sidebar (never auto-pinned) |
| `⇧⌘O` | Open host folder in isolated sandbox (CoW overlay or APFS clone) |
| `⇧⌘N` | New Private Linux MicroVM |
| `⌥⌘T` | New Raw Host Shell (unsandboxed) |
| `⌥⌘,` | Configure active sandbox overrides |
| `⌘,` | Global `boo_box` Settings |
| `⌘D` / `⇧⌘D` | Split pane right / down |
| `⌥⌘[` / `⌥⌘]` | Previous / next split pane |
| `⌘P` | Quick Switcher & Command Palette (jump across open/past sessions & actions) |
| `⌘F` / `⌘G` / `⇧⌘G` | In-terminal GPU Find / Next Match / Previous Match |
| `⌘1`–`⌘9` | Jump to open session |
| `⌘B` / `⌥⌘S` | Toggle sidebar / flip sidebar Left ↔ Right |
| `⇧⌘E` / `⇧⌘F` | Rename active session / search sidebar sessions |
| `⇧⌘K` | Reset Private VM to clean state |
| `⌘W` / `⇧⌘W` | Close pane / close session tab (keeps non-empty macOS sandboxes in `PAST`) |
---

## Security Model

- **macOS Sandbox (`sandbox-exec`):** Default-denies reads, existence checks, and writes across `/Users`, `/private/tmp`, `/private/var/folders`, `/Volumes`, and `~/boo_box/vault/`, allowing writes strictly inside the session directory (`~/boo_box/sessions/<id>/`), configured package caches (`~/boo_box/cache`), `~/boo_box/env`, and opted-in CLI configs. Host toolchains (`/opt/homebrew`, `/usr/bin`, etc.) are strictly read-only.
- **CoW Overlay Isolation (`boobox-overlay`):** Lower host directories are opened strictly `O_RDONLY | O_NOFOLLOW` with canonical path containment; all mutations land in `.overlay/upper/` and `.overlay/whiteouts.json`. Direct sandbox TCP access to the daemon's localhost port is kernel-blocked by Seatbelt (only the macOS kernel NFS client connects), and one-shot export tokens + 128-bit HMAC handles prevent cross-session access.
- **Host Secret Vault (`boobox-proxy`):** Real secret values live in the Seatbelt-denied Host Vault (`~/boo_box/vault/`, `0700`/`0600`, zero plaintext in `config.json`) or 1Password (`op://`) and are pushed to `boobox-proxy` over a `0600` Unix socket (`~/boo_box/run/proxy-ctl.sock`). Sandboxes only see `bbx_ph_...` phantom tokens; sending a phantom token to an unauthorized host or from an unauthorized session is blocked (`403`) and logged.
- **Terminal Escape Hardening:** `clipboard-read = ask` is enforced via Ghostty's managed override; clicking `http(s)` links in sandboxed tabs displays a dismissible prompt (and non-web URL schemes always confirm before launching external macOS handlers).
- **Private Linux MicroVM:** Hardware-virtualized via Apple `Virtualization.framework` with no host filesystem mounts by default and optional `Offline` mode (omits the virtual NIC completely).
