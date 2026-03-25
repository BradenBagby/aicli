# AI CLI

This repository defines a local, AI-agnostic harness so different AI TUIs
(Claude, Codex, Gemini, etc.) can operate against the same system.

## Scope

- shared tools
- agent definitions
- shared memory vault
- system prompts/contracts
- infrastructure hooks/scripts

## Layout

- `seed/bin/aih`: Harness CLI source for initializing and validating shared state.
- `seed/bin/ralph`: Loop runner for one-task-per-run automation across supported CLIs.
- `seed/tools/bin/vault`: Canonical memory vault CLI (file-native markdown+YAML notes).
- `seed/systems/prompts/ralph.md`: Canonical Ralph loop prompt synced to `~/.ai/systems/prompts/ralph.md`.
- `setup.sh`: Root bootstrap orchestrator for new-system provisioning.
- `scripts/setup/*.sh`: Per-domain installers (`plugins.sh`, `agents.sh`, etc.).
- `seed/`: Repository seed bundle copied into `$AI_HOME` during setup.
- `docs/architecture.md`: Canonical architecture and integration contract.

Bootstrap contract:

- `~/.ai/cortex.md` is loaded first at session start.
- contracts are loaded lazily from `~/.ai/systems/contracts/*.md` as needed.

## Quick Start (Recommended)

Do this in order:

1. Clone this repo and `cd` into it.
2. Choose a git mode — **bridge** (recommended, no SSH keys needed) or **SSH**:

   **Bridge mode** (host runs git, container calls it via socket):
   ```bash
   brew install socat
   ```

   **SSH mode** (traditional, git runs inside container with your keys):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/ai_ed25519 -C "ai-sandbox" -N ""
   # then add ~/.ssh/ai_ed25519.pub to your GitHub/GitLab account
   ```

3. Build the image:
   ```bash
   docker build --build-arg GITCONFIG=$(base64 -i ~/.gitconfig) -t sandbox .
   ```
4. Copy the `sandbox()` function from [Run Container](#run-container) into your shell startup file (`~/.bashrc`, `~/.zshrc`, or `~/.profile`). If using bridge mode, also set `AICLI_HOME`.
5. Source your startup file (for example, `source ~/.zshrc`).
6. In your terminal, navigate to the project you want mounted into `/workspace`.
7. Run:
   ```bash
   sandbox --bridge   # bridge mode
   sandbox --ssh      # SSH mode
   sandbox            # auto-detect (bridge if socket exists, else SSH)
   ```

Do not run `./setup.sh` manually for normal use. The container entrypoint runs the required setup automatically when `sandbox` starts.

## Persistent Memory (engram)

The harness uses a two-layer memory system:

- **Vault** (`~/.ai/memory`) — canonical, file-native markdown notes with YAML frontmatter. Source of truth.
- **engram** (`~/.ai/memory/engram`) — supplemental memory layer for session summaries and full-text search across past sessions.

`vault` handles durable structured records. `engram` adds searchable session memory with MCP integration so agents can save and retrieve context automatically.

engram is wired as an MCP server in all supported clients (Claude, OpenCode, Gemini, Codex) and provides 13 tools including `mem_save`, `mem_search`, `mem_context`, and `mem_session_summary`.

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ENGRAM_DATA_DIR` | `~/.ai/memory/engram` | engram SQLite database location |

`ENGRAM_DATA_DIR` is set automatically by the container entrypoint. The path is under `~/.ai/memory` which is persisted by the volume mount.

### Usage

Search memories from the CLI:

```bash
engram search "bootstrap contract"
```

Browse all memories interactively:

```bash
engram tui
```

The MCP server is started automatically by each AI client when needed. No manual initialization required.

## Shared Documentation Vault

Project documentation is expected to live in a separate Obsidian vault repo.

Set `DOC_VAULT_ROOT` to your local documentation vault path:

```bash
export DOC_VAULT_ROOT="/path/to/your/documentation/vault"
```

`DOC_VAULT_ROOT` is the global documentation vault location. It is separate from the
project repo you are actively working in.
Project documentation folder names are determined by running `docslug` in the working
project repo. Documentation generation should fail if either `DOC_VAULT_ROOT` is unset
or `docslug` is unavailable.

