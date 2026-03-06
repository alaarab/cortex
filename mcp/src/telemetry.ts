import * as fs from "fs";
import * as path from "path";

interface TelemetryConfig {
  enabled: boolean;
  enabledAt?: string;
}

interface UsageStats {
  toolCalls: Record<string, number>;
  cliCommands: Record<string, number>;
  errors: number;
  sessions: number;
  lastActive: string;
}

interface TelemetryData {
  config: TelemetryConfig;
  stats: UsageStats;
}

function telemetryPath(cortexPath: string): string {
  return path.join(cortexPath, ".governance", "telemetry.json");
}

function loadTelemetry(cortexPath: string): TelemetryData {
  const file = telemetryPath(cortexPath);
  const defaults: TelemetryData = {
    config: { enabled: false },
    stats: { toolCalls: {}, cliCommands: {}, errors: 0, sessions: 0, lastActive: "" },
  };
  if (!fs.existsSync(file)) return defaults;
  try {
    const raw = JSON.parse(fs.readFileSync(file, "utf8"));
    return {
      config: { ...defaults.config, ...raw.config },
      stats: { ...defaults.stats, ...raw.stats },
    };
  } catch {
    return defaults;
  }
}

function saveTelemetry(cortexPath: string, data: TelemetryData): void {
  const file = telemetryPath(cortexPath);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(data, null, 2) + "\n");
}

export function isTelemetryEnabled(cortexPath: string): boolean {
  return loadTelemetry(cortexPath).config.enabled;
}

export function setTelemetryEnabled(cortexPath: string, enabled: boolean): void {
  const data = loadTelemetry(cortexPath);
  data.config.enabled = enabled;
  if (enabled && !data.config.enabledAt) {
    data.config.enabledAt = new Date().toISOString();
  }
  saveTelemetry(cortexPath, data);
}

export function trackToolCall(cortexPath: string, toolName: string): void {
  const data = loadTelemetry(cortexPath);
  if (!data.config.enabled) return;
  data.stats.toolCalls[toolName] = (data.stats.toolCalls[toolName] || 0) + 1;
  data.stats.lastActive = new Date().toISOString();
  saveTelemetry(cortexPath, data);
}

export function trackCliCommand(cortexPath: string, command: string): void {
  const data = loadTelemetry(cortexPath);
  if (!data.config.enabled) return;
  data.stats.cliCommands[command] = (data.stats.cliCommands[command] || 0) + 1;
  data.stats.lastActive = new Date().toISOString();
  saveTelemetry(cortexPath, data);
}

export function trackError(cortexPath: string): void {
  const data = loadTelemetry(cortexPath);
  if (!data.config.enabled) return;
  data.stats.errors += 1;
  saveTelemetry(cortexPath, data);
}

export function trackSession(cortexPath: string): void {
  const data = loadTelemetry(cortexPath);
  if (!data.config.enabled) return;
  data.stats.sessions += 1;
  data.stats.lastActive = new Date().toISOString();
  saveTelemetry(cortexPath, data);
}

export function getTelemetrySummary(cortexPath: string): string {
  const data = loadTelemetry(cortexPath);
  if (!data.config.enabled) return "Telemetry: disabled (opt in with 'cortex config telemetry on')";

  const topTools = Object.entries(data.stats.toolCalls)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5)
    .map(([name, count]) => `  ${name}: ${count}`)
    .join("\n");

  const topCli = Object.entries(data.stats.cliCommands)
    .sort(([, a], [, b]) => b - a)
    .slice(0, 5)
    .map(([name, count]) => `  ${name}: ${count}`)
    .join("\n");

  const lines = [
    `Telemetry: enabled (since ${data.config.enabledAt || "unknown"})`,
    `Sessions: ${data.stats.sessions}`,
    `Errors: ${data.stats.errors}`,
    `Last active: ${data.stats.lastActive || "never"}`,
  ];
  if (topTools) lines.push("Top tools:", topTools);
  if (topCli) lines.push("Top CLI commands:", topCli);
  return lines.join("\n");
}

export function resetTelemetry(cortexPath: string): void {
  const data = loadTelemetry(cortexPath);
  data.stats = { toolCalls: {}, cliCommands: {}, errors: 0, sessions: 0, lastActive: "" };
  saveTelemetry(cortexPath, data);
}
