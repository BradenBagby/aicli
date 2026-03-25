# Cortex

This is the top-level bootstrap contract for the AI-agnostic harness.

## Session Start Contract

This file must be loaded at the start of every new session before any user-facing answer.

Required startup order:
1. Read `~/.ai/cortex.md`.
2. Mention TID/PROVIDER once at session start only, unless user explicitly asks again.
3. Do not preload all contracts; load only the contracts required by the current task.
4. Proceed with task work.

If step 1 fails, report the failure and retry before continuing.

## Harness Roadmap

Canonical harness paths:

- `~/.ai/bin` - shared command entrypoints
- `~/.ai/agents/definitions` - agent definitions
- `~/.ai/skills` - shared skills
- `~/.ai/tools/bin` - shared tools
- `~/.ai/plugins` - plugin packages
- `~/.ai/memory` - session memory files

## Required Component Contracts

- `~/.ai/systems/contracts/memory.md` - memory policy and checkpoint format
- `~/.ai/systems/contracts/agents.md` - agent selection and delegation contract
- `~/.ai/systems/contracts/tools.md` - shared tools contract
- `~/.ai/systems/contracts/safety.md` - safety and high-risk action contract

## Contract Loading Policy (Context Control)

Load contracts lazily by trigger:

- Load `memory.md` only when memory read/write/checkpoint behavior is needed.
- Load `agents.md` when selecting or delegating agents.
- Load `tools.md` when tool choice/permissions are relevant.
- Load `safety.md` for high-risk, destructive, or sensitive operations.

## Session Correlation (TID)

- If `TID` and `PROVIDER` are present in environment, include `TID=<value>` and `PROVIDER=<value>` exactly once before the first user-facing response of a new session. Do not repeat unless the user explicitly asks.
- Use `TID` and `PROVIDER` as the primary session correlation keys for transcript lookup and debugging.
- If either `TID` or `PROVIDER` is missing, explicitly state which value is missing and continue.

## Project Intelligence (Jumpstart)

The SessionStart hook automatically generates and maintains a jumpstart cache file at `~/.ai/cache/jumpstart/<hash>.json` (keyed by project path). This file contains cached project intelligence:

- **structure** — `tree -JL2` snapshot of the project layout
- **stack** — detected languages, frameworks, package manager, and key scripts
- **last_commit** — SHA and subject of HEAD when the cache was last written
- **is_git** — whether the project is tracked by git

The hook injects this data into session context automatically. The cache is updated incrementally when HEAD moves: sentinel files changing triggers stack re-detection, files added/deleted triggers structure re-scan, otherwise only the commit note updates.

The cache lives in `~/.ai/cache/jumpstart/` (not in the project directory) to avoid polluting repos. Do not manually edit it — the hook manages its lifecycle.

## Operating Rules

- Treat this file as the harness bootstrap source of truth.
- Use shared tools and skills before creating new local-only logic.
- Keep durable memory in `~/.ai/memory` following `~/.ai/systems/contracts/memory.md`.
- Never access any disallowed secret files (`.env.*` except `.env.local` and `.env.example`).

  ## Command Aliases
- If user message is exactly `summary`:
  1) Verify `$TID` and `$PROVIDER` are non-empty by running `echo $TID && echo $PROVIDER`. If either is empty, report which is missing and stop.
  2) Run `transcriptid --provider "$PROVIDER" --tid "$TID"`.
  3) If transcript resolution fails, report failure and stop (do not produce plain chat summary).
  4) Create/update a vault session note with `vault new session ...`. Do not include dates/timestamps in the title; `vault` already prefixes filenames with a timestamp.
  5) Write summary content into the note.
  6) Set frontmatter `transcript` to resolved transcript path.
  7) Reply only with note path and transcript path.
