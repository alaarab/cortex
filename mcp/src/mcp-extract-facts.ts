/**
 * Structured fact extraction from findings.
 *
 * When CORTEX_FEATURE_FACT_EXTRACT=1, each new finding is passed to an LLM
 * that extracts a single structured preference or fact (e.g. "prefers X",
 * "avoids Y", "uses Z framework"). Extracted facts are stored in
 * <project>/preferences.json and surfaced in session_start context.
 *
 * Feature-flagged to keep the default code path fast and LLM-free.
 */

import * as fs from "fs";
import * as path from "path";
import { debugLog } from "./shared.js";
import { safeProjectPath } from "./utils.js";
import { callLlm } from "./content-dedup.js";

const FACT_EXTRACT_FLAG = "CORTEX_FEATURE_FACT_EXTRACT";
const MAX_FACTS = 50;

export interface ExtractedFact {
  fact: string;
  source: string; // truncated finding text
  at: string;     // ISO timestamp
}

function preferencesPath(cortexPath: string, project: string): string | null {
  const dir = safeProjectPath(cortexPath, project);
  return dir ? path.join(dir, "preferences.json") : null;
}

export function readExtractedFacts(cortexPath: string, project: string): ExtractedFact[] {
  const p = preferencesPath(cortexPath, project);
  if (!p || !fs.existsSync(p)) return [];
  try {
    const data = JSON.parse(fs.readFileSync(p, "utf8"));
    return Array.isArray(data) ? data : [];
  } catch { return []; }
}

function writeExtractedFacts(cortexPath: string, project: string, facts: ExtractedFact[]): void {
  const p = preferencesPath(cortexPath, project);
  if (!p) return;
  try {
    const trimmed = facts.slice(-MAX_FACTS);
    const tmp = p + ".tmp";
    fs.writeFileSync(tmp, JSON.stringify(trimmed, null, 2));
    fs.renameSync(tmp, p);
  } catch (err: unknown) {
    debugLog(`writeExtractedFacts: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/**
 * Fire-and-forget: extract a structured fact from a new finding using an LLM.
 * Skips silently if the feature flag is off or no LLM is configured.
 */
export function extractFactFromFinding(cortexPath: string, project: string, finding: string): void {
  const flag = process.env[FACT_EXTRACT_FLAG];
  if (!flag || !["1", "true", "on", "yes"].includes(flag.trim().toLowerCase())) return;

  // No LLM keys configured — skip
  if (!process.env.CORTEX_LLM_ENDPOINT && !process.env.ANTHROPIC_API_KEY && !process.env.OPENAI_API_KEY) return;

  void (async () => {
    try {
      const prompt =
        `Extract a single user preference, technology choice, or architectural fact from this finding. ` +
        `Return ONLY a short statement in the format "prefers X", "uses Y", "avoids Z", ` +
        `or "decided to X because Y". If no clear preference or fact exists, return "none".\n\nFinding: ${finding.slice(0, 500)}`;

      const raw = await callLlm(prompt, undefined, 60);
      if (!raw || raw.toLowerCase() === "none") return;

      const existing = readExtractedFacts(cortexPath, project);
      // Deduplicate: skip if very similar fact already stored (simple substring check)
      const normalized = raw.toLowerCase();
      if (existing.some(f => f.fact.toLowerCase() === normalized)) return;

      existing.push({ fact: raw, source: finding.slice(0, 120), at: new Date().toISOString() });
      writeExtractedFacts(cortexPath, project, existing);
    } catch (err: unknown) {
      debugLog(`extractFactFromFinding: ${err instanceof Error ? err.message : String(err)}`);
    }
  })();
}
