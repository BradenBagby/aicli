#!/usr/bin/env bash

# Harness SessionStart Hook
# 1. Loads the curated harness bootstrap contract (cortex.md)
# 2. Gathers live git state (branch, status, upstream)
# 3. Manages .ai/jumpstart.json — cached project structure & stack detection
#    - Creates on first run; updates incrementally when HEAD moves
# 4. Emits combined context for the SessionStart hook

set -uo pipefail

MEMORY_DIR="$HOME/.ai"
GLOBAL_CORTEX="$MEMORY_DIR/cortex.md"

# ── Read hook input ──────────────────────────────────────────────────────

HOOK_INPUT=""
if [ ! -t 0 ]; then
  HOOK_INPUT=$(cat)
fi

SESSION_SOURCE=$(echo "$HOOK_INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
PROJECT_DIR=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null || echo "")
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(pwd)"
fi

# ── Helpers ──────────────────────────────────────────────────────────────

brief=""

emit() {
  brief+="$1"$'\n'
}

emit_section() {
  brief+=$'\n'"## $1"$'\n'
}

# ── Cortex ───────────────────────────────────────────────────────────────

load_cortex() {
  if [[ -f "$GLOBAL_CORTEX" ]]; then
    brief+="$(cat "$GLOBAL_CORTEX")"$'\n'
  fi
}

# ── Live Git State (never cached — changes between sessions) ─────────────

gather_git_live() {
  cd "$PROJECT_DIR" 2>/dev/null || return
  git rev-parse --is-inside-work-tree &>/dev/null || return

  local branch head_sha head_msg
  branch=$(git branch --show-current 2>/dev/null || echo "detached")
  head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "")
  head_msg=$(git log -1 --format='%s' 2>/dev/null || echo "")

  emit_section "Git State (live)"
  emit "Branch: \`$branch\`"
  [ -n "$head_sha" ] && emit "HEAD: \`$head_sha\` $head_msg"

  # Working tree
  local status_output
  status_output=$(git status --porcelain 2>/dev/null || echo "")
  if [ -n "$status_output" ]; then
    local staged modified untracked
    staged=$(echo "$status_output" | grep -c '^[MADRC] ' || true)
    modified=$(echo "$status_output" | grep -c '^ [MD]' || true)
    untracked=$(echo "$status_output" | grep -c '^??' || true)
    local parts=()
    [ "$staged" -gt 0 ] && parts+=("$staged staged")
    [ "$modified" -gt 0 ] && parts+=("$modified modified")
    [ "$untracked" -gt 0 ] && parts+=("$untracked untracked")
    emit "Working tree: $(IFS=', '; echo "${parts[*]}")"

    # List changed files (max 15)
    echo "$status_output" | head -15 | awk '{print "- " $2}' | while read -r line; do
      emit "$line"
    done
    local total
    total=$(echo "$status_output" | wc -l | tr -d ' ')
    [ "$total" -gt 15 ] && emit "  ... and $((total - 15)) more"
  else
    emit "Working tree: clean"
  fi

  # Stashes
  local stash_count
  stash_count=$(git stash list 2>/dev/null | wc -l | tr -d ' ')
  [ "$stash_count" -gt 0 ] && emit "Stashes: $stash_count"

  # Upstream sync
  local upstream
  upstream=$(git rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || echo "")
  if [ -n "$upstream" ]; then
    local ahead behind
    ahead=$(git rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "0")
    behind=$(git rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo "0")
    if [ "$ahead" -gt 0 ] || [ "$behind" -gt 0 ]; then
      local sync_parts=()
      [ "$ahead" -gt 0 ] && sync_parts+=("$ahead ahead")
      [ "$behind" -gt 0 ] && sync_parts+=("$behind behind")
      emit "Upstream ($upstream): $(IFS=', '; echo "${sync_parts[*]}")"
    fi
  fi

  # Merge/rebase state
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null)
  [ -d "$git_dir/rebase-merge" ] || [ -d "$git_dir/rebase-apply" ] && emit "**REBASE IN PROGRESS**"
  [ -f "$git_dir/MERGE_HEAD" ] && emit "**MERGE IN PROGRESS**"
  [ -f "$git_dir/CHERRY_PICK_HEAD" ] && emit "**CHERRY-PICK IN PROGRESS**"
}

# ── Jumpstart Cache ──────────────────────────────────────────────────────

