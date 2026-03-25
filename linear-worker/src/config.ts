import type { Config } from "./types.js";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Required environment variable ${name} is not set`);
  }
  return value;
}

function optionalEnv(name: string, defaultValue: string): string {
  return process.env[name] || defaultValue;
}

function optionalEnvInt(name: string, defaultValue: number): number {
  const raw = process.env[name];
  if (!raw) return defaultValue;
  const parsed = parseInt(raw, 10);
  if (isNaN(parsed)) {
    throw new Error(`Environment variable ${name} must be an integer, got: ${raw}`);
  }
  return parsed;
}

export function loadConfig(): Config {
  return {
    linearApiKey: requireEnv("LINEAR_API_KEY"),
    linearTeamId: requireEnv("LINEAR_TEAM_ID"),
    pollInterval: optionalEnvInt("LINEAR_POLL_INTERVAL", 30000),
    maxIterations: optionalEnvInt("LINEAR_MAX_ITERATIONS", 10),
    model: optionalEnv("LINEAR_MODEL", "sonnet"),
    stateFile: optionalEnv(
      "LINEAR_STATE_FILE",
      "/tmp/linear-worker-state.json"
    ),
    workspace: optionalEnv("LINEAR_WORKSPACE", "/workspace"),
  };
}
