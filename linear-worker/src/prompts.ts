import { readFileSync } from "node:fs";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { LinearIssue } from "./types.js";

const AI_HOME = process.env.AI_HOME ?? `${process.env.HOME}/.ai`;
const PROMPTS_DIR = join(AI_HOME, "systems", "prompts");

function readTemplate(filename: string): string {
  const path = join(PROMPTS_DIR, filename);
  try {
    return readFileSync(path, "utf-8");
  } catch {
    throw new Error(`Prompt template not found: ${path}`);
  }
}

function buildContext(issue: LinearIssue): string {
  let context = `## Task: ${issue.identifier} — ${issue.title}\n\n`;
  context += `**Linear URL:** ${issue.url}\n\n`;
  if (issue.description) {
    context += `## Description\n\n${issue.description}\n\n`;
  }
  return context;
}

export function generateImplementPrompt(issue: LinearIssue): string {
  const template = readTemplate("linear-implement.md");
  const context = buildContext(issue);
  return `${context}\n\n${template}`;
}

export function generatePlanPrompt(issue: LinearIssue): string {
  const template = readTemplate("linear-plan.md");
  const context = buildContext(issue);
  return `${context}\n\n${template}`;
}

export function generateRetryPrompt(
  issue: LinearIssue,
  blockedReason: string,
  humanReply: string
): string {
  const template = readTemplate("linear-retry.md");
  const context = buildContext(issue);
  const retryContext =
    `## Previous Blocker\n\n${blockedReason}\n\n` +
    `## Reply / Guidance\n\n${humanReply}\n\n`;
  return `${context}\n\n${retryContext}\n\n${template}`;
}

export function writePromptFile(
  issueIdentifier: string,
  content: string
): string {
  const filename = `linear-prompt-${issueIdentifier.toLowerCase()}.md`;
  const filepath = join(tmpdir(), filename);
  writeFileSync(filepath, content);
  return filepath;
}