# Store jumpstart cache outside the project directory to avoid polluting repos.
# Each project gets its own cache file keyed by a hash of the project path.
_project_hash=$(echo -n "$PROJECT_DIR" | md5sum 2>/dev/null | cut -d' ' -f1 || echo -n "$PROJECT_DIR" | md5 2>/dev/null | cut -d' ' -f1 || echo "default")
JUMPSTART_DIR="${AI_HOME:-$HOME/.ai}/cache/jumpstart"
mkdir -p "$JUMPSTART_DIR"
JUMPSTART_FILE="$JUMPSTART_DIR/${_project_hash}.json"

# Sentinel files — if any of these changed, re-run stack detection
SENTINEL_FILES=(
  package.json Cargo.toml go.mod pyproject.toml requirements.txt
  Gemfile pom.xml build.gradle build.gradle.kts Dockerfile
  docker-compose.yml docker-compose.yaml compose.yml
  tsconfig.json
)

jumpstart_needs_update() {
  # No cache file → full scan needed
  [ ! -f "$JUMPSTART_FILE" ] && echo "full" && return

  cd "$PROJECT_DIR" 2>/dev/null || { echo "none"; return; }
  git rev-parse --is-inside-work-tree &>/dev/null || { echo "none"; return; }

  local cached_sha current_sha
  cached_sha=$(jq -r '.last_commit_sha // ""' "$JUMPSTART_FILE" 2>/dev/null)
  current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

  # Same commit → no update needed
  [ "$cached_sha" = "$current_sha" ] && { echo "none"; return; }

  # Different commit — check what changed
  local update_type="note"  # at minimum, update the commit note

  # Check if sentinel files were touched
  if [ -n "$cached_sha" ] && git cat-file -t "$cached_sha" &>/dev/null; then
    local changed_files
    changed_files=$(git diff --name-only "$cached_sha"..HEAD 2>/dev/null || echo "")

    for sentinel in "${SENTINEL_FILES[@]}"; do
      if echo "$changed_files" | grep -qx "$sentinel"; then
        update_type="stack"
        break
      fi
    done

    # Check if files were added/deleted (structure change)
    local stat_output
    stat_output=$(git diff --stat "$cached_sha"..HEAD 2>/dev/null || echo "")
    if echo "$stat_output" | grep -qE 'files? changed.*insertion|deletion'; then
      local adds dels
      adds=$(git diff --diff-filter=A --name-only "$cached_sha"..HEAD 2>/dev/null | wc -l | tr -d ' ')
      dels=$(git diff --diff-filter=D --name-only "$cached_sha"..HEAD 2>/dev/null | wc -l | tr -d ' ')
      if [ "$adds" -gt 0 ] || [ "$dels" -gt 0 ]; then
        if [ "$update_type" = "stack" ]; then
          update_type="full"
        else
          update_type="structure"
        fi
      fi
    fi
  else
    # Can't diff (cached SHA gone, force-pushed, etc.) → full rebuild
    update_type="full"
  fi

  echo "$update_type"
}

gather_structure() {
  cd "$PROJECT_DIR" 2>/dev/null || return
  # tree -J outputs JSON; -f includes full relative paths; -L 3 limits depth; -I excludes noise dirs
  tree -JfL 3 \
    -I 'node_modules|.git|dist|build|.next|__pycache__|.venv|venv|target|.cache|.turbo|coverage|.ai|.env*|secrets' \
    2>/dev/null || echo '[]'
}

