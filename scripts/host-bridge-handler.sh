#!/usr/bin/env bash
# Called by socat per-connection. Arg $1 = workspace dir.
# Reads null-delimited args from stdin: CMD\0ARG1\0ARG2\0...
# Validates against allowlist and safety rules, runs git in workspace.

WORKSPACE="${1:-.}"
ALLOWLIST="add checkout reset commit pull push fetch status log diff stash branch show mv rm ls-files clean pr"
PROTECTED_BRANCHES="main master develop trunk"
LOG_FILE="${HOME}/.aih-bridge.log"
BB_CREDS="${HOME}/.config/bitbucket/credentials"

# Read null-delimited args from stdin (fd 0, connected to socket by socat)
# Uses read loop for bash 3.2 compatibility (macOS default shell)
args=()
while IFS= read -r -d '' arg; do
  [[ -z "$arg" ]] && break  # empty arg = end-of-args sentinel
  args+=("$arg")
done
cmd="${args[0]%$'\n'}"   # strip any trailing newline
rest_args=("${args[@]:1}")

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$$] $cmd ${rest_args[*]}" >> "$LOG_FILE"
}

deny() {
  echo "ERROR: $*" | tee -a "$LOG_FILE"
  exit 1
}

# --- Allowlist check ---
[[ -z "$cmd" ]] && exit 0  # empty = connectivity probe, ignore silently
allowed=false
for allowed_cmd in $ALLOWLIST; do
  [[ "$cmd" == "$allowed_cmd" ]] && allowed=true && break
done
[[ "$allowed" == false ]] && deny "command '$cmd' not in allowlist ($ALLOWLIST)"

cd "$WORKSPACE" || deny "cannot cd to workspace '$WORKSPACE'"

# --- Per-command safety rules ---

if [[ "$cmd" == "commit" ]]; then
  for arg in "${rest_args[@]}"; do
    case "$arg" in
      --amend)              deny "--amend is not allowed (no rewriting git history)" ;;
      --fixup=*|--squash=*) deny "'$arg' is not allowed (no rewriting git history)" ;;
      --no-verify|-n)       deny "--no-verify is not allowed (hooks must run)" ;;
    esac
  done
  current_branch="$(git branch --show-current 2>/dev/null)"
  if [[ "$current_branch" != claude/* ]]; then
    deny "commits only allowed on branches prefixed 'claude/' (current: '$current_branch')"
  fi
fi

if [[ "$cmd" == "push" ]]; then
  # Validate current branch before checking args
  current_branch="$(git branch --show-current 2>/dev/null)"
  if [[ "$current_branch" != claude/* ]]; then
    deny "push only allowed from branches prefixed 'claude/' (current: '$current_branch')"
  fi
  for arg in "${rest_args[@]}"; do
    case "$arg" in
      --force|-f|--force-with-lease|--force-if-includes)
        deny "'$arg' is not allowed (no force pushing)" ;;
    esac
    # Block refspecs that target a non-claude branch
    if [[ "$arg" == *:* ]]; then
      target="${arg##*:}"
      target="${target#refs/heads/}"
      if [[ "$target" != claude/* ]]; then
        deny "cannot push to '$target' — target branch must be prefixed 'claude/'"
      fi
    fi
  done
fi

if [[ "$cmd" == "branch" ]]; then
  for arg in "${rest_args[@]}"; do
    case "$arg" in
      -D) deny "-D (force delete) is not allowed. Use -d for safe branch deletion." ;;
    esac
  done
fi

if [[ "$cmd" == "stash" ]]; then
  subcommand=""
  for arg in "${rest_args[@]}"; do
    [[ "$arg" == -* ]] && continue
    subcommand="$arg"
    break
  done
  case "$subcommand" in
    drop|clear) deny "stash $subcommand is not allowed (permanently destroys stashed work)" ;;
  esac
fi

if [[ "$cmd" == "pr" ]]; then
  # Load credentials
  [[ -f "$BB_CREDS" ]] || deny "Bitbucket credentials not found at $BB_CREDS. See README for setup."
  # shellcheck source=/dev/null
  source "$BB_CREDS"
  [[ -n "${BITBUCKET_USERNAME:-}" ]]     || deny "BITBUCKET_USERNAME not set in $BB_CREDS"
  [[ -n "${BITBUCKET_APP_PASSWORD:-}" ]] || deny "BITBUCKET_APP_PASSWORD not set in $BB_CREDS"

  # Parse args
  title=""
  description=""
  source_branch="$(git branch --show-current 2>/dev/null)"
  dest_branch=""
  i=0
  while [[ $i -lt ${#rest_args[@]} ]]; do
    case "${rest_args[$i]}" in
      --title)       ((i++)); title="${rest_args[$i]}" ;;
      --description) ((i++)); description="${rest_args[$i]}" ;;
      --source)      ((i++)); source_branch="${rest_args[$i]}" ;;
      --dest)        ((i++)); dest_branch="${rest_args[$i]}" ;;
    esac
    ((i++))
  done

  [[ -n "$title" ]]         || deny "host-pr requires --title"
  [[ -n "$source_branch" ]] || deny "could not detect source branch; use --source"
  [[ "$source_branch" == claude/* ]] || deny "PRs only allowed from branches prefixed 'claude/' (source: '$source_branch')"

  # Default dest to first protected branch found in local remote-tracking refs (no network)
  if [[ -z "$dest_branch" ]]; then
    for candidate in master main develop trunk; do
      if git show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
        dest_branch="$candidate"
        break
      fi
    done
    [[ -n "$dest_branch" ]] || deny "could not detect destination branch; use --dest (tried: master main develop trunk)"
  fi

  # Auto-detect workspace and repo slug from git remote URL
  remote_url="$(git remote get-url origin 2>/dev/null)" \
    || deny "no 'origin' remote found"
  if [[ "$remote_url" =~ bitbucket\.org[:/]([^/]+)/([^/.]+) ]]; then
    bb_workspace="${BASH_REMATCH[1]}"
    bb_repo="${BASH_REMATCH[2]}"
  else
    deny "origin remote does not look like a Bitbucket URL: $remote_url"
  fi

  # Build JSON payload safely with Python (guaranteed on macOS)
  payload="$(python3 -c "
import json, sys
print(json.dumps({
  'title': sys.argv[1],
  'description': sys.argv[2],
  'source': {'branch': {'name': sys.argv[3]}},
  'destination': {'branch': {'name': sys.argv[4]}}
}))
" "$title" "$description" "$source_branch" "$dest_branch")"

  log
  echo "Creating PR: '$title' ($source_branch → $dest_branch) in $bb_workspace/$bb_repo"

  response="$(curl -s -w '\n%{http_code}' -X POST \
    -u "$BITBUCKET_USERNAME:$BITBUCKET_APP_PASSWORD" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.bitbucket.org/2.0/repositories/$bb_workspace/$bb_repo/pullrequests")"

  http_code="${response##*$'\n'}"
  body="${response%$'\n'*}"

  if [[ "$http_code" == "201" ]]; then
    pr_url="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['links']['html']['href'])" <<< "$body" 2>/dev/null)"
    echo "PR created: ${pr_url:-$body}"
  else
    error_msg="$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message', sys.stdin.read()))" <<< "$body" 2>/dev/null || echo "$body")"
    deny "Bitbucket API error ($http_code): $error_msg"
  fi
  exit 0
fi

# --- Log and run git command ---
log
git "$cmd" "${rest_args[@]}" 2>&1
