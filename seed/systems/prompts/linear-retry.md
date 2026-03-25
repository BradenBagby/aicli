# Retry Task

You are retrying a task that was previously blocked. The original task details, previous blocker, and a human reply with guidance are provided above.

## Workflow

1. **Read the guidance** — The "Reply / Guidance" section above contains a human response to your blocker. Use this information to overcome the obstacle.
2. **Reassess** — With the new information, determine how to proceed with the original task.
3. **Continue** — Follow the same workflow as the original task type:
   - For **implementation tasks**: write tests, implement, run tests, commit via `host-*` commands, push, create PR via `host-pr`, write PR URL to `pr-url.txt`, write test results to `test-results.txt`, set `status.md` to `Status: done`.
   - For **plan tasks**: analyze the codebase, write a detailed implementation plan to `plan-output.md` in the workspace root, set `status.md` to `Status: done`.

## When Still Blocked

If the guidance doesn't resolve the issue:
1. Write a detailed explanation to `why_blocked.md` — explain what the guidance was, how you tried to apply it, and why it still doesn't work.
2. Set `status.md` to exactly `Status: blocked`.

## Important

- Use `host-*` commands for all git operations.
- All branches use the `claude/` prefix.
- The workspace may already have your previous work on it — continue from where you left off if applicable.
