import { describe, it, expect, beforeEach, afterEach } from "vitest";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import {
  isTelemetryEnabled,
  setTelemetryEnabled,
  trackToolCall,
  trackCliCommand,
  trackError,
  trackSession,
  getTelemetrySummary,
  resetTelemetry,
} from "./telemetry.js";

let tmpDir: string;

beforeEach(() => {
  tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "cortex-telemetry-test-"));
  fs.mkdirSync(path.join(tmpDir, ".governance"), { recursive: true });
});

afterEach(() => {
  fs.rmSync(tmpDir, { recursive: true, force: true });
});

describe("telemetry", () => {
  it("defaults to disabled", () => {
    expect(isTelemetryEnabled(tmpDir)).toBe(false);
  });

  it("can be enabled and disabled", () => {
    setTelemetryEnabled(tmpDir, true);
    expect(isTelemetryEnabled(tmpDir)).toBe(true);

    setTelemetryEnabled(tmpDir, false);
    expect(isTelemetryEnabled(tmpDir)).toBe(false);
  });

  it("records enabledAt timestamp on first enable", () => {
    setTelemetryEnabled(tmpDir, true);
    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.config.enabledAt).toBeTruthy();
    expect(new Date(data.config.enabledAt).getTime()).toBeGreaterThan(0);
  });

  it("does not track when disabled", () => {
    trackToolCall(tmpDir, "search_knowledge");
    trackCliCommand(tmpDir, "search");
    trackError(tmpDir);
    trackSession(tmpDir);

    // File should not exist since telemetry is disabled and no writes happened
    const file = path.join(tmpDir, ".governance", "telemetry.json");
    expect(fs.existsSync(file)).toBe(false);
  });

  it("tracks tool calls when enabled", () => {
    setTelemetryEnabled(tmpDir, true);
    trackToolCall(tmpDir, "search_knowledge");
    trackToolCall(tmpDir, "search_knowledge");
    trackToolCall(tmpDir, "add_learning");

    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.stats.toolCalls.search_knowledge).toBe(2);
    expect(data.stats.toolCalls.add_learning).toBe(1);
  });

  it("tracks CLI commands when enabled", () => {
    setTelemetryEnabled(tmpDir, true);
    trackCliCommand(tmpDir, "search");
    trackCliCommand(tmpDir, "doctor");
    trackCliCommand(tmpDir, "search");

    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.stats.cliCommands.search).toBe(2);
    expect(data.stats.cliCommands.doctor).toBe(1);
  });

  it("tracks errors when enabled", () => {
    setTelemetryEnabled(tmpDir, true);
    trackError(tmpDir);
    trackError(tmpDir);

    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.stats.errors).toBe(2);
  });

  it("tracks sessions and updates lastActive", () => {
    setTelemetryEnabled(tmpDir, true);
    trackSession(tmpDir);
    trackSession(tmpDir);
    trackSession(tmpDir);

    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.stats.sessions).toBe(3);
    expect(data.stats.lastActive).toBeTruthy();
  });

  it("resets stats without changing config", () => {
    setTelemetryEnabled(tmpDir, true);
    trackToolCall(tmpDir, "search_knowledge");
    trackSession(tmpDir);
    trackError(tmpDir);

    resetTelemetry(tmpDir);

    const data = JSON.parse(
      fs.readFileSync(path.join(tmpDir, ".governance", "telemetry.json"), "utf8")
    );
    expect(data.config.enabled).toBe(true);
    expect(data.stats.toolCalls).toEqual({});
    expect(data.stats.sessions).toBe(0);
    expect(data.stats.errors).toBe(0);
  });

  it("returns disabled summary when off", () => {
    const summary = getTelemetrySummary(tmpDir);
    expect(summary).toContain("disabled");
    expect(summary).toContain("opt in");
  });

  it("returns usage summary when enabled with data", () => {
    setTelemetryEnabled(tmpDir, true);
    trackToolCall(tmpDir, "search_knowledge");
    trackToolCall(tmpDir, "search_knowledge");
    trackCliCommand(tmpDir, "doctor");
    trackSession(tmpDir);

    const summary = getTelemetrySummary(tmpDir);
    expect(summary).toContain("enabled");
    expect(summary).toContain("Sessions: 1");
    expect(summary).toContain("search_knowledge: 2");
    expect(summary).toContain("doctor: 1");
  });

  it("handles corrupted telemetry file gracefully", () => {
    fs.writeFileSync(
      path.join(tmpDir, ".governance", "telemetry.json"),
      "not valid json"
    );
    // Should not throw, should return defaults
    expect(isTelemetryEnabled(tmpDir)).toBe(false);
    expect(getTelemetrySummary(tmpDir)).toContain("disabled");
  });
});
