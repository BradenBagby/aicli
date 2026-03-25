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

## Linear Integration

When working on tasks dispatched by the linear-worker service, your task details come from a Linear issue. The issue title, description, and any acceptance criteria are provided in your prompt.

### General Rules

- **Always use `host-*` commands** for git operations. Never use `git` directly.
- **All branches must start with `claude/`** — the host bridge rejects anything else.
- **One task at a time** — focus entirely on the current task.
- **Leave high-level comments** — the service posts comments to Linear on your behalf based on status files you write. Keep `why_blocked.md` detailed but concise.

### Implementation Tasks

1. Read and understand the task requirements from the prompt.
2. Explore the codebase to understand existing patterns and conventions.
3. Write tests where appropriate — use the project's existing test framework.
4. Implement the solution following existing code style.
5. Run the relevant test suite. Write results (test names, pass/fail) to `test-results.txt`.
6. Commit via `host-add` + `host-commit`.
7. Push: `host-push --set-upstream origin <branch-name>`.
8. Create PR: `host-pr --title "<issue-id>: <title>" --description "<summary>"`.
9. Write the PR URL to `pr-url.txt`.
10. Set `status.md` to `Status: done`.

### Plan Tasks

1. Analyze the codebase thoroughly.
2. Write an implementation plan to `plan-output.md` covering architecture, file changes, testing strategy, and risks.
3. Do not implement — only plan.
4. Set `status.md` to `Status: done`.

### When Blocked

You can always move to blocked if you get stuck:
1. Write a detailed explanation to `why_blocked.md` (what you tried, what failed, what you need).
2. Set `status.md` to `Status: blocked`.
3. Do NOT submit partial work or incomplete PRs.

### Testing

- Always write tests where it makes sense for the changes.
- Always run the project's relevant test suite before submitting.
- Record test results to `test-results.txt` (test names and pass/fail status).
- If tests fail and you can fix them, fix them. If not, move to blocked.
