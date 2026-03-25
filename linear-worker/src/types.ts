export interface TaskState {
  issueId: string;
  identifier: string; // e.g. "CLA-42"
  title: string;
  status: "in_progress" | "completed" | "blocked";
  lane: "implement" | "plan";
  startedAt: string;
  completedAt?: string;
  blockedAt?: string;
  blockedReason?: string;
  attempts: number;
  branchName?: string;
  prUrl?: string;
  lastBotCommentId?: string;
}

export interface WorkerState {
  tasks: Record<string, TaskState>;
  stateMapCache?: StateMap;
}

export interface StateMap {
  implement: string;
  createPlan: string;
  inProgress: string;
  blocked: string;
  prSubmitted: string;
  planNeedsReview: string;
}

export interface LinearIssue {
  id: string;
  identifier: string;
  title: string;
  description?: string;
  url: string;
}

export interface TaskResult {
  success: boolean;
  prUrl?: string;
  plan?: string;
  blockedReason?: string;
  testResults?: string;
}

export interface Config {
  linearApiKey: string;
  linearTeamId: string;
  pollInterval: number;
  maxIterations: number;
  model: string;
  stateFile: string;
  workspace: string;
}
