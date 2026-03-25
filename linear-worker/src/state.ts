import { readFileSync, writeFileSync, existsSync } from "node:fs";
import type { Config, TaskState, WorkerState, StateMap } from "./types.js";

const MAX_RETRY_ATTEMPTS = 3;

export class StateManager {
  private state: WorkerState;
  private stateFile: string;

  constructor(config: Config) {
    this.stateFile = config.stateFile;
    this.state = this.load();
  }

  private load(): WorkerState {
    if (existsSync(this.stateFile)) {
      try {
        const raw = readFileSync(this.stateFile, "utf-8");
        return JSON.parse(raw);
      } catch {
        console.warn(
          `Failed to parse state file ${this.stateFile}, starting fresh`
        );
      }
    }
    return { tasks: {} };
  }

  save(): void {
    writeFileSync(this.stateFile, JSON.stringify(this.state, null, 2));
  }

  cacheStateMap(stateMap: StateMap): void {
    this.state.stateMapCache = stateMap;
    this.save();
  }

  getCachedStateMap(): StateMap | undefined {
    return this.state.stateMapCache;
  }

  getTask(issueId: string): TaskState | undefined {
    return this.state.tasks[issueId];
  }

  isInFlight(issueId: string): boolean {
    const task = this.state.tasks[issueId];
    return task?.status === "in_progress";
  }

  hasAnyInFlight(): boolean {
    return Object.values(this.state.tasks).some(
      (t) => t.status === "in_progress"
    );
  }

  shouldPickUp(issueId: string): boolean {
    const task = this.state.tasks[issueId];
    if (!task) return true; // Never seen before
    if (task.status === "in_progress") return false; // Already working on it
    // Completed/blocked tasks CAN be re-picked up if they reappear in an
    // actionable lane — the user explicitly moved them back.
    return true;
  }

  canRetry(issueId: string): boolean {
    const task = this.state.tasks[issueId];
    if (!task) return false;
    if (task.status !== "blocked") return false;
    return task.attempts < MAX_RETRY_ATTEMPTS;
  }

  startTask(
    issueId: string,
    identifier: string,
    title: string,
    lane: "implement" | "plan"
  ): TaskState {
    const existing = this.state.tasks[issueId];
    const task: TaskState = {
      issueId,
      identifier,
      title,
      status: "in_progress",
      lane,
      startedAt: new Date().toISOString(),
      attempts: (existing?.attempts ?? 0) + 1,
      branchName: existing?.branchName,
      prUrl: existing?.prUrl,
      lastBotCommentId: existing?.lastBotCommentId,
    };
    this.state.tasks[issueId] = task;
    this.save();
    return task;
  }

  completeTask(issueId: string, prUrl?: string): void {
    const task = this.state.tasks[issueId];
    if (!task) return;
    task.status = "completed";
    task.completedAt = new Date().toISOString();
    if (prUrl) task.prUrl = prUrl;
    this.save();
  }

  blockTask(issueId: string, reason: string, botCommentId: string): void {
    const task = this.state.tasks[issueId];
    if (!task) return;
    task.status = "blocked";
    task.blockedAt = new Date().toISOString();
    task.blockedReason = reason;
    task.lastBotCommentId = botCommentId;
    this.save();
  }

  setBranchName(issueId: string, branchName: string): void {
    const task = this.state.tasks[issueId];
    if (!task) return;
    task.branchName = branchName;
    this.save();
  }

  setBotCommentId(issueId: string, commentId: string): void {
    const task = this.state.tasks[issueId];
    if (!task) return;
    task.lastBotCommentId = commentId;
    this.save();
  }

  getBlockedTasks(): TaskState[] {
    return Object.values(this.state.tasks).filter(
      (t) => t.status === "blocked" && t.attempts < MAX_RETRY_ATTEMPTS
    );
  }

  clearInFlightOnStartup(): void {
    // On service restart, any in-flight tasks should be treated as blocked
    for (const task of Object.values(this.state.tasks)) {
      if (task.status === "in_progress") {
        task.status = "blocked";
        task.blockedAt = new Date().toISOString();
        task.blockedReason =
          "Service restarted while task was in progress";
      }
    }
    this.save();
  }
}
