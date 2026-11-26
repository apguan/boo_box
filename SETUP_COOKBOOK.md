# `boo_box` Setup Cookbook & Sandbox Gotchas

> **For AI Coding Agents (Claude Code, OMP, Codex, OpenCode, Gemini CLI):**
> If a user asked you to read this cookbook and set up `boo_box` for them, follow **[Section 1: Agent-Guided Interactive Onboarding](#1-agent-guided-interactive-onboarding)** step by step. Ask the user the short question set **first** (never assume they want to share host credentials or SSH keys), inspect their Mac read-only, then run only the steps they approve.

---

## Why Setup Matters in a Sandboxed Terminal

Every macOS Sandbox tab in `boo_box` runs inside a default-deny Apple Seatbelt profile (`sandbox-exec`):
- **Blocked by design:** macOS Keychain, `~/.ssh`, `~/Desktop`, `~/Documents`, `/private/tmp`, `/private/var/folders`, writes to `/opt/homebrew`, and writes to your real host repos.
- **Result:** Tools that normally store logins in macOS Keychain (`gh`, `vercel`, `npm`) or expect global `~/.gitconfig` / `~/.mcp-auth` need a **one-time setup** so every future sandbox tab works seamlessly with zero per-tab re-login.

All tokens configured through **`Settings (⌘,) → Connections`** or **`boo setup-github`** are stored exclusively in the host-only **Host Vault** (`~/boo_box/vault/`, `0700`/`0600`, kernel-denied by Seatbelt, zero Keychain ACL modals across rebuilds/updates) — **never plaintext in `~/boo_box/config.json`**.

---

## 1. Agent-Guided Interactive Onboarding

### Step A — Inspect the User's Mac (Read-Only, Zero Secret Printing)
Run these safe checks first so you can pre-select smart defaults (never print raw secret values!):

```bash
# 1. Installed coding agents & existing MCP configs
for p in ~/.omp/agent/mcp.json ~/.claude.json ~/.config/opencode/opencode.json ~/.codex/config.toml ~/.gemini/settings.json; do
  [ -e "$p" ] && echo "FOUND_AGENT_CFG: $p"
done
for bin in omp claude opencode codex gemini gh vercel wrangler fly supabase; do
  command -v "$bin" >/dev/null 2>&1 && echo "FOUND_CLI: $bin ($(command -v "$bin"))"
done

# 2. Current Git & GitHub state (safe — never prints tokens)
git config --global --get user.name  || echo "GIT_NAME=<unset>"
git config --global --get user.email || echo "GIT_EMAIL=<unset>"
gh auth status 2>&1 | sed 's/Token:.*/Token: <redacted>/' || true
ssh-add -l 2>&1 || true

# 3. Current boo_box setup status
boo setup-github --status 2>/dev/null || true
boo tools 2>/dev/null || true
```

### Step B — Ask the User These 4 Quick Setup Questions
Present concise choices with clear security tradeoffs (use your harness's question UI or a short numbered prompt):
1. **Sandbox Shell Auth & 1-Click OAuth Agent MCP Servers (`Settings (⌘,) → Connections`):**
   - **Sandbox Shell Auth (GitHub):** Click **`Connect`** (or run `boo setup-github --from-gh`) — uses existing host `gh` OAuth instantly or launches GitHub browser OAuth (`gh auth login --web`), saves `GH_TOKEN` to `~/boo_box/vault/connections.json` (`0600`, Seatbelt-denied), and hot-reloads `git` / `gh` auth into **all open and new sandboxes immediately** via `preexec` + self-sourcing `~/.boobox-bin/{git,gh,boobox-git-cred}` shims. *(Optional: click **Paste Token** or run `boo setup-github --token <pat>` for a repo-scoped fine-grained PAT.)*
   - **Agent MCP Servers (Native OAuth 2.1 + PKCE + Dynamic Client Registration):** Click **`Connect`** on **Notion**, **Linear**, **Vercel**, **Supabase**, **Stripe**, **Sentry**, **Cloudflare**, **Figma**, or **Slack** — opens the official browser OAuth consent page directly, exchanges tokens via loopback `127.0.0.1`, stores them in `~/boo_box/vault/oauth.json`, and writes native OAuth credentials straight into **OMP** (`~/.omp/agent/agent.db`), **OpenCode** (`~/.local/share/opencode/mcp-auth.json`), and selected agent MCP configs (**Claude Code**, **Codex**, **Gemini CLI**). Zero API keys or manual copy-pasting!

2. **No-Login MCP Tools:**
   - Enable **Context7**, **Cloudflare Docs**, **Playwright**, or **Sequential Thinking** in 1 click inside **`Settings → Connections → Agent MCP Servers`**.

3. **LLM Provider Auth:**
   - If the user uses OAuth logins inside their coding agent (Claude / OMP / Codex / OpenCode), enabling their agent config folder in **`Settings → Sandbox Access`** carries auth automatically.
   - If the user uses raw LLM API keys (**Anthropic**, **OpenAI**, **OpenRouter**, **Gemini**), add them in **`Settings → Secrets & Network`** so keys stay in the Host Vault (`~/boo_box/vault/`) or 1Password (`op://`) and sandboxes only ever receive worthless `bbx_ph_…` phantom tokens swapped by `boobox-proxy`.
4. **Outbound Network Posture & Global Sandbox Tools:**
   - **Network mode (`Settings → Secrets & Network`):** `Full (Vault Protected)` *(default)*, `Dev Allowlist` *(locks Seatbelt to `boobox-proxy` + curated dev domains; blocked hosts pop a 1-click Allow toast in the tab header)*, or `Offline (Air-gapped)`.
   - **Global Sandbox Toolchains (`~/boo_box/env`):** Install any sandbox-writable CLIs via `boo env run '<install-cmd>'` so they can self-update without touching read-only `/opt/homebrew`.

### Step C — Apply Approved Configuration & Verify
- **GitHub (if chosen via CLI instead of clicking `Connect` in Settings):**
  ```bash
  # One-shot OAuth import from host `gh`:
  boo setup-github --from-gh
  # Or interactive scoped PAT:
  boo setup-github
  ```
- **Verify inside a fresh sandbox tab (`⌘T` or `boo .`):**
  ```bash
  git config user.name && git config user.email
  gh auth status
  ```
- **Live hot-reload:** Connecting or disconnecting GitHub / Connections updates `.boobox-env.sh` across **every open sandbox immediately** — your next `git` / `gh` command (even inside already-open tabs or running coding agents) picks up the change automatically with zero restart.

---

## 2. Sandbox Gotchas & How `boo_box` Solves Them

### 1. Why `gh` / `git push` asks to log in again inside a sandbox
- **Cause:** On macOS, `gh` stores its OAuth token in **macOS Keychain**, which Seatbelt blocks inside sandboxes.
- **Fix:** Run `boo setup-github` once (or connect **GitHub** in **`Settings (⌘,) → Connections`**). This stores `GH_TOKEN` in the Seatbelt-denied Host Vault (`~/boo_box/vault/connections.json`), wires a sandbox-aware credential helper in host `~/.gitconfig`, injects `GIT_CONFIG_COUNT` + `GH_TOKEN` into each sandbox's `0600` `~/.boobox-env.sh`, and installs self-sourcing `~/.boobox-bin/{git,gh,boobox-git-cred}` shims that hot-reload tokens on every command.
- **Gotcha:** Never run `gh auth setup-git` *inside* a sandbox when `allowHostGitConfig` is enabled — host `~/.gitconfig` is read-only under Seatbelt. Always run `boo setup-github` (or click **Connect** in Settings) on the host once.

### 2. Why `brew upgrade` / `omp update` fails with `/opt/homebrew/Cellar is not writable`
- **Cause:** Host toolchains (`/opt/homebrew`, `/usr/bin`, `~/.bun`, `fnm`) are intentionally mounted **read-only** so a compromised agent cannot backdoor binaries on your Mac.
- **Fix (2 options):**
  1. Run Homebrew upgrades from a host terminal or Raw Host tab (**`⌥⌘T`**).
  2. Install self-updating CLIs into the **Global Sandbox Environment** (`~/boo_box/env`, shared RW across sandboxes and placed ahead of `/opt/homebrew` on `PATH`):
     ```bash
     boo env run 'curl -fsSL https://astral.sh/uv/install.sh | sh'
     boo env run 'npm install -g @openai/codex'
     ```

### 3. Phantom Tokens (`boobox-proxy`) vs Direct Host Vault Connections
- **`boobox-proxy` phantom tokens (`bbx_ph_...`)** rewrite HTTP headers/paths on **Base-URL reverse-proxy routes** (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENROUTER_BASE_URL`, `GOOGLE_GEMINI_BASE_URL`) without TLS MITM. Real LLM keys **never** exist inside the sandbox.
- **Direct HTTPS CLIs (`gh`, `git push`)** use TLS `CONNECT` tunnels where `boobox-proxy` cannot rewrite encrypted HTTP headers. Those use **`Settings → Connections → Sandbox Shell Auth`** (stored in Seatbelt-denied `~/boo_box/vault/`, injected into `0600` `.boobox-env.sh`, and automatically withheld on `None (0 secrets)` sandboxes via `⌥⌘,`).
- **Best practice:** Use **fine-grained, repo-scoped tokens** for shell auth so blast radius stays minimal.

### 4. MCP OAuth Logins Across Sandboxes
- Remote HTTP MCPs (Notion, Linear, Slack, Figma, Sentry, Cloudflare, Supabase, Vercel, Stripe) use browser OAuth and cache tokens under `~/.mcp-auth` and your agent's config folder (`~/.omp`, `~/.claude`, `~/.config/opencode`, `~/.codex`, `~/.gemini`).
- `boo_box` automatically mounts `~/.mcp-auth` and enabled agent config folders read-write into sandboxes, so once you connect an MCP via **`Settings (⌘,) → Connections → Agent MCP Servers`** and complete browser sign-in once, every sandbox shares the login.

### 5. Instant CoW Overlay (`boobox-overlay`), APFS Clones & `rm -rf node_modules`
- **Default — Instant CoW Overlay (`~20 ms`, $O(1)$):** By default (`Settings → General → Workspace isolation`), `boo .` and `⇧⌘O` mount your project via `boobox-overlay` (localhost NFSv3 Copy-on-Write). Even a 1M+ file monorepo opens in `~20 ms` with **0 extra SSD blocks**; every edit/create/delete lands strictly inside `~/boo_box/sessions/<id>/.overlay/` while the host folder is read-only (`O_RDONLY | O_NOFOLLOW`). Overlay sandboxes automatically set `core.checkStat=minimal` + `core.trustctime=false` via `GIT_CONFIG_COUNT` so `git status` runs in `~0.5s` on 350k-file repos without editing your repo's `.git/config`.
- **Optional — APFS Full / Slim Clone (`--clone`, `--full`, `--slim`):** If you want a frozen point-in-time snapshot with raw local APFS syscall speed, switch to **APFS Full Clone** in `Settings → General` or pass `boo --clone .` / `boo --slim .`. Unchanged APFS `clonefile(2)` files share extents (`0 B` extra SSD data even if `du` double-counts apparent size), and repeat opens pop a background warm clone in `<1 s`.
- **Fast `rm -rf` and `cp -R` inside sandboxes:** `boo_box` puts read-only shims in `~/.boobox-bin` ahead of `/bin`:
  - `rm -rf <dir>` atomically moves directories into `$TMPDIR/.rm-trash/` and reaps in the background (`<5 ms` even for 300k-file `node_modules`; opt out with `BOOBOX_SYNC_RM=1`).
  - `cp -R <src> <new-dst>` uses APFS `cp -c` copy-on-write (`0` extra blocks; opt out with `BOOBOX_NO_COW_CP=1`).
  - `mktemp` redirects macOS `/usr/bin/mktemp` (which ignores `$TMPDIR` by default!) into the session's `.tmp/` so `bun install` / `postinstall` scripts never fail with `/var/folders/...: Operation not permitted`. *(Caveat: native Swift/Foundation binaries calling `NSTemporaryDirectory()` bypass `mktemp` and still resolve `/var/folders/...`.)*

### 6. Live Hot-Reload & Detached `booboxd` Sessions
- **`Connections` (`GitHub` / `GH_TOKEN`)** and **`boobox-proxy` egress allowlist** changes apply **live to already-open tabs and running agents** with zero restart (`preexec` + self-sourcing shims). Changes to **`Sandbox Access`** (Seatbelt mounts) or **`Ephemeral Setup`** apply to every new tab, or press **`⌥⌘,`** → **`Save & Restart Sandbox`** on an existing tab.
- With **`Persistent detached sessions (booboxd)`** enabled (default in `Settings → General`), quitting or auto-updating `boo_box.app` **detaches** without killing running shells or coding agents, keeps `boobox-proxy` and `boobox-overlay` mounts alive, and reattaches with 128 KiB scrollback replay on relaunch. Explicitly closing a pane (`⌘W`) or tab (`⇧⌘W`) terminates its processes cleanly (unmounting overlay sessions while keeping `.overlay/upper/` for instant `PAST` resume).

### 7. Common Shortcuts & Editor Tip
- **`⌘F` / `⌘G` / `⇧⌘G`**: In-terminal GPU scrollback Find / Next / Previous (`Ctrl+F` stays readline forward-char).
- **`⌘P`**: Quick Switcher & Command Palette (jump across open/past sessions, Connections, Settings, and actions).
- **`⌘K`**: Clear Screen.
- **`⌘W` / `⇧⌘W`**: Close active split pane / close entire session tab.
- **Cursor IDE `code .` opening Agents Window instead of Editor:** Cursor 3 added `--classic` (`alias code='command code --classic'`), or set **Open Agents Window on Startup → Off** in Cursor Settings.
