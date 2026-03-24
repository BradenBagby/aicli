#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SOURCE_CONFIG_DIR="$SOURCE_SEED_DIR/configs"
[[ -d "$SOURCE_CONFIG_DIR" ]] || die "Missing source configs directory at $SOURCE_CONFIG_DIR"

install_or_merge_claude_settings() {
  local source_file="$1"
  local dest_file="$2"
  local required_dir="$3"
  local tool_name="$4"
  local install_hint="$5"
  local hook_cmd="~/.ai/infra/hooks/session-start.sh"
  local statusline_cmd="~/.claude/statusline.sh"

  if [[ ! -f "$source_file" ]]; then
    warn "Source config missing for $tool_name: $source_file"
    return 1
  fi

  if [[ ! -d "$required_dir" ]]; then
    skip "$tool_name config not installed (missing directory: $required_dir)"
    if [[ -n "$install_hint" ]]; then
      log "      Install hint: $install_hint"
    fi
    return 0
  fi

  ensure_dir "$(dirname "$dest_file")"

  # First install uses seed template as-is.
  if [[ ! -f "$dest_file" ]]; then
    cp -p "$source_file" "$dest_file"
    log "Installed $tool_name config: $dest_file"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found; cannot merge $tool_name settings without overwriting. Skipping."
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg hook "$hook_cmd" --arg statusline "$statusline_cmd" '
    def has_cortex_hook:
      ((.hooks.SessionStart // [])
        | map(any((.hooks // [])[]?; (.type == "command" and .command == $hook)))
        | any);

    (if has_cortex_hook then
      .
    else
      .hooks = (.hooks // {}) |
      .hooks.SessionStart = ((.hooks.SessionStart // []) + [{"hooks":[{"type":"command","command":$hook}]}])
    end)
    | if (.statusLine | type) != "object" then
        .statusLine = {"type":"command","command":$statusline}
      else
        .statusLine.type = (.statusLine.type // "command") |
        .statusLine.command = (.statusLine.command // $statusline)
      end
    | .permissions = (.permissions // {})
    | .permissions.deny = ((.permissions.deny // []) + [
        "Bash(git push*)",
        "Bash(git rebase*)",
        "Bash(git filter-repo*)",
        "Bash(git clean -fdx*)",
        "Bash(git gc --prune=now*)",
        "Bash(git merge*)"
      ] | unique)
    | .enabledPlugins = ((.enabledPlugins // {}) + {"agent-browser@local-plugins": true})
    | .extraKnownMarketplaces = ((.extraKnownMarketplaces // {}) + {
        "local-plugins": {"source": {"source": "directory", "path": "~/.ai/plugins"}}
      })
  ' "$dest_file" >"$tmp_file" || {
    rm -f "$tmp_file"
    warn "Could not parse $tool_name config as JSON: $dest_file"
    return 0
  }

  if cmp -s "$tmp_file" "$dest_file"; then
    rm -f "$tmp_file"
    log "$tool_name config unchanged: $dest_file"
    return 0
  fi

  backup_if_exists "$dest_file"
  cp -p "$tmp_file" "$dest_file"
  rm -f "$tmp_file"
  log "Merged $tool_name SessionStart hook into: $dest_file"
}

install_or_merge_claude_settings \
  "$SOURCE_CONFIG_DIR/claude_settings.json" \
  "$HOME/.claude/claude.json" \
  "$HOME/.claude" \
  "Claude" \
  "curl -fsSL https://claude.ai/install.sh | bash"

# Claude Code reads MCP servers from ~/.claude.json (home dir root), not settings.json.
# Merge mcpServers there so /mcp and claude mcp list pick them up.
if [[ -d "$HOME/.claude" ]] && command -v jq >/dev/null 2>&1; then
  claude_json="$HOME/.claude.json"
  tmp_file="$(mktemp)"
  jq -n \
    --argjson existing "$(jq '.' "$claude_json" 2>/dev/null || echo '{}')" '
    $existing
    | .mcpServers = ((.mcpServers // {}) + {
        "engram": {"type": "stdio", "command": "engram", "args": ["mcp"]}
      })
  ' >"$tmp_file"
  if ! cmp -s "$tmp_file" "$claude_json" 2>/dev/null; then
    backup_if_exists "$claude_json"
    cp -p "$tmp_file" "$claude_json"
    log "Merged MCP servers into $claude_json"
  else
    log "Claude MCP config unchanged: $claude_json"
  fi
  rm -f "$tmp_file"
fi

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/claude_statusline.sh" \
  "$HOME/.claude/statusline.sh" \
  "$HOME/.claude" \
  "Claude status line" \
  "curl -fsSL https://claude.ai/install.sh | bash"

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/claude_CLAUDE.md" \
  "$HOME/.claude/CLAUDE.md" \
  "$HOME/.claude" \
  "Claude global CLAUDE.md" \
  "curl -fsSL https://claude.ai/install.sh | bash"

if [[ -f "$HOME/.claude/statusline.sh" && ! -x "$HOME/.claude/statusline.sh" ]]; then
  chmod u+x "$HOME/.claude/statusline.sh"
  log "Set executable permission on Claude status line: $HOME/.claude/statusline.sh"
fi

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/cursor_rules_ai-cortex-policy.mdc" \
  "$HOME/.cursor/rules/cortex-policy.mdc" \
  "$HOME/.cursor/rules" \
  "Cursor" \
  "curl https://cursor.com/install -fsS | bash"

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/cursor_rules_agent-browser.mdc" \
  "$HOME/.cursor/rules/agent-browser.mdc" \
  "$HOME/.cursor/rules" \
  "Cursor agent-browser rule" \
  "curl https://cursor.com/install -fsS | bash"

# Cursor MCP servers → ~/.cursor/mcp.json
if [[ -d "$HOME/.cursor" ]] && command -v jq >/dev/null 2>&1; then
  cursor_mcp="$HOME/.cursor/mcp.json"
  tmp_file="$(mktemp)"
  jq -n \
    --argjson existing "$(jq '.' "$cursor_mcp" 2>/dev/null || echo '{}')" '
    $existing
    | .mcpServers = ((.mcpServers // {}) + {
        "engram": {"command": "engram", "args": ["mcp"]}
      })
  ' >"$tmp_file"
  if ! cmp -s "$tmp_file" "$cursor_mcp" 2>/dev/null; then
    backup_if_exists "$cursor_mcp"
    cp -p "$tmp_file" "$cursor_mcp"
    log "Merged MCP servers into $cursor_mcp"
  else
    log "Cursor MCP config unchanged: $cursor_mcp"
  fi
  rm -f "$tmp_file"
fi

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/codex_AGENTS.md" \
  "$HOME/.codex/AGENTS.md" \
  "$HOME/.codex" \
  "Codex" \
  "brew install codex (macOS) OR npm i -g @openai/codex (Linux). Codex CLI currently supports macOS/Linux only."

# Codex skill: agent-browser
if [[ -d "$HOME/.codex" ]]; then
  codex_skill_dest="$HOME/.codex/skills/agent-browser"
  harness_skill_src="$HOME/.ai/plugins/plugins/agent-browser/skills/agent-browser"
  mkdir -p "$HOME/.codex/skills"
  if [[ -d "$harness_skill_src" ]]; then
    if [[ ! -e "$codex_skill_dest" ]]; then
      ln -sf "$harness_skill_src" "$codex_skill_dest"
      log "Linked Codex agent-browser skill: $codex_skill_dest"
    else
      log "Codex agent-browser skill unchanged: $codex_skill_dest"
    fi
  else
    warn "agent-browser skill source not found at $harness_skill_src (run setup plugins first)"
  fi
fi

# Gemini skill: agent-browser
if [[ -d "$HOME/.gemini" ]]; then
  gemini_skill_dest="$HOME/.gemini/skills/agent-browser"
  harness_skill_src="$HOME/.ai/plugins/plugins/agent-browser/skills/agent-browser"
  if [[ -d "$harness_skill_src" ]]; then
    ensure_dir "$HOME/.gemini/skills"
    if [[ ! -e "$gemini_skill_dest" ]]; then
      ln -sf "$harness_skill_src" "$gemini_skill_dest"
      log "Linked Gemini agent-browser skill: $gemini_skill_dest"
    else
      log "Gemini agent-browser skill unchanged: $gemini_skill_dest"
    fi
  else
    warn "agent-browser skill source not found at $harness_skill_src (run setup plugins first)"
  fi
fi

if [[ -f "$SOURCE_CONFIG_DIR/opencode_auth.json" ]]; then
  opencode_auth="$HOME/.local/share/opencode/auth.json"
  ensure_dir "$(dirname "$opencode_auth")"
  if [[ ! -f "$opencode_auth" ]]; then
    cp -p "$SOURCE_CONFIG_DIR/opencode_auth.json" "$opencode_auth"
    log "Installed OpenCode auth template: $opencode_auth"
  else
    log "OpenCode auth unchanged: $opencode_auth"
  fi
else
  warn "Source config missing for OpenCode auth template: $SOURCE_CONFIG_DIR/opencode_auth.json"
fi

if [[ -f "$SOURCE_CONFIG_DIR/kilo_auth.json" ]]; then
  kilo_auth="$HOME/.local/share/kilo/auth.json"
  ensure_dir "$(dirname "$kilo_auth")"
  if [[ ! -f "$kilo_auth" ]]; then
    cp -p "$SOURCE_CONFIG_DIR/kilo_auth.json" "$kilo_auth"
    log "Installed Kilo auth template: $kilo_auth"
  else
    log "Kilo auth unchanged: $kilo_auth"
  fi
else
  warn "Source config missing for Kilo auth template: $SOURCE_CONFIG_DIR/kilo_auth.json"
fi

if [[ -f "$SOURCE_CONFIG_DIR/kilo_config.json" ]]; then
  kilo_config="$HOME/.config/kilo/kilo.json"
  ensure_dir "$(dirname "$kilo_config")"
  if [[ ! -f "$kilo_config" ]]; then
    cp -p "$SOURCE_CONFIG_DIR/kilo_config.json" "$kilo_config"
    log "Installed Kilo config template: $kilo_config"
  elif grep -q 'permission:' "$kilo_config" &&
    grep -q '\*: allow' "$kilo_config"; then
    backup_if_exists "$kilo_config"
    cp -p "$SOURCE_CONFIG_DIR/kilo_config.json" "$kilo_config"
    log "Migrated Kilo config template to valid JSON: $kilo_config"
  elif command -v jq >/dev/null 2>&1 && jq -e . "$kilo_config" >/dev/null 2>&1; then
    tmp_file="$(mktemp)"
    jq --arg cortex "~/.ai/cortex.md" --arg ab_skill "~/.ai/plugins/plugins/agent-browser/skills/agent-browser/SKILL.md" '
      .instructions = ((.instructions // []) + [$cortex, $ab_skill] | unique)
      | .permission = (.permission // {})
      | .permission.bash = ((.permission.bash // {}) + {
          "* .env*": "deny",
          "* .env": "deny",
          "* .env.*": "deny",
          "* .env.local*": "allow",
          "* .env.example*": "allow",
          "* */.env*": "deny",
          "* */.env.local*": "allow",
          "* */.env.example*": "allow",
          "git push*": "deny",
          "git rebase*": "deny",
          "git filter-repo*": "deny",
          "git clean -fdx*": "deny",
          "git gc --prune=now*": "deny",
          "git merge*": "deny"
        })
      | .permission.read = ((.permission.read // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.edit = ((.permission.edit // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.glob = ((.permission.glob // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.list = ((.permission.list // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .mcp = ((.mcp // {}) + {
          "engram": {"type": "local", "command": ["engram", "mcp"], "enabled": true}
        })
    ' "$kilo_config" >"$tmp_file" || {
      rm -f "$tmp_file"
      warn "Could not parse Kilo config as JSON: $kilo_config"
      tmp_file=""
    }

    if [[ -n "${tmp_file:-}" ]]; then
      if cmp -s "$tmp_file" "$kilo_config"; then
        rm -f "$tmp_file"
        log "Kilo config unchanged: $kilo_config"
      else
        backup_if_exists "$kilo_config"
        cp -p "$tmp_file" "$kilo_config"
        rm -f "$tmp_file"
        log "Merged Kilo startup instructions into: $kilo_config"
      fi
    fi
  else
    warn "jq not found or Kilo config is not strict JSON; skipping instruction merge: $kilo_config"
  fi
else
  warn "Source config missing for Kilo config template: $SOURCE_CONFIG_DIR/kilo_config.json"
fi

if [[ -f "$SOURCE_CONFIG_DIR/opencode_config.json" ]]; then
  opencode_config="$HOME/.config/opencode/opencode.json"
  ensure_dir "$(dirname "$opencode_config")"
  if [[ ! -f "$opencode_config" ]]; then
    cp -p "$SOURCE_CONFIG_DIR/opencode_config.json" "$opencode_config"
    log "Installed OpenCode config template: $opencode_config"
  elif grep -q 'permission:' "$opencode_config" &&
    grep -q '\*: allow' "$opencode_config"; then
    backup_if_exists "$opencode_config"
    cp -p "$SOURCE_CONFIG_DIR/opencode_config.json" "$opencode_config"
    log "Migrated OpenCode config template to valid JSON: $opencode_config"
  elif command -v jq >/dev/null 2>&1 && jq -e . "$opencode_config" >/dev/null 2>&1; then
    tmp_file="$(mktemp)"
    jq --arg cortex "~/.ai/cortex.md" --arg ab_skill "~/.ai/plugins/plugins/agent-browser/skills/agent-browser/SKILL.md" '
      .instructions = ((.instructions // []) + [$cortex, $ab_skill] | unique)
      | .permission = (.permission // {})
      | .permission.bash = ((.permission.bash // {}) + {
          "* .env*": "deny",
          "* .env": "deny",
          "* .env.*": "deny",
          "* .env.local*": "allow",
          "* .env.example*": "allow",
          "* */.env*": "deny",
          "* */.env.local*": "allow",
          "* */.env.example*": "allow",
          "git push*": "deny",
          "git rebase*": "deny",
          "git filter-repo*": "deny",
          "git clean -fdx*": "deny",
          "git gc --prune=now*": "deny",
          "git merge*": "deny"
        })
      | .permission.read = ((.permission.read // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.edit = ((.permission.edit // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.glob = ((.permission.glob // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .permission.list = ((.permission.list // {}) + {
          "*": "allow",
          ".env*": "deny",
          "**/.env*": "deny",
          "*.env": "deny",
          "*.env.*": "deny",
          "**/*.env": "deny",
          "**/*.env.*": "deny",
          ".env.local": "allow",
          "**/.env.local": "allow",
          ".env.example": "allow",
          "**/.env.example": "allow"
        })
      | .mcp = ((.mcp // {}) + {
          "engram": {"type": "local", "command": ["engram", "mcp"], "enabled": true}
        })
    ' "$opencode_config" >"$tmp_file" || {
      rm -f "$tmp_file"
      warn "Could not parse OpenCode config as JSON: $opencode_config"
      tmp_file=""
    }

    if [[ -n "${tmp_file:-}" ]]; then
      if cmp -s "$tmp_file" "$opencode_config"; then
        rm -f "$tmp_file"
        log "OpenCode config unchanged: $opencode_config"
      else
        backup_if_exists "$opencode_config"
        cp -p "$tmp_file" "$opencode_config"
        rm -f "$tmp_file"
        log "Merged OpenCode startup instructions into: $opencode_config"
      fi
    fi
  else
    warn "jq not found or OpenCode config is not strict JSON; skipping instruction merge: $opencode_config"
  fi
else
  warn "Source config missing for OpenCode config template: $SOURCE_CONFIG_DIR/opencode_config.json"
fi

install_or_merge_gemini_settings() {
  local source_file="$1"
  local dest_file="$2"
  local required_dir="$3"
  local tool_name="$4"
  local install_hint="$5"
  local hook_cmd="~/.ai/infra/hooks/session-start.sh"

  if [[ ! -f "$source_file" ]]; then
    warn "Source config missing for $tool_name: $source_file"
    return 1
  fi

  if [[ ! -d "$required_dir" ]]; then
    skip "$tool_name config not installed (missing directory: $required_dir)"
    if [[ -n "$install_hint" ]]; then
      log "      Install hint: $install_hint"
    fi
    return 0
  fi

  ensure_dir "$(dirname "$dest_file")"

  if [[ ! -f "$dest_file" ]]; then
    cp -p "$source_file" "$dest_file"
    log "Installed $tool_name config: $dest_file"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not found; cannot merge $tool_name settings without overwriting. Skipping."
    return 0
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  jq --arg hook "$hook_cmd" '
    def has_cortex_hook:
      ((.hooks.SessionStart // [])
        | map(any((.hooks // [])[]?; (.type == "command" and .command == $hook)))
        | any);

    (if has_cortex_hook then
      .
    else
      .hooks = (.hooks // {}) |
      .hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"*","hooks":[{"name":"cortex_loader","type":"command","command":$hook,"timeout":5000}]}])
    end)
    | .permissions = (.permissions // {})
    | .permissions.deny = ((.permissions.deny // []) + [
        "Bash(git push*)",
        "Bash(git rebase*)",
        "Bash(git filter-repo*)",
        "Bash(git clean -fdx*)",
        "Bash(git gc --prune=now*)",
        "Bash(git merge*)"
      ] | unique)
    | .mcpServers = ((.mcpServers // {}) + {
        "engram": {"command": "engram", "args": ["mcp"]}
      })
  ' "$dest_file" >"$tmp_file" || {
    rm -f "$tmp_file"
    warn "Could not parse $tool_name config as JSON: $dest_file"
    return 0
  }

  if cmp -s "$tmp_file" "$dest_file"; then
    rm -f "$tmp_file"
    log "$tool_name config unchanged: $dest_file"
    return 0
  fi

  backup_if_exists "$dest_file"
  cp -p "$tmp_file" "$dest_file"
  rm -f "$tmp_file"
  log "Merged $tool_name SessionStart hook into: $dest_file"
}

install_or_merge_gemini_settings \
  "$SOURCE_CONFIG_DIR/gemini_settings.json" \
  "$HOME/.gemini/settings.json" \
  "$HOME/.gemini" \
  "Gemini CLI" \
  "brew install gemini-cli (macOS) OR npm install -g @google/gemini-cli (Linux/Windows)"

install_config_if_dir_exists \
  "$SOURCE_CONFIG_DIR/codex_config.toml" \
  "$HOME/.codex/config.toml" \
  "$HOME/.codex" \
  "Codex MCP config" \
  "npm install -g @openai/codex"

