# `boo_box` Setup Cookbook & Sandbox Gotchas

> **For AI Coding Agents (Claude Code, OMP, Codex, OpenCode, Gemini CLI):**
> If a user asked you to read this cookbook and set up `boo_box` for them, follow **[Section 1: Agent-Guided Interactive Onboarding](#1-agent-guided-interactive-onboarding)** step by step. Ask the user the short question set **first** (never assume they want to share host credentials or SSH keys), inspect their Mac read-only, then run only the steps they approve.

---

## Why Setup Matters in a Sandboxed Terminal

Every macOS Sandbox tab in `boo_box` runs inside a default-deny Apple Seatbelt profile (`sandbox-exec`):
- **Blocked by design:** macOS Keychain, `~/.ssh`, `~/Desktop`, `~/Documents`, `/private/tmp`, `/private/var/folders`, writes to `/opt/homebrew`, and writes to your real host repos.
- **Result:** Tools that normally store logins in macOS Keychain (`gh`, `vercel`, `npm`) or expect global `~/.gitconfig` / `~/.mcp-auth` need a **one-time setup** so every future sandbox tab works seamlessly with zero per-tab re-login.

All tokens configured through **`Settings (⌘,) → Connections`** or **`boo setup-github`** are stored encrypted in **macOS Keychain** (`dev.boo-box.connections` / `dev.boo-box.secrets`) — **never plaintext in `~/boo_box/config.json`**.

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

### Step B — Ask the User These 5 Setup Questions
Present concise choices with clear security tradeoffs (use your harness's question UI or a short numbered prompt):

1. **GitHub & `git push` inside sandboxes:**
   - **Option 1 (Recommended — Scoped Fine-Grained PAT):** Create a repo-scoped PAT (`Contents` + `Pull requests` RW) at `https://github.com/settings/personal-access-tokens/new`, then run `boo setup-github --token <pat>` (stored encrypted in macOS Keychain).
   - **Option 2 (Fastest — Reuse Host `gh` CLI Login):** Run `boo setup-github --from-gh` (imports your existing `gh auth token` into Keychain, configures `~/.gitconfig` + `gh auth setup-git`; carries your full host `gh` scopes).
   - **Option 3 (SSH Agent Forwarding):** Enable `Allow Host SSH Agent` + `Allow Read-Only Host ~/.gitconfig` in `Settings → Sandbox Access` (private keys never enter the sandbox; requires SSH remotes or `insteadOf`).
   - **Option 4 (Read-Only / No Push):** Skip GitHub auth — sandboxes cannot push commits or create PRs.

2. **LLM Provider API Keys (Proxy-Protected Phantom Tokens):**
   - Which providers do you use via API keys (**Anthropic**, **OpenAI**, **OpenRouter**, **Gemini**)?
   - Direct the user to paste keys in **`Settings (⌘,) → Connections → LLM Providers`** (or **`Secrets & Network`**). Real keys stay strictly on the host in Keychain; sandboxes only receive worthless `bbx_ph_...` phantom tokens swapped by `boobox-proxy` on bound provider hosts.
   - *(Note: if the user authenticates their coding agent via OAuth — e.g. Claude/OMP/Codex login — their shared agent config folder in `Settings → Sandbox Access` already carries auth automatically.)*

3. **Cloud & Dev CLIs (Keychain-Backed):**
   - Which extra CLIs do you use inside sandboxes?
   - Supported 1-click in **`Settings (⌘,) → Connections → Apps & CLIs`**: **Cloudflare (`wrangler`)**, **Vercel** (supports 1-click local import), **Supabase**, **Linear**, **Stripe**, **Sentry**, **Slack**, **npm** (supports `~/.npmrc` import), **Fly.io** (supports `~/.fly/config.yml` import), **Exa**, **Context7**, **Firecrawl**.

4. **MCP Servers (1-Click Multi-Agent Sync):**
   - Which MCP servers do you want synced into your installed coding agents (**OMP**, **OpenCode**, **Claude Code**, **Codex**, **Gemini CLI**)?
   - Built-in 1-click catalog in **`Settings (⌘,) → Connections → MCP Servers`**:
     - **OAuth HTTP (browser login, persisted via shared `~/.mcp-auth`):** Notion, Linear, Slack, Figma, Sentry, Cloudflare Docs, Supabase, Vercel, Stripe, Context7, OpenRouter.
     - **Local Stdio (`npx`):** GitHub MCP, Playwright, Exa Search, Sequential Thinking.

5. **Outbound Network Posture & Global Sandbox Tools:**
   - **Network mode (`Settings → Secrets & Network`):**
     - `Full (Vault Protected)` *(default — unrestricted dev traffic, LLM keys still protected by phantom tokens)*
     - `Dev Allowlist` *(locks Seatbelt to `boobox-proxy` + curated LLM/npm/PyPI/GitHub/Cloudflare domains; blocked requests pop a 1-click **`Allow (this tab)` / `Allow globally`** toast in the tab header)*
     - `Offline (Air-gapped)` *(blocks all remote traffic)*
   - **Global Sandbox Toolchains (`~/boo_box/env`):** Want to install any sandbox-writable CLIs via `boo env run '<install-cmd>'` (e.g. `bun`, `uv`, `omp`, `claude`, `codex`) so they can self-update without touching read-only `/opt/homebrew`?

### Step C — Apply Approved Configuration & Verify
- **GitHub (if chosen):**
  ```bash
  # Option 1 (fine-grained PAT — ask user to run or pass via env so it stays out of chat logs):
  boo setup-github
  # Option 2 (one-shot import from host `gh`):
  boo setup-github --from-gh
  ```
- **Verify inside a fresh sandbox tab (`⌘T` or `boo .`):**
  ```bash
  git config user.name && git config user.email
  gh auth status
  ```
- **Remind the user:** Already-open tabs keep their launch environment; open a new tab (`⌘T`) or press **`⌥⌘,`** → **`Save & Restart Sandbox`** to pick up new connections immediately.

---

## 2. Sandbox Gotchas & How `boo_box` Solves Them

### 1. Why `gh` / `git push` asks to log in again inside a sandbox
- **Cause:** On macOS, `gh` stores its OAuth token in **macOS Keychain**, which Seatbelt blocks inside sandboxes. Also `allowHostGitConfig` is off by default.
- **Fix:** Run `boo setup-github` once (or connect **GitHub** in **`Settings (⌘,) → Connections`**). This stores `GH_TOKEN` in `boo_box`'s Keychain (`dev.boo-box.connections`), writes `user.name`/`user.email`/`gh auth setup-git` to your host `~/.gitconfig`, mounts `~/.gitconfig` read-only, and injects `GH_TOKEN` via each sandbox's private `0600` `~/.boobox-env.sh`.
- **Gotcha:** Never run `gh auth setup-git` *inside* a sandbox when `allowHostGitConfig` is enabled — host `~/.gitconfig` is read-only under Seatbelt. Always run `boo setup-github` (or `gh auth setup-git`) on the host once.

### 2. Why `brew upgrade` / `omp update` fails with `/opt/homebrew/Cellar is not writable`
- **Cause:** Host toolchains (`/opt/homebrew`, `/usr/bin`, `~/.bun`, `fnm`) are intentionally mounted **read-only** so a compromised agent cannot backdoor binaries on your Mac.
- **Fix (2 options):**
  1. Run Homebrew upgrades from a host terminal or Raw Host tab (**`⌥⌘T`**).
  2. Install self-updating CLIs into the **Global Sandbox Environment** (`~/boo_box/env`, shared RW across sandboxes and placed ahead of `/opt/homebrew` on `PATH`):
     ```bash
     boo env run 'curl -fsSL https://astral.sh/uv/install.sh | sh'
     boo env run 'npm install -g @openai/codex'
     ```

### 3. Phantom Tokens (`boobox-proxy`) vs Direct Keychain Connections
- **`boobox-proxy` phantom tokens (`bbx_ph_...`)** rewrite HTTP headers/paths on **Base-URL reverse-proxy routes** (`ANTHROPIC_BASE_URL`, `OPENAI_BASE_URL`, `OPENROUTER_BASE_URL`, `GOOGLE_GEMINI_BASE_URL`) without TLS MITM. Real LLM keys **never** exist inside the sandbox.
- **Direct HTTPS CLIs (`gh`, `git push`, `vercel`, `wrangler`, `stripe`)** use TLS `CONNECT` tunnels where `boobox-proxy` cannot rewrite encrypted HTTP headers. Those use **`Settings → Connections`** (encrypted in macOS Keychain, injected into `0600` `.boobox-env.sh`, and automatically withheld on `None (0 secrets)` sandboxes via `⌥⌘,`).
- **Best practice:** Use **fine-grained, repo-scoped or test-mode tokens** for Connections so blast radius stays minimal.

### 4. MCP OAuth Logins Across Sandboxes
- Remote HTTP MCPs (Notion, Linear, Slack, Figma, Sentry, Cloudflare, Supabase, Vercel, Stripe) use browser OAuth and cache tokens under `~/.mcp-auth` and your agent's config folder (`~/.omp`, `~/.claude`, `~/.config/opencode`, `~/.codex`, `~/.gemini`).
- `boo_box` automatically mounts `~/.mcp-auth` and enabled agent config folders read-write into sandboxes, so once you install an MCP via **`Settings (⌘,) → Connections → 1-Click MCP Servers`** and complete browser sign-in once, every sandbox shares the login.

### 5. Monorepo APFS Cloning, `du` Storage Numbers & `rm -rf node_modules`
- **Apparent `du` vs real SSD usage:** macOS `du` double-counts APFS `clonefile(2)` shared extents. Unchanged cloned files (e.g. a 2 GB `.git` packfile + `node_modules`) use **`0 B` of extra SSD data** — real extra storage per session is only `.home`/`.tmp` (~10–20 MB), files you edit, and ~`0.5–1 KB`/inode of APFS B-tree metadata.
- **Cold clone speed on huge monorepos (300k+ files):** APFS kernel `clonefile(2)` allocates new inodes serially (~30–40s for 350k+ files in `node_modules`). `boo_box` keeps a background **warm pool** so repeat `boo .` / `⌘T` opens pop in ~1s via atomic `rename(2)` + Git delta sync. For instant cold clones without `node_modules`, run `boo --slim .` (or enable **Slim clone** in `Settings → General`).
- **Fast `rm -rf` and `cp -R` inside sandboxes:** `boo_box` puts read-only shims in `~/.boobox-bin` ahead of `/bin`:
  - `rm -rf <dir>` atomically moves directories into `$TMPDIR/.rm-trash/` and reaps in the background (`<5 ms` even for 300k-file `node_modules`; opt out with `BOOBOX_SYNC_RM=1`).
  - `cp -R <src> <new-dst>` uses APFS `cp -c` copy-on-write (`0` extra blocks; opt out with `BOOBOX_NO_COW_CP=1`).
  - `mktemp` redirects macOS `/usr/bin/mktemp` (which ignores `$TMPDIR` by default!) into the session's `.tmp/` so `bun install` / `postinstall` scripts never fail with `/var/folders/...: Operation not permitted`. *(Caveat: native Swift/Foundation binaries calling `NSTemporaryDirectory()` bypass `mktemp` and still resolve `/var/folders/...`.)*

### 6. Already-Open Tabs vs New Tabs & Detached `booboxd` Sessions
- Changing **`Connections`**, **`Sandbox Access`**, or **`Ephemeral Setup`** applies to every **new** tab immediately. For an **already-open** tab, press **`⌥⌘,`** → **`Save & Restart Sandbox`** (proxy egress allowlist changes apply live with zero restart!).
- With **`Persistent detached sessions (booboxd)`** enabled (default in `Settings → General`), quitting or auto-updating `boo_box.app` **detaches** without killing running shells or coding agents, keeps `boobox-proxy` alive on the same port, and reattaches with 128 KiB scrollback replay on relaunch. Explicitly closing a pane (`⌘W`) or tab (`⇧⌘W`) terminates its processes cleanly.

### 7. Common Shortcuts & Editor Tip
- **`⌘F` / `⌘G` / `⇧⌘G`**: In-terminal GPU scrollback Find / Next / Previous (`Ctrl+F` stays readline forward-char).
- **`⌘P`**: Quick Switcher & Command Palette (jump across open/past sessions, Connections, Settings, and actions).
- **`⌘K`**: Clear Screen.
- **`⌘W` / `⇧⌘W`**: Close active split pane / close entire session tab.
- **Cursor IDE `code .` opening Agents Window instead of Editor:** Cursor 3 added `--classic` (`alias code='command code --classic'`), or set **Open Agents Window on Startup → Off** in Cursor Settings.