Add that export to your shell startup file (`~/.bashrc`, `~/.zshrc`, or `~/.profile`) so tooling can consistently find the shared docs vault.

## Container Workflow

### Prerequisites

- Docker installed and available in your shell
- **Bridge mode**: `brew install socat` + set `AICLI_HOME` (see [Host Bridge](#host-bridge))
- **SSH mode**: dedicated SSH keys — see the [SSH Keys](#ssh-keys) section
- Optional: base64 support if passing `GITCONFIG` at build time

### Build Image

```bash
docker build --build-arg GITCONFIG=$(base64 -i ~/.gitconfig) -t sandbox .
```

Notes:

- `TZ` controls container timezone.
- `GITCONFIG` is optional; omit it if you do not want to inject git config.

### Run Container

Add this helper to `~/.bashrc`, `~/.zshrc`, or `~/.profile`.

Set `AICLI_HOME` to the path where you cloned this repo:

```bash
export AICLI_HOME="$HOME/path/to/aicli"  # update to your clone path

# Directories sandbox is allowed to mount. Subdirectories are also permitted.
SANDBOX_ALLOWED_WORKSPACES=(
  "$HOME/wavv-docker/core"
  "$HOME/wavv-docker/prisma"
)

sandbox() {
  # Workspace allowlist check
  local current_dir
  current_dir="$(pwd)"
  local allowed=false
  for allowed_dir in "${SANDBOX_ALLOWED_WORKSPACES[@]}"; do
    if [[ "$current_dir" == "$allowed_dir" || "$current_dir" == "$allowed_dir/"* ]]; then
      allowed=true
      break
    fi
  done
  if [[ "$allowed" == false ]]; then
    echo "[sandbox] ERROR: '$current_dir' is not an allowed workspace."
    echo "[sandbox] Allowed: ${SANDBOX_ALLOWED_WORKSPACES[*]}"
    return 1
  fi

  local mode=""
  for arg in "$@"; do
    case "$arg" in --bridge) mode=bridge ;; --ssh) mode=ssh ;; esac
  done
  if [[ -z "$mode" ]]; then
    mode=bridge
  fi

  local extra_mounts=() bridge_pid=""

  if [[ "$mode" == "bridge" ]]; then
    socat TCP-LISTEN:57421,fork,reuseaddr \
      EXEC:"bash '$AICLI_HOME/scripts/host-bridge-handler.sh' '$(pwd)'" &
    bridge_pid=$!
    sleep 0.3
    echo "[sandbox] Bridge started (pid $bridge_pid) in $(pwd)"
  else
    extra_mounts+=(
      -v "$HOME/.ssh/ai_ed25519:/home/ai/.ssh/id_ed25519:ro"
      -v "$HOME/.ssh/ai_ed25519.pub:/home/ai/.ssh/id_ed25519.pub:ro"
      -v "$HOME/.ssh/known_hosts:/home/ai/.ssh/known_hosts:ro"
    )
    echo "[sandbox] SSH mode"
  fi

  # Load .env file if it exists in the aicli repo
  local env_file_args=()
  if [[ -f "$AICLI_HOME/.env" ]]; then
    env_file_args+=(--env-file "$AICLI_HOME/.env")
  fi

  # Determine command: "sandbox --linear" runs the linear-worker service
  local container_cmd="/bin/bash"
  for arg in "$@"; do
    case "$arg" in
      --linear) container_cmd="linear-worker" ;;
    esac
  done

  docker network create sandbox >/dev/null 2>&1 || true
  docker run --rm -it \
    --network sandbox \
    "${env_file_args[@]}" \
    -v "sandbox_home:/home/ai" \
    -v "sandbox_ai:/home/ai/.ai" \
    -v "sandbox_cache:/home/ai/.cache" \
    -v "sandbox_claude:/home/ai/.claude" \
    -v "sandbox_codex:/home/ai/.codex" \
    -v "sandbox_config:/home/ai/.config" \
    -v "sandbox_cursor:/home/ai/.cursor" \
    -v "sandbox_gemini:/home/ai/.gemini" \
    -v "sandbox_local:/home/ai/.local" \
    "${extra_mounts[@]}" \
    -v "$(pwd):/workspace" \
    --workdir /workspace \
    sandbox \
    $container_cmd

  # Cleanup bridge when docker exits
  if [[ -n "$bridge_pid" ]]; then
    kill "$bridge_pid" 2>/dev/null
    echo "[sandbox] Bridge stopped"
  fi
}
```

On startup, the container entrypoint runs harness setup and client config merge:

- `setup.sh` (default components)
- `setup.sh clients`

### Security Note

The default CLI functions configured in the image use permissive flags (`--yolo`,
`--dangerously-*`). Treat this container as an untrusted automation environment,
not a hardened production boundary.

### Shell Launch Functions

These are the shell functions to launch the various tui:

```bash
agent() { TID="$(openssl rand -hex 24)" PROVIDER=cursor command agent --yolo "$@"; }
cursor() { TID="$(openssl rand -hex 24)" PROVIDER=cursor command agent --yolo "$@"; }
claude() { TID="$(openssl rand -hex 24)" PROVIDER=claude command claude --dangerously-skip-permissions "$@"; }
codex() { TID="$(openssl rand -hex 24)" PROVIDER=codex command codex --dangerously-bypass-approvals-and-sandbox "$@"; }
gemini() { TID="$(openssl rand -hex 24)" PROVIDER=gemini command gemini --yolo "$@"; }
kilo() { auth_file="$HOME/.local/share/kilo/auth.json"; mkdir -p "$(dirname "$auth_file")"; if [ -f "$auth_file" ] && grep -q APIKEY "$auth_file"; then [ -z "${MINIMAX_API_KEY:-}" ] && read -s -p "MiniMax API key: " MINIMAX_API_KEY && echo; sed -i "s/APIKEY/$MINIMAX_API_KEY/g" "$auth_file"; fi; TID="$(openssl rand -hex 24)" PROVIDER=kilo command kilo "$@"; }
opencode() { auth_file="$HOME/.local/share/opencode/auth.json"; mkdir -p "$(dirname "$auth_file")"; if [ -f "$auth_file" ] && grep -q APIKEY "$auth_file"; then [ -z "${MINIMAX_API_KEY:-}" ] && read -s -p "MiniMax API key: " MINIMAX_API_KEY && echo; sed -i "s/APIKEY/$MINIMAX_API_KEY/g" "$auth_file"; fi; TID="$(openssl rand -hex 24)" PROVIDER=opencode command opencode "$@"; }
```

### Ralph Loop

`ralph` runs a prompt-driven execution loop for `claude`, `opencode`, or `kilo`.
It is installed to `~/.ai/bin/ralph` and reads the default prompt from
`~/.ai/systems/prompts/ralph.md`.

Required workspace files (must already exist before running `ralph`):

- `tasks.md`
- `status.md`

Default behavior:

- One task per iteration
- Stops on `Status: done` or `Status: blocked`
- Sets `Status: done` automatically when no unchecked tasks remain
- Per-iteration timeout supported (`--iteration-timeout`, default 600s)

CLI defaults:

- Claude: model `haiku`, output format `json`
- OpenCode: model `minimax/MiniMax-M2.5`
- Kilo: model `minimax/MiniMax-M2.5`

Examples:

```bash
ralph --cli claude --max-iterations 5 --iteration-timeout 30
ralph --cli opencode --max-iterations 5 --iteration-timeout 30
ralph --cli kilo --max-iterations 5 --iteration-timeout 30 -- --auto
```

### Once you have built the sandbox docker image, use sandbox in the following way
```bash
sandbox
```

This command:
- Creates a Docker network named `sandbox` (if it doesn't exist)
- Mounts your SSH keys as read-only volumes
- Shares your current working directory as `/workspace`
- Provides persistent volumes for each AI tool's configuration
- Runs as a non-root user

### Inside the Sandbox

Once inside, you have access to:

- **AI Tools**: `claude`, `codex`, `cursor`, `gemini`, `kilo`, `opencode` (with pre-configured start functions)
- **Memory**: `engram` (persistent session memory, MCP server, TUI — `engram tui`, `engram search`)
- **Package Managers**: `npm`, `pnpm`, `bun`
- **Development Tools**: `git`, `gh` (GitHub CLI), `glab` (GitLab CLI), `python3`, `vim`, `jq`, `ripgrep`
- **Browser Automation**: `agent-browser` (Playwright-backed browser CLI for AI agents)
- **Worktree Management**: `wt` (git worktree helper)
- **Workspace**: Your current directory mounted at `/workspace`

### Git Visualization Tools

#### gitlogue — cinematic git history replay
Replays your commit history as an animated TUI. Defaults to a screensaver-style random commit replay.

```bash
# Replay last 10 commits oldest-first
gitlogue --commit HEAD~10..HEAD --order asc

# Filter by author, loop continuously
gitlogue --author "alice" --loop

# View staged or unstaged changes
gitlogue diff
gitlogue diff --unstaged

# Date range with a theme
gitlogue --after "1 week ago" --theme dracula

# Speed up the replay (default is slow; lower ms = faster)
gitlogue --speed 10
```

#### diffwatch — live file diff TUI
Opens a TUI that watches a directory and shows colored diffs as files are written. Useful for watching what the AI is editing in real time.

```bash
# Watch current directory (non-recursive)
diffwatch

# Watch entire project recursively
diffwatch -p /workspace -r

# Watch a specific path recursively
diffwatch -p /workspace/src -r
```

Press `q` or `Ctrl+C` to exit.

#### gsw (git-status-watch) — live git status stream
Streams a new git status line every time the repo changes, event-driven via inotify (no polling). Also powers the Claude Code status bar GIT column automatically.

```bash
# Continuous watch with formatted output
gsw --format '{branch} +{staged} ~{modified} ?{untracked} ⇡{ahead}⇣{behind}'

# One-shot (current status, then exit)
gsw --once --format '{branch} +{staged} ~{modified} ?{untracked}'

# Include stash count and repo state (merge/rebase/etc.)
gsw --format '{branch} +{staged} ~{modified} ?{untracked} stash:{stash} [{state}]'
```

Format placeholders: `{branch}`, `{staged}`, `{modified}`, `{untracked}`, `{conflicted}`, `{ahead}`, `{behind}`, `{stash}`, `{state}`

#### wt — parallel worktree launcher

Creates N isolated copies of the current repo as git worktrees, each on its own branch, for running multiple agents against the same codebase simultaneously without conflicts.

Folders and branches are named `{short-sha}-v{n}` scoped to the current HEAD, so repeated runs never clobber each other.

**When to use:** spin up multiple worktrees when you want to run several AI agents in parallel on competing implementations of the same feature, then compare and cherry-pick the best result.

```bash
# Create 3 worktrees from current HEAD (e.g. abc1234-v1, abc1234-v2, abc1234-v3)
wt 3

# Each worktree is an independent branch you can work in
cd .worktree/abc1234-v1
claude  # agent 1 works here

cd .worktree/abc1234-v2
claude  # agent 2 works here independently

# Remove all worktrees when done
wt --rm
```

Worktrees are created under `.worktree/` which is automatically added to `.gitignore`.

### Host Bridge

Bridge mode lets the container run git commands on your host machine without SSH keys. The container calls `host-commit`, `host-pull`, etc. — these send requests through a Unix socket to a socat process running on your host, which executes the git command in your actual project directory.

#### Prerequisites

```bash
brew install socat
```

Set `AICLI_HOME` in your shell startup file (alongside the `sandbox()` function):

```bash
export AICLI_HOME="$HOME/path/to/aicli"
```

#### Usage

```bash
cd ~/myproject
sandbox --bridge
# [sandbox] Bridge started (pid 12345) in /Users/you/myproject
```

Inside the container:

```bash
host-status           # git status (runs on host)
host-pull             # git pull
host-commit -m "fix"  # git commit -m "fix"
host-push             # git push
host-diff             # git diff
host-log              # git log
host-git fetch        # any allowlisted subcommand via host-git
host-pr --title "feat: add login" --description "Adds OAuth login"  # open Bitbucket PR
```

#### Allowlisted Commands

Only these commands are permitted through the bridge:

`commit` `pull` `push` `fetch` `status` `log` `diff` `stash` `branch` `pr`

Anything else (e.g. `host-git rebase`) returns an error and is not executed.

#### Bitbucket PRs

`host-pr` creates a pull request on Bitbucket via the REST API. Credentials never enter the container — they are read from a file on the host.

**One-time setup:**

```bash
mkdir -p ~/.config/bitbucket
cat > ~/.config/bitbucket/credentials <<'EOF'
BITBUCKET_USERNAME="your-username"
BITBUCKET_APP_PASSWORD="your-app-password"
EOF
chmod 600 ~/.config/bitbucket/credentials
```

Generate an app password at: Bitbucket → Personal settings → App passwords. Required scopes: `pullrequest:write`.

**Usage:**

```bash
host-pr --title "feat: add login"
host-pr --title "fix: null check" --description "Fixes #42" --dest develop
host-pr --title "chore: update deps" --source feat/deps --dest main
```

- `--title` (required)
- `--description` (optional)
- `--source` (optional — defaults to current branch)
- `--dest` (optional — auto-detects `main`/`master`/`develop`/`trunk` from remote)

The workspace and repo slug are auto-detected from the `origin` remote URL. The PR URL is printed on success.

#### How It Works

1. `sandbox --bridge` starts `socat` in the background, listening on `/tmp/aih-bridge.sock`
2. The socket is mounted into the container at the same path
3. Container-side `host-*` commands send a one-line request (`COMMAND ARGS...`) to the socket
4. `scripts/host-bridge-handler.sh` validates the command and runs `git` in your project directory
5. Output is streamed back to the container
6. When you exit the container, socat is killed and the socket is removed automatically

---

### SSH Keys

⚠️ **IMPORTANT: Generate a dedicated SSH key for use with this container. DO NOT reuse your existing SSH keys.**

The setup expects SSH keys at:
- `~/.ssh/ai_ed25519` (private key, read-only)
- `~/.ssh/ai_ed25519.pub` (public key, read-only)
- `~/.ssh/known_hosts` (known hosts, read-only)

#### Generate a New SSH Key for the Sandbox

```bash
ssh-keygen -t ed25519 -f ~/.ssh/ai_ed25519 -C "ai-sandbox" -N ""
```

This creates a dedicated key pair specifically for the sandbox.

#### Add the Public Key to Your VCS

You **must** add the new public key to your version control system (GitHub, GitLab, Gitea, etc.) before using the sandbox:

**GitHub:**
1. Copy your public key: `cat ~/.ssh/ai_ed25519.pub`
2. Go to Settings → SSH and GPG keys → New SSH key
3. Paste the key and save

**GitLab:**
1. Copy your public key: `cat ~/.ssh/ai_ed25519.pub`
2. Go to Preferences → SSH Keys
3. Paste the key and save

**Other VCS:**
- Consult your platform's documentation for adding SSH keys to your account
- The public key (`~/.ssh/ai_ed25519.pub`) is what you add to your VCS profile

This allows the sandbox to authenticate with your repositories without exposing your main SSH keys.

#### Key Separation Benefits

- **Isolation**: If the container is compromised, only the sandbox-specific key is exposed
- **Security**: Your main SSH keys remain safe on your host system
- **Control**: You can easily revoke the sandbox key without affecting other systems
- **Auditability**: You can track sandbox activity separately in your VCS logs

If you need to use a different key file name, update the key paths in the `sandbox()` function.

### Sudo Access & Password

The `ai` user is configured with sudo privileges. The Dockerfile sets a specific password hash for the `ai` user account.
You can change this to your own password:

1. Generate a SHA-512 password hash (using `crypt` format with `$y$` prefix):
   ```bash
   python3 -c "import crypt; print(crypt.crypt('your_password', crypt.METHOD_SHA512))"
   ```

2. Replace the hash in the Dockerfile with the hash you just generated (line 45):
   Start with the `$` and replace from it to the last `:`.

3. Rebuild the image with your new hash.
