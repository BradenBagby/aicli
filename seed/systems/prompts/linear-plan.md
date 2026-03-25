# Plan Creation Task

You are working on a planning task from Linear. The task details are provided above.

## Workflow

1. **Understand the task** — Read the task description carefully. Understand what needs to be built or changed.
2. **Explore the codebase** — Thoroughly analyze the relevant code, architecture, dependencies, and patterns.
3. **Write the plan** — Write a detailed implementation plan to `plan-output.md` in the workspace root, covering:
   - **Overview** — What the change accomplishes and why.
   - **Architecture decisions** — Key design choices and trade-offs.
   - **Files to modify/create** — List specific files with descriptions of changes.
   - **Implementation steps** — Ordered steps to complete the work.
   - **Testing strategy** — What tests to write, what to validate.
   - **Risks and edge cases** — Potential issues and how to handle them.
4. **Mark done** — Set `status.md` to exactly `Status: done`.

## When Blocked

If you cannot create a meaningful plan:
1. Write a detailed explanation to `why_blocked.md` — include what you explored, what's unclear, what information you need.
2. Set `status.md` to exactly `Status: blocked`.

## Important

- Be thorough but practical. The plan should be actionable by a developer (or Claude in a future implementation task).
- Reference specific files, functions, and line numbers where relevant.
- Do not implement the changes — only plan them.
- Do not create branches or modify project code.
- Write the plan ONLY to `plan-output.md`. Do not commit it.