detect_stack() {
  # Optional: structure JSON (from gather_structure / jumpstart cache) for fast file location
  local structure="${1:-}"
  cd "$PROJECT_DIR" 2>/dev/null || return

  local stack_parts=()
  local pkg_manager=""
  local scripts_json="null"

  # Helper: find all instances of a filename.
  # 1. Root check; 2. Structure JSON; 3. Filesystem find (last resort)
  find_all_stack_files() {
    local filename="$1"
    local found=()
    # 1. Root
    [ -f "$filename" ] && found+=("$filename")
    # 2. Structure JSON (names are full relative paths: ./dir/file)
    if [ -n "$structure" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] && [ -f "$p" ] && found+=("$p")
      done < <(echo "$structure" | jq -r --arg f "$filename" '
        .. | objects | select(.type == "file" and (.name | endswith("/" + $f)))
        | .name | ltrimstr("./")
      ' 2>/dev/null)
    fi
    # 3. Filesystem find (last resort — covers files deeper than -L3 or missing structure)
    if [ "${#found[@]}" -eq 0 ]; then
      while IFS= read -r p; do
        [ -n "$p" ] && found+=("$p")
      done < <(find . -maxdepth 3 -name "$filename" \
        -not -path '*/node_modules/*' \
        -not -path '*/.git/*' \
        -not -path '*/vendor/*' \
        -not -path '*/__pycache__/*' \
        -not -path '*/.venv/*' \
        -not -path '*/venv/*' \
        -not -path '*/target/*' \
        2>/dev/null)
    fi
    printf '%s\n' "${found[@]}"
  }

  # Thin wrapper returning the first match (for single-file lookups)
  find_stack_file() { find_all_stack_files "$1" | head -1; }

  # Detect framework from a package.json's deps; appends to stack_parts
  detect_node_pkg() {
    local pkg_json="$1"
    local pkg_dir
    pkg_dir=$(dirname "$pkg_json")
    local deps
    deps=$(cat "$pkg_json")

    # Lock file → package manager
    if [ -z "$pkg_manager" ]; then
      if [ -f "$pkg_dir/bun.lockb" ] || [ -f "$pkg_dir/bun.lock" ]; then pkg_manager="bun"
      elif [ -f "$pkg_dir/pnpm-lock.yaml" ]; then pkg_manager="pnpm"
      elif [ -f "$pkg_dir/yarn.lock" ]; then pkg_manager="yarn"
      else pkg_manager="npm"; fi
    fi

    # Framework
    if echo "$deps" | jq -e '.dependencies.next // .devDependencies.next' &>/dev/null; then stack_parts+=("Next.js")
    elif echo "$deps" | jq -e '.dependencies.react // .devDependencies.react' &>/dev/null; then stack_parts+=("React")
    elif echo "$deps" | jq -e '.dependencies.vue // .devDependencies.vue' &>/dev/null; then stack_parts+=("Vue")
    elif echo "$deps" | jq -e '.dependencies.svelte // .devDependencies.svelte' &>/dev/null; then stack_parts+=("Svelte")
    elif echo "$deps" | jq -e '.dependencies["@angular/core"] // .devDependencies["@angular/core"]' &>/dev/null; then stack_parts+=("Angular")
    elif echo "$deps" | jq -e '.dependencies["@nestjs/core"] // .devDependencies["@nestjs/core"]' &>/dev/null; then stack_parts+=("NestJS")
    elif echo "$deps" | jq -e '.dependencies.express // .devDependencies.express' &>/dev/null; then stack_parts+=("Express")
    elif echo "$deps" | jq -e '.dependencies.fastify // .devDependencies.fastify' &>/dev/null; then stack_parts+=("Fastify")
    elif echo "$deps" | jq -e '.dependencies.hono // .devDependencies.hono' &>/dev/null; then stack_parts+=("Hono")
    fi

    [ -f "$pkg_dir/tsconfig.json" ] && stack_parts+=("TypeScript")

    # Collect scripts from all packages; first one wins for display
    if [ "$scripts_json" = "null" ]; then
      local scripts_raw
      scripts_raw=$(echo "$deps" | jq -c '
        .scripts // {} | to_entries
        | map(select(.key | test("^(test|build|dev|start|lint|typecheck|check|format)$")))
        | from_entries
      ' 2>/dev/null || echo '{}')
      if [ "$scripts_raw" != "{}" ] && [ -n "$scripts_raw" ]; then
        scripts_json=$(jq -n --arg pm "$pkg_manager" --argjson s "$scripts_raw" '{manager: $pm, scripts: $s}')
      fi
    fi
  }

  # Node.js ecosystem — scan ALL package.json files to handle monorepos
  local pkg_jsons=()
  while IFS= read -r p; do
    [ -n "$p" ] && pkg_jsons+=("$p")
  done < <(find_all_stack_files "package.json")

  if [ "${#pkg_jsons[@]}" -gt 0 ]; then
    for pkg_json in "${pkg_jsons[@]}"; do
      detect_node_pkg "$pkg_json"
    done
    # Deduplicate stack_parts (preserve order)
    local seen=() deduped=()
    for part in "${stack_parts[@]}"; do
      local is_dup=0
      for s in "${seen[@]:-}"; do [ "$s" = "$part" ] && is_dup=1 && break; done
      [ "$is_dup" -eq 0 ] && deduped+=("$part") && seen+=("$part")
    done
    stack_parts=("${deduped[@]}")
    stack_parts+=("Node ($pkg_manager)")
  fi

  # Python
  local pyproject
  pyproject=$(find_stack_file "pyproject.toml")
  if [ -n "$pyproject" ]; then
    local py_dir
    py_dir=$(dirname "$pyproject")
    stack_parts+=("Python")
    if [ -f "$py_dir/uv.lock" ]; then stack_parts+=("uv")
    elif [ -f "$py_dir/poetry.lock" ]; then stack_parts+=("Poetry")
    elif [ -f "$py_dir/Pipfile.lock" ]; then stack_parts+=("Pipenv")
    fi
    if grep -q 'django' "$pyproject" 2>/dev/null; then stack_parts+=("Django")
    elif grep -q 'fastapi' "$pyproject" 2>/dev/null; then stack_parts+=("FastAPI")
    elif grep -q 'flask' "$pyproject" 2>/dev/null; then stack_parts+=("Flask")
    fi
  elif [ -n "$(find_stack_file "requirements.txt")" ]; then
    stack_parts+=("Python (pip)")
  fi

  # Rust
  [ -n "$(find_stack_file "Cargo.toml")" ] && stack_parts+=("Rust")

  # Go
  local go_mod
  go_mod=$(find_stack_file "go.mod")
  if [ -n "$go_mod" ]; then
    local go_module
    go_module=$(head -1 "$go_mod" | awk '{print $2}')
    stack_parts+=("Go ($go_module)")
  fi

  # Ruby
  local gemfile
  gemfile=$(find_stack_file "Gemfile")
  if [ -n "$gemfile" ]; then
    local gem_dir
    gem_dir=$(dirname "$gemfile")
    stack_parts+=("Ruby")
    [ -f "$gem_dir/config/routes.rb" ] && stack_parts+=("Rails")
  fi

  # Java/Kotlin
  [ -n "$(find_stack_file "build.gradle")" ] || [ -n "$(find_stack_file "build.gradle.kts")" ] && stack_parts+=("Gradle")
  [ -n "$(find_stack_file "pom.xml")" ] && stack_parts+=("Maven")

  # Docker
  if [ -f "Dockerfile" ] || [ -f "docker-compose.yml" ] || [ -f "docker-compose.yaml" ] || [ -f "compose.yml" ]; then
    stack_parts+=("Docker")
  fi

  # Output as JSON
  local stack_str
  stack_str=$(IFS=', '; echo "${stack_parts[*]}")
  jq -n --arg stack "$stack_str" --argjson scripts "$scripts_json" \
    '{stack: $stack, scripts: $scripts}'
}

get_commit_note() {
  cd "$PROJECT_DIR" 2>/dev/null || return
  git rev-parse --is-inside-work-tree &>/dev/null || return

  local sha subject
  sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  subject=$(git log -1 --format='%s' 2>/dev/null || echo "")

  jq -n --arg sha "$sha" --arg subject "$subject" \
    '{sha: $sha, subject: $subject}'
}

write_jumpstart() {
  local update_scope="$1"  # full | structure | stack | note
  cd "$PROJECT_DIR" 2>/dev/null || return

  mkdir -p "$PROJECT_DIR/.ai"

  local commit_note
  commit_note=$(get_commit_note)
  local current_sha
  current_sha=$(echo "$commit_note" | jq -r '.sha')

  if [ "$update_scope" = "full" ] || [ ! -f "$JUMPSTART_FILE" ]; then
    # Full scan
    local is_git="false"
    git rev-parse --is-inside-work-tree &>/dev/null && is_git="true"

    local structure stack
    structure=$(gather_structure)
    stack=$(detect_stack "$structure")

    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg sha "$current_sha" \
      --argjson git "$is_git" \
      --argjson structure "$structure" \
      --argjson stack "$stack" \
      --argjson commit "$commit_note" \
      '{
        generated_at: $ts,
        last_commit_sha: $sha,
        is_git: $git,
        structure: $structure,
        stack: $stack,
        last_commit: $commit
      }' > "$JUMPSTART_FILE"
    return
  fi

  # Incremental updates
  local tmp
  tmp=$(mktemp)
  cp "$JUMPSTART_FILE" "$tmp"

  case "$update_scope" in
    stack)
      local structure
      structure=$(gather_structure)
      local stack
      stack=$(detect_stack "$structure")
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg sha "$current_sha" \
         --argjson stack "$stack" \
         --argjson structure "$structure" \
         --argjson commit "$commit_note" \
         '.generated_at=$ts | .last_commit_sha=$sha | .stack=$stack | .structure=$structure | .last_commit=$commit' \
         "$tmp" > "$JUMPSTART_FILE"
      ;;
    structure)
      local structure
      structure=$(gather_structure)
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg sha "$current_sha" \
         --argjson structure "$structure" \
         --argjson commit "$commit_note" \
         '.generated_at=$ts | .last_commit_sha=$sha | .structure=$structure | .last_commit=$commit' \
         "$tmp" > "$JUMPSTART_FILE"
      ;;
    note)
      jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg sha "$current_sha" \
         --argjson commit "$commit_note" \
         '.generated_at=$ts | .last_commit_sha=$sha | .last_commit=$commit' \
         "$tmp" > "$JUMPSTART_FILE"
      ;;
  esac

  rm -f "$tmp"
}

