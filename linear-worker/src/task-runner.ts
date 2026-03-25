import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import type { Config, LinearIssue, TaskResult } from "./types.js";
import {
  generateImplementPrompt,
  generatePlanPrompt,
  generateRetryPrompt,
  writePromptFile,
} from "./prompts.js";

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 40);
}

function readFileIfExists(path: string): string | undefined {
  try {
    if (existsSync(path)) {
      return readFileSync(path, "utf-8").trim();
    }
  } catch {
    // ignore
  }
  return undefined;
}

function runCommand(
  command: string,
  args: string[],
  cwd: string
): Promise<number> {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      cwd,
      stdio: "inherit",
      env: process.env,
    });
    proc.on("close", (code) => resolve(code ?? 1));
    proc.on("error", () => resolve(1));
  });
}

function runCommandCapture(
  command: string,
  args: string[],
  cwd: string
): Promise<{ exitCode: number; stdout: string }> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    const proc = spawn(command, args, {
      cwd,
      stdio: ["inherit", "pipe", "inherit"],
      env: process.env,
    });
    proc.stdout.on("data", (chunk: Buffer) => {
      chunks.push(chunk);
      process.stdout.write(chunk);
    });
    proc.on("close", (code) =>
      resolve({ exitCode: code ?? 1, stdout: Buffer.concat(chunks).toString() })
    );
    proc.on("error", () => resolve({ exitCode: 1, stdout: "" }));
  });
}

/**
 * Runs a command and formats stream-json output into readable logs.
 * Extracts Claude's text, tool calls, and tool results while dropping noise.
 */
function runCommandFormatted(
  command: string,
  args: string[],
  cwd: string
): Promise<number> {
  return new Promise((resolve) => {
    const proc = spawn(command, args, {
      cwd,
      stdio: ["inherit", "pipe", "pipe"],
      env: process.env,
    });

    let buffer = "";

    proc.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed) continue;

        // Pass through non-JSON lines (ralph's own logs)
        if (!trimmed.startsWith("{")) {
          console.log(trimmed);
          continue;
        }

        try {
          const event = JSON.parse(trimmed);
          formatStreamEvent(event);
        } catch {
          // Not valid JSON, print as-is
          console.log(trimmed);
        }
      }
    });

    proc.stderr.on("data", (chunk: Buffer) => {
      process.stderr.write(chunk);
    });

    proc.on("close", (code) => resolve(code ?? 1));
    proc.on("error", () => resolve(1));
  });
}

function formatStreamEvent(event: Record<string, unknown>): void {
  const type = event.type as string;
  const msg = event.message as Record<string, unknown> | undefined;

  if (type === "assistant" && msg?.content) {
    const content = msg.content as Array<Record<string, unknown>>;
    for (const block of content) {
      if (block.type === "text" && block.text) {
        console.log(`\n  Claude: ${block.text}`);
      } else if (block.type === "tool_use") {
        const name = block.name as string;
        const input = block.input as Record<string, unknown>;
        if (name === "Bash") {
          console.log(`\n  > ${name}: ${input.command ?? ""}`);
        } else if (name === "Read") {
          console.log(`\n  > ${name}: ${input.file_path ?? ""}`);
        } else if (name === "Write") {
          console.log(`\n  > ${name}: ${input.file_path ?? ""}`);
        } else if (name === "Edit") {
          console.log(`\n  > ${name}: ${input.file_path ?? ""}`);
        } else if (name === "Grep") {
          console.log(`\n  > ${name}: "${input.pattern ?? ""}" in ${input.path ?? "."}`);
        } else if (name === "Glob") {
          console.log(`\n  > ${name}: ${input.pattern ?? ""}`);
        } else {
          console.log(`\n  > ${name}`);
        }
      }
    }
  } else if (type === "result") {
    const subtype = event.subtype as string;
    const cost = event.total_cost_usd as number | undefined;
    const turns = event.num_turns as number | undefined;
    console.log(
      `\n  [Result: ${subtype}${turns ? `, ${turns} turns` : ""}${cost ? `, $${cost.toFixed(4)}` : ""}]`
    );
  }
  // Skip: user (tool results), system, and other noise
}

export class TaskRunner {
  private config: Config;

  constructor(config: Config) {
    this.config = config;
  }

  private branchName(issue: LinearIssue): string {
    const slug = slugify(issue.title);
    return `claude/${issue.identifier.toLowerCase()}-${slug}`;
  }

  async prepareWorkspace(
    issue: LinearIssue,
    lane: "implement" | "plan"
  ): Promise<string> {
    const workspace = this.config.workspace;
    const branch = this.branchName(issue);

    if (lane === "implement") {
      // Try creating the branch; if it already exists, just check it out
      const exitCode = await runCommand("host-checkout", ["-b", branch], workspace);
      if (exitCode !== 0) {
        await runCommand("host-checkout", [branch], workspace);
      }
    }

    // Write ralph's required files
    const taskDescription =
      lane === "implement"
        ? `Implement: ${issue.title}`
        : `Create implementation plan: ${issue.title}`;

    writeFileSync(
      join(workspace, "tasks.md"),
      `- [ ] ${taskDescription}\n`
    );
    writeFileSync(join(workspace, "status.md"), "Status: working\n");

    return branch;
  }

