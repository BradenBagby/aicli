import { LinearClient, type Issue, type Comment } from "@linear/sdk";
import type { Config, StateMap, LinearIssue } from "./types.js";

const LANE_NAMES: (keyof StateMap)[] = [
  "implement",
  "createPlan",
  "inProgress",
  "blocked",
  "prSubmitted",
  "planNeedsReview",
];

// Maps Linear workflow state names (as they appear in Linear) to our internal keys
const STATE_NAME_MAP: Record<string, keyof StateMap> = {
  Implement: "implement",
  "Create Plan": "createPlan",
  "In Progress": "inProgress",
  Blocked: "blocked",
  "PR Submitted": "prSubmitted",
  "Plan Needs Review": "planNeedsReview",
};

export class LinearTaskClient {
  private client: LinearClient;
  private teamId: string;
  private stateMap: StateMap | null = null;

  constructor(config: Config) {
    this.client = new LinearClient({ apiKey: config.linearApiKey });
    this.teamId = config.linearTeamId;
  }

  async initStateMap(): Promise<StateMap> {
    const team = await this.client.team(this.teamId);
    const states = await team.states();

    const map: Partial<StateMap> = {};

    for (const state of states.nodes) {
      const key = STATE_NAME_MAP[state.name];
      if (key) {
        map[key] = state.id;
      }
    }

    // Verify all required states are found
    const missing = LANE_NAMES.filter((k) => !map[k]);
    if (missing.length > 0) {
      throw new Error(
        `Missing workflow states in Linear team: ${missing.join(", ")}. ` +
          `Expected states: ${Object.keys(STATE_NAME_MAP).join(", ")}`
      );
    }

    this.stateMap = map as StateMap;
    return this.stateMap;
  }

  getStateMap(): StateMap {
    if (!this.stateMap) {
      throw new Error("State map not initialized. Call initStateMap() first.");
    }
    return this.stateMap;
  }

  async pollActionableTasks(): Promise<LinearIssue[]> {
    const stateMap = this.getStateMap();

    const issues = await this.client.issues({
      filter: {
        team: { id: { eq: this.teamId } },
        state: {
          id: { in: [stateMap.implement, stateMap.createPlan] },
        },
      },
    });

    return issues.nodes.map((issue) => this.mapIssue(issue));
  }

  async pollBlockedIssues(): Promise<LinearIssue[]> {
    const stateMap = this.getStateMap();

    const issues = await this.client.issues({
      filter: {
        team: { id: { eq: this.teamId } },
        state: {
          id: { eq: stateMap.blocked },
        },
      },
    });

    return issues.nodes.map((issue) => this.mapIssue(issue));
  }

  async getIssueComments(issueId: string): Promise<Comment[]> {
    const issue = await this.client.issue(issueId);
    const comments = await issue.comments();
    return comments.nodes;
  }

  async findHumanReplyAfter(
    issueId: string,
    afterCommentId: string
  ): Promise<Comment | null> {
    const comments = await this.getIssueComments(issueId);

    // Sort by creation date ascending
    const sorted = [...comments].sort(
      (a, b) =>
        new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime()
    );

    // Find the bot comment index
    const botIdx = sorted.findIndex((c) => c.id === afterCommentId);
    if (botIdx === -1) return null;

    // Look for a comment after the bot comment that isn't from our bot
    // (bot comments typically have a specific pattern we set)
    for (let i = botIdx + 1; i < sorted.length; i++) {
      const comment = sorted[i];
      // If the comment body doesn't start with our bot prefix, it's a human reply
      if (!comment.body.startsWith("[linear-worker]")) {
        return comment;
      }
    }

    return null;
  }

  async getIssueState(
    issueId: string
  ): Promise<{ stateId: string; stateName: string }> {
    const issue = await this.client.issue(issueId);
    const state = await issue.state;
    if (!state) throw new Error(`Issue ${issueId} has no state`);
    return { stateId: state.id, stateName: state.name };
  }

  async getIssueLane(issueId: string): Promise<"implement" | "plan" | null> {
    const { stateId } = await this.getIssueState(issueId);
    const stateMap = this.getStateMap();
    if (stateId === stateMap.implement) return "implement";
    if (stateId === stateMap.createPlan) return "plan";
    return null;
  }

  async getFullIssueDetails(
    issueId: string
  ): Promise<{ title: string; description: string | undefined; url: string; identifier: string }> {
    const issue = await this.client.issue(issueId);
    return {
      title: issue.title,
      description: issue.description ?? undefined,
      url: issue.url,
      identifier: issue.identifier,
    };
  }

  async moveToState(
    issueId: string,
    state: keyof StateMap
  ): Promise<void> {
    const stateMap = this.getStateMap();
    const stateId = stateMap[state];
    await this.client.updateIssue(issueId, { stateId });
  }

  async addComment(issueId: string, body: string): Promise<string> {
    const prefixedBody = `[linear-worker] ${body}`;
    const payload = await this.client.createComment({
      issueId,
      body: prefixedBody,
    });
    const comment = await payload.comment;
    return comment?.id ?? "";
  }

  async updateIssueBody(
    issueId: string,
    appendContent: string
  ): Promise<void> {
    const issue = await this.client.issue(issueId);
    const existingBody = issue.description ?? "";
    const updatedBody = existingBody + "\n\n---\n\n## Implementation Plan\n\n" + appendContent;
    await this.client.updateIssue(issueId, { description: updatedBody });
  }

  private mapIssue(issue: Issue): LinearIssue {
    return {
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      description: issue.description ?? undefined,
      url: issue.url,
    };
  }
}