gather_changes_since_cache() {
  cd "$PROJECT_DIR" 2>/dev/null || return
  git rev-parse --is-inside-work-tree &>/dev/null || return

  [ ! -f "$JUMPSTART_FILE" ] && return

  local cached_sha
  cached_sha=$(jq -r '.last_commit_sha // ""' "$JUMPSTART_FILE" 2>/dev/null)
  [ -z "$cached_sha" ] && return

  local current_sha
  current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
  [ "$cached_sha" = "$current_sha" ] && return

  # Show what happened since last cached state
  if git cat-file -t "$cached_sha" &>/dev/null; then
    local log_output
    log_output=$(git log --oneline "$cached_sha"..HEAD 2>/dev/null | head -10)
    if [ -n "$log_output" ]; then
      emit_section "Changes Since Last Session"
      emit "\`$cached_sha\` → \`$(git rev-parse --short HEAD)\`"
      emit "$log_output"
      local total
      total=$(git rev-list --count "$cached_sha"..HEAD 2>/dev/null || echo "0")
      [ "$total" -gt 10 ] && emit "  ... and $((total - 10)) more commits"
    fi
  fi
}

emit_jumpstart_context() {
  [ ! -f "$JUMPSTART_FILE" ] && return

  local stack scripts_json pkg_manager
  stack=$(jq -r '.stack.stack // ""' "$JUMPSTART_FILE" 2>/dev/null)
  scripts_json=$(jq -c '.stack.scripts // null' "$JUMPSTART_FILE" 2>/dev/null)

  if [ -n "$stack" ] && [ "$stack" != "null" ]; then
    emit_section "Stack"
    emit "$stack"

    if [ "$scripts_json" != "null" ] && [ -n "$scripts_json" ]; then
      pkg_manager=$(echo "$scripts_json" | jq -r '.manager // "npm"')
      local scripts_list
      scripts_list=$(echo "$scripts_json" | jq -r '.scripts // {} | to_entries[] | "\(.key): `'"$pkg_manager"' run \(.key)` (\(.value))"' 2>/dev/null)
      if [ -n "$scripts_list" ]; then
        emit ""
        emit "**Key commands:**"
        emit "$scripts_list"
      fi
    fi
  fi

  # Structure — skip on compaction to save tokens
  if [ "$SESSION_SOURCE" != "compact" ]; then
    local structure
    structure=$(jq -c '.structure // null' "$JUMPSTART_FILE" 2>/dev/null)
    if [ "$structure" != "null" ] && [ -n "$structure" ]; then
      emit_section "Project Structure"
      # Render tree JSON as a readable list (top-level only)
      local tree_summary
      tree_summary=$(echo "$structure" | jq -r '
        .[0].contents // [] | .[] |
        (.name | ltrimstr("./") | ltrimstr(".\\")) as $n |
        if .type == "directory" then "- \($n)/"
        else "- \($n)" end
      ' 2>/dev/null)
      [ -n "$tree_summary" ] && emit "$tree_summary"
    fi
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────

# 1. Always load cortex
load_cortex

emit ""
emit "# Project Intelligence (auto-generated)"
emit "Session: $SESSION_SOURCE | $(date '+%Y-%m-%d %H:%M')"

# 2. Live git state
gather_git_live

# 3. Jumpstart cache — check and update
cd "$PROJECT_DIR" 2>/dev/null || true

UPDATE_SCOPE=$(jumpstart_needs_update)

if [ "$UPDATE_SCOPE" != "none" ]; then
  # Emit changes-since-cache before updating (so context shows what changed)
  gather_changes_since_cache
  # Update the cache
  write_jumpstart "$UPDATE_SCOPE"
fi

# 4. Emit cached project intelligence
emit_jumpstart_context

# ── Output ───────────────────────────────────────────────────────────────

ESCAPED_CONTENT=$(jq -Rs . <<< "$brief")

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": $ESCAPED_CONTENT
  }
}
EOF
