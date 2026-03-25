import { loadConfig } from "./config.js";
import { LinearTaskClient } from "./linear-client.js";
import { StateManager } from "./state.js";
import { TaskRunner } from "./task-runner.js";
import type { Config, LinearIssue, TaskState } from "./types.js";

let shuttingDown = false;
let taskInFlight = false;

async function main(): Promise<void> {
  console.log("[linear-worker] Starting...");

  const config = loadConfig();
  const linearClient = new LinearTaskClient(config);
  const stateManager = new StateManager(config);
  const taskRunner = new TaskRunner(config);

  // Recover from crash: mark any in-flight tasks as blocked
  stateManager.clearInFlightOnStartup();

  // Initialize workflow state map (fetch from Linear or use cache)
  console.log("[linear-worker] Fetching workflow states from Linear...");
  const stateMap = await linearClient.initStateMap();
  stateManager.cacheStateMap(stateMap);
  console.log("[linear-worker] Workflow states initialized.");

  // Graceful shutdown
  const shutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log("\n[linear-worker] Shutting down gracefully...");
    if (!taskInFlight) process.exit(0);
    // If a task is in flight, let it finish (ralph handles its own timeouts)
    console.log("[linear-worker] Waiting for current task to complete...");
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);

  console.log(
    `[linear-worker] Polling every ${config.pollInterval / 1000}s for tasks on team ${config.linearTeamId}`
  );

  // Initial poll immediately, then on interval
  await pollLoop(config, linearClient, stateManager, taskRunner);

  setInterval(async () => {
    try {
      await pollLoop(config, linearClient, stateManager, taskRunner);
    } catch (err) {
      console.error("[linear-worker] Poll error:", err);
    }
  }, config.pollInterval);
}

async function pollLoop(
  config: Config,
  linearClient: LinearTaskClient,
  stateManager: StateManager,
  taskRunner: TaskRunner
): Promise<void> {
  if (shuttingDown || taskInFlight) return;

  // 1. Check blocked tasks for human replies (retry flow)
  const blockedTasks = stateManager.getBlockedTasks();
  for (const blockedTask of blockedTasks) {
    if (!blockedTask.lastBotCommentId) continue;

    try {
      const reply = await linearClient.findHumanReplyAfter(
        blockedTask.issueId,
        blockedTask.lastBotCommentId
      );

      if (reply && stateManager.canRetry(blockedTask.issueId)) {
        console.log(
          `[linear-worker] Found reply on blocked task ${blockedTask.identifier}, retrying...`
        );
        await executeTask(
          config,
          linearClient,
          stateManager,
          taskRunner,
          {
            id: blockedTask.issueId,
            identifier: blockedTask.identifier,
            title: blockedTask.title,
            url: "",
          },
          blockedTask.lane,
          {
            blockedReason: blockedTask.blockedReason ?? "Unknown",
            humanReply: reply.body,
          }
        );
        return; // Only one task at a time
      }
    } catch (err) {
      console.error(
        `[linear-worker] Error checking blocked task ${blockedTask.identifier}:`,
        err
      );
    }
  }

  // 2. Poll for new actionable tasks
  let tasks: LinearIssue[];
  try {
    tasks = await linearClient.pollActionableTasks();
  } catch (err) {
    console.error("[linear-worker] Error polling tasks:", err);
    return;
  }

  if (tasks.length === 0) return;

  // Pick the first task we haven't already processed
  for (const task of tasks) {
    if (!stateManager.shouldPickUp(task.id)) continue;

    // Determine lane
    const lane = await linearClient.getIssueLane(task.id);
    if (!lane) continue;

    console.log(
      `[linear-worker] Picking up task ${task.identifier}: "${task.title}" (${lane})`
    );

    await executeTask(
      config,
      linearClient,
      stateManager,
      taskRunner,
      task,
      lane
    );
    return; // Only one task at a time
  }
}

async function executeTask(
  config: Config,
  linearClient: LinearTaskClient,
  stateManager: StateManager,
  taskRunner: TaskRunner,
  issue: LinearIssue,
  lane: "implement" | "plan",
  retryContext?: { blockedReason: string; humanReply: string }
): Promise<void> {
  taskInFlight = true;
  const isRetry = !!retryContext;

  try {
    // Move to In Progress
    await linearClient.moveToState(issue.id, "inProgress");
    const startComment = isRetry
      ? "Retrying with new guidance..."
      : `Starting ${lane === "implement" ? "implementation" : "plan creation"}...`;
    const commentId = await linearClient.addComment(issue.id, startComment);

    // Track in state
    const taskState = stateManager.startTask(
      issue.id,
      issue.identifier,
      issue.title,
      lane
    );
    stateManager.setBotCommentId(issue.id, commentId);

    // Get full issue details for the prompt
    const details = await linearClient.getFullIssueDetails(issue.id);
    const fullIssue: LinearIssue = {
      id: issue.id,
      identifier: details.identifier,
      title: details.title,
      description: details.description,
      url: details.url,
    };

    // Run the task
    const result = await taskRunner.runTask(fullIssue, lane, retryContext);

    if (result.success) {
      if (lane === "implement") {
        // Move to PR Submitted
        await linearClient.moveToState(issue.id, "prSubmitted");

        let comment = result.prUrl
          ? `PR submitted: ${result.prUrl}`
          : "Implementation complete.";
        if (result.testResults) {
          comment += `\n\n**Test Results:**\n\`\`\`\n${result.testResults}\n\`\`\``;
        }
        await linearClient.addComment(issue.id, comment);
        stateManager.completeTask(issue.id, result.prUrl);
      } else {
        // Plan: update issue body and move to Plan Needs Review
        if (result.plan) {
          await linearClient.updateIssueBody(issue.id, result.plan);
        }
        await linearClient.moveToState(issue.id, "planNeedsReview");
        await linearClient.addComment(
          issue.id,
          "Implementation plan added to issue body."
        );
        stateManager.completeTask(issue.id);
      }

      console.log(
        `[linear-worker] Task ${issue.identifier} completed successfully.`
      );
    } else {
      // Blocked
      await linearClient.moveToState(issue.id, "blocked");
      const blockedComment = await linearClient.addComment(
        issue.id,
        `Blocked: ${result.blockedReason ?? "Unknown error"}`
      );
      stateManager.blockTask(
        issue.id,
        result.blockedReason ?? "Unknown error",
        blockedComment
      );

      console.log(
        `[linear-worker] Task ${issue.identifier} blocked: ${result.blockedReason}`
      );
    }
  } catch (err) {
    console.error(
      `[linear-worker] Error executing task ${issue.identifier}:`,
      err
    );

    // Try to move to blocked in Linear
    try {
      const errMsg =
        err instanceof Error ? err.message : "Unexpected error in linear-worker";
      const blockedComment = await linearClient.addComment(
        issue.id,
        `Blocked (worker error): ${errMsg}`
      );
      await linearClient.moveToState(issue.id, "blocked");
      stateManager.blockTask(issue.id, errMsg, blockedComment);
    } catch {
      console.error(
        "[linear-worker] Failed to update Linear after error"
      );
    }
  } finally {
    // Always clean up
    try {
      await taskRunner.cleanWorkspace();
    } catch (err) {
      console.error("[linear-worker] Error cleaning workspace:", err);
    }

    taskInFlight = false;

    if (shuttingDown) {
      console.log("[linear-worker] Task complete, shutting down.");
      process.exit(0);
    }
  }
}

main().catch((err) => {
  console.error("[linear-worker] Fatal error:", err);
  process.exit(1);
});
