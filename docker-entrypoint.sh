#!/usr/bin/env bash
set -euo pipefail

HARNESS_ROOT="/etc/aih"
AI_HOME="${AI_HOME:-$HOME/.ai}"

ensure_venv_activation_in_bashrc() {
    local bashrc="$HOME/.bashrc"
    local venv_activate="$HOME/venv/bin/activate"
    local marker_start="# >>> aicli-venv >>>"
    local marker_end="# <<< aicli-venv <<<"
    local tmp

    [[ -f "$venv_activate" ]] || return 0
    [[ -f "$bashrc" ]] || return 0

    tmp="$(mktemp)"

    awk -v start="$marker_start" -v end="$marker_end" '
        $0 == start { in_block=1; next }
        in_block && $0 == end { in_block=0; next }
        !in_block { print }
    ' "$bashrc" > "$tmp"

    cat >> "$tmp" <<EOF

$marker_start
if [ -f "$HOME/venv/bin/activate" ] && [ -z "\${VIRTUAL_ENV:-}" ] && [[ ":\${PATH}:" != *":$HOME/venv/bin:"* ]]; then
  . "$HOME/venv/bin/activate"
fi
$marker_end
EOF

    if ! cmp -s "$tmp" "$bashrc"; then
        cp "$tmp" "$bashrc"
    fi
    rm -f "$tmp"
}

ensure_harness_path_in_bashrc() {
    local bashrc="$HOME/.bashrc"
    local marker_start="# >>> aih-path >>>"
    local marker_end="# <<< aih-path <<<"
    local tmp

    [[ -f "$bashrc" ]] || return 0

    tmp="$(mktemp)"

    awk -v start="$marker_start" -v end="$marker_end" '
        $0 == start { in_block=1; next }
        in_block && $0 == end { in_block=0; next }
        !in_block { print }
    ' "$bashrc" > "$tmp"

    cat >> "$tmp" <<'EOF'

# >>> aih-path >>>
export PATH="$HOME/.local/bin:$HOME/.ai/bin:$HOME/.ai/tools/bin:$PATH"
# <<< aih-path <<<
EOF

    if ! cmp -s "$tmp" "$bashrc"; then
        cp "$tmp" "$bashrc"
    fi
    rm -f "$tmp"
}

ensure_engram_env_in_bashrc() {
    local bashrc="$HOME/.bashrc"
    local marker_start="# >>> engram >>>"
    local marker_end="# <<< engram <<<"
    local tmp

    [[ -f "$bashrc" ]] || return 0

    tmp="$(mktemp)"

    awk -v start="$marker_start" -v end="$marker_end" '
        $0 == start { in_block=1; next }
        in_block && $0 == end { in_block=0; next }
        !in_block { print }
    ' "$bashrc" > "$tmp"

    cat >> "$tmp" <<'EOF'

# >>> engram >>>
export ENGRAM_DATA_DIR="${ENGRAM_DATA_DIR:-$HOME/.ai/memory/engram}"
# <<< engram <<<
EOF

    if ! cmp -s "$tmp" "$bashrc"; then
        cp "$tmp" "$bashrc"
    fi
    rm -f "$tmp"
}

# Remove stale PATH entries from .bashrc for tools now installed to system paths,
# strip the redundant standalone .local/bin export, and collapse excessive blank lines
remove_stale_paths_from_bashrc() {
    local bashrc="$HOME/.bashrc"
    [[ -f "$bashrc" ]] || return 0
    local tmp
    tmp="$(mktemp)"
    grep -v -E '((\$HOME|/home/[^/]+)/\.(kilo|opencode)/bin|^# (kilo|opencode)$|^export PATH="\$HOME/\.local/bin:\$PATH"$)' "$bashrc" \
        | cat -s > "$tmp"
    if ! cmp -s "$tmp" "$bashrc"; then
        cp "$tmp" "$bashrc"
    fi
    rm -f "$tmp"
}
remove_stale_paths_from_bashrc

# Remove stale home-dir binaries for tools now installed to /usr/local/bin
rm -f "$HOME/.kilo/bin/kilo" "$HOME/.opencode/bin/opencode"
rm -f "$HOME/.nvm/versions/node/v"*/bin/codex \
      "$HOME/.nvm/versions/node/v"*/bin/gemini \
      "$HOME/.nvm/versions/node/v"*/bin/agent-browser

mkdir -p \
    "$AI_HOME" \
    "$HOME/.claude" \
    "$HOME/.codex" \
    "$HOME/.cursor/rules" \
    "$HOME/.gemini" \
    "$HOME/.config/kilo" \
    "$HOME/.config/opencode" \
    "$HOME/.local/share/kilo" \
    "$HOME/.local/share/opencode" \
    "$HOME/.local/state/kilo" \
    "$HOME/.local/state/opencode" \
    "$HOME/.cache/kilo" \
    "$HOME/.cache/opencode"

ensure_venv_activation_in_bashrc
ensure_harness_path_in_bashrc
ensure_engram_env_in_bashrc

if [[ -f "$HARNESS_ROOT/setup.sh" ]]; then
    (
        cd "$HARNESS_ROOT"
        bash ./setup.sh
        bash ./setup.sh clients
    )
fi

# Ensure harness bins and CLI tools are on PATH for non-interactive commands (e.g. linear-worker)
export PATH="$HOME/.local/bin:$HOME/.ai/bin:$HOME/.ai/tools/bin:$PATH"

exec "$@"
