# Git Workflow

You are running inside a sandboxed Docker container. The workspace is mounted from the host at `/workspace`.

**Do not run `git commit`, `git push`, `git pull`, `git fetch`, or create pull requests directly.** These operations must go through the host bridge commands so that safety rules and credentials are enforced on the host.

## Host bridge commands

Use these instead of the equivalent `git` commands:

| Instead of | Use |
|------------|-----|
| `git add` | `host-add` |
| `git checkout` | `host-checkout` |
| `git reset` | `host-reset` |
| `git mv` | `host-mv` |
| `git rm` | `host-rm` |
| `git commit` | `host-commit` |
| `git push` | `host-push` |
| `git pull` | `host-pull` |
| `git fetch` | `host-fetch` |
| `git show` | `host-show` |
| `git ls-files` | `host-ls-files` |
| `git status` | `host-status` |
| `git log` | `host-log` |
| `git diff` | `host-diff` |
| `git stash` | `host-git stash` |
| `git branch` | `host-git branch` |
| create a PR | `host-pr --title "..." [--description "..."]` |

These accept the same arguments as their `git` equivalents (e.g. `host-commit -m "message"`, `host-push --set-upstream origin <branch>`).

`host-git <subcommand>` is also available as a direct gateway for any allowed subcommand.

## Local git operations (use directly)

Do not use `git` directly inside the container — use the host bridge commands above for all git operations.

## Branch rules

- **Always work on a `claude/` prefixed branch.** The host bridge will reject commits and pushes from any other branch.
- Before starting work: `git checkout -b claude/<short-description>`
- Do not use `--amend`, `--no-verify`, `--force`, or any history-rewriting flags.

## Pull request flow

1. Create a branch: `host-checkout -b claude/<feature>`
2. Make changes, stage with `host-add <files>`
3. Commit: `host-commit -m "description"`
4. Push: `host-push --set-upstream origin claude/<feature>`
5. Open PR: `host-pr --title "Title" --description "Details"`
