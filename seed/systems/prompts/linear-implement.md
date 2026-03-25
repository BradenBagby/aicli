# Implementation Task

You are working on a task from Linear. The task details are provided above.

## Workflow

1. **Understand the task** — Read the task description carefully. Identify acceptance criteria.
2. **Explore the codebase** — Understand the relevant code, patterns, and conventions before making changes.
3. **Write tests** — Where appropriate, write tests first (unit tests, integration tests, or both). Use the project's existing test framework and conventions.
4. **Implement** — Make the changes described in the task. Follow existing code style and patterns.
5. **Run tests** — Run the full relevant test suite. Write test names and pass/fail results to `test-results.txt` in the workspace root.
6. **Commit** — Stage changed files with `host-add <files>`. Commit via `host-commit -m "<descriptive message>"`.
7. **Push** — Push the branch: `host-push --set-upstream origin <branch-name>` (the branch was already created for you).
8. **Create PR** — Create a pull request: `host-pr --title "<issue-identifier>: <short title>" --description "<summary of changes>"`.
9. **Record PR URL** — Write the PR URL to `pr-url.txt` in the workspace root.
10. **Mark done** — Set `status.md` to exactly `Status: done`.

## Push Failures

If `host-push` fails, **read the error output carefully**. The host runs pre-push hooks (linters, type checks) that may reject the push. Common causes:
- TypeScript errors — fix them, amend or create a new commit, and push again.
- Lint errors — fix them and retry.
- Test failures — fix them and retry.

Do NOT give up on the first push failure. Fix the issue and try again.

## Testing Requirements

- Use `host-wavv jest <module>` to run tests on the host. Do NOT run jest directly inside the container.
- Check `back-end/package.json` scripts to discover available test submodules (e.g., `jest callboards`, `jest auth`, etc.).
- Only run tests for areas affected by your changes. For example, if you changed callboard files, run `host-wavv jest callboards`, not `host-wavv jest`.
- Write a summary of test results (test names, pass/fail) to `test-results.txt`.
- If tests fail and you can fix them, fix them. If not, treat as blocked.

## When Blocked

If you cannot complete the task for any reason:
1. Write a detailed explanation to `why_blocked.md` — include what you tried, what failed, what information or access you need.
2. Set `status.md` to exactly `Status: blocked`.
3. Do NOT create partial PRs or incomplete implementations.

## Important

- Use `host-*` commands for all git operations (not `git` directly).
- All branches use the `claude/` prefix (already set up for you).
- Do not modify files unrelated to the task.
- Keep commits focused and descriptive.
- Do NOT commit `status.md`, `tasks.md`, `why_blocked.md`, `test-results.txt`, or `pr-url.txt` — these are worker control files, not project code.