  async runTask(
    issue: LinearIssue,
    lane: "implement" | "plan",
    retryContext?: { blockedReason: string; humanReply: string }
  ): Promise<TaskResult> {
    const workspace = this.config.workspace;

    // Generate the prompt
    let promptContent: string;
    if (retryContext) {
      promptContent = generateRetryPrompt(
        issue,
        retryContext.blockedReason,
        retryContext.humanReply
      );
    } else if (lane === "implement") {
      promptContent = generateImplementPrompt(issue);
    } else {
      promptContent = generatePlanPrompt(issue);
    }

    const promptPath = writePromptFile(issue.identifier, promptContent);

    // Prepare workspace (branch for implement, just files for plan)
    const branch = await this.prepareWorkspace(issue, lane);

    // Build ralph args — plan tasks run in plan mode (read-only, single iteration)
    const isPlan = lane === "plan" && !retryContext;
    const ralphArgs = [
      "--cli",
      "claude",
      "--prompt-file",
      promptPath,
      "--workspace",
      workspace,
      "--max-iterations",
      isPlan ? "1" : String(this.config.maxIterations),
      "--model",
      this.config.model,
    ];

    if (isPlan) {
      ralphArgs.push("--permission-mode", "plan");
    }

    // Stream JSON events so we can see Claude's work in real time
    ralphArgs.push("--", "--output-format", "stream-json", "--verbose");

    console.log(
      `[task-runner] Spawning ralph for ${issue.identifier} (${lane}${isPlan ? ", plan mode" : ""})...`
    );
    if (lane === "implement") {
      console.log(`[task-runner] Branch: ${branch}`);
    }
    console.log(`[task-runner] Prompt: ${promptPath}`);

    if (isPlan) {
      // Plan mode: capture stdout as the plan output (Claude can't write files in plan mode)
      const { exitCode, stdout } = await runCommandCapture(
        "ralph",
        ralphArgs,
        workspace
      );

      console.log(`[task-runner] Ralph exited with code ${exitCode}`);

      const result: TaskResult = { success: exitCode === 0 };

      if (result.success) {
        // Extract plan from Claude's stdout (strip ralph log lines)
        result.plan = extractPlanFromOutput(stdout);
        if (!result.plan) {
          result.success = false;
          result.blockedReason = "Claude produced no plan output";
        }
      } else {
        result.blockedReason = `Ralph exited with code ${exitCode}`;
      }

      try {
        unlinkSync(promptPath);
      } catch {
        // ignore
      }

      return result;
    }

    // Non-plan tasks (implement + plan retries): run normally, read output files
    const exitCode = await runCommand("ralph", ralphArgs, workspace);

    console.log(`[task-runner] Ralph exited with code ${exitCode}`);

    // Read status.md to determine outcome
    const statusContent =
      readFileIfExists(join(workspace, "status.md")) ?? "";
    const statusMatch = statusContent.match(/Status:\s*(\w+)/);
    const status = statusMatch?.[1] ?? "blocked";

    // Collect results based on lane
    const result: TaskResult = { success: status === "done" };

    if (result.success) {
      if (lane === "implement") {
        result.prUrl = readFileIfExists(join(workspace, "pr-url.txt"));
        result.testResults = readFileIfExists(
          join(workspace, "test-results.txt")
        );
      } else {
        // Plan retry — Claude writes to plan-output.md
        result.plan = readFileIfExists(join(workspace, "plan-output.md"));
      }
    } else {
      result.blockedReason =
        readFileIfExists(join(workspace, "why_blocked.md")) ??
        `Ralph exited with code ${exitCode}, status: ${status}`;
    }

    // Clean up prompt file
    try {
      unlinkSync(promptPath);
    } catch {
      // ignore
    }

    return result;
  }

  async cleanWorkspace(): Promise<void> {
    const workspace = this.config.workspace;

    // Remove worker-generated files
    const filesToClean = [
      "tasks.md",
      "status.md",
      "why_blocked.md",
      "pr-url.txt",
      "plan-output.md",
      "test-results.txt",
    ];

    for (const file of filesToClean) {
      try {
        const path = join(workspace, file);
        if (existsSync(path)) unlinkSync(path);
      } catch {
        // ignore
      }
    }

    // Discard any uncommitted changes from blocked/failed tasks so the next
    // task starts with a clean workspace. host-reset restores tracked files,
    // host-git clean removes untracked files created during the task.
    await runCommand("host-reset", ["--hard"], workspace);
    await runCommand("host-git", ["clean", "-fd"], workspace);

    // Return to default branch (detect main/master/develop)
    const { stdout } = await runCommandCapture(
      "host-git",
      ["branch", "--list", "main", "master", "develop"],
      workspace
    );
    const defaultBranch = stdout.trim().split("\n")
      .map(b => b.replace(/^\*?\s*/, "").trim())
      .find(b => b) ?? "master";
    await runCommand("host-checkout", [defaultBranch], workspace);
  }
}

function extractPlanFromOutput(stdout: string): string | undefined {
  // Filter out ralph's own log lines and extract Claude's actual output.
  // Ralph logs start with "Ralph:", "===", "Stopping:", "Status:", "All tasks", "Max iterations", "Loop completed"
  // Claude's JSON output (--output-format json) wraps the response.
  const lines = stdout.split("\n");
  const contentLines: string[] = [];

  for (const line of lines) {
    // Skip ralph's log lines
    if (
      /^(Ralph:|===|Stopping:|Status:|All tasks|Max iterations|Loop completed|Prompt file:|Iteration timeout:|\s*$)/.test(
        line
      )
    ) {
      continue;
    }

    // Try to parse as JSON (Claude's --output-format json output)
    try {
      const parsed = JSON.parse(line);
      if (parsed.result) {
        return parsed.result;
      }
      if (parsed.content) {
        return typeof parsed.content === "string"
          ? parsed.content
          : JSON.stringify(parsed.content);
      }
    } catch {
      // Not JSON, include as raw content
      contentLines.push(line);
    }
  }

  const content = contentLines.join("\n").trim();
  return content || undefined;
}
