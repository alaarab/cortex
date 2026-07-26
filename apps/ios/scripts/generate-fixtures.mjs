#!/usr/bin/env node
/**
 * Generates ground-truth fixtures for PhrenKit's parser/serializer tests by
 * running the REAL CLI functions against a temp store and snapshotting the
 * resulting files. Regenerate after CLI format changes:
 *
 *   pnpm --filter @phren/cli build
 *   node apps/ios/scripts/generate-fixtures.mjs
 *
 * A PhrenKit test failure after regeneration flags a format change that the
 * Swift transcriptions must absorb.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../../..");
const dist = path.join(repoRoot, "packages/cli/dist");
const fixturesDir = path.resolve(here, "../PhrenKit/Tests/PhrenKitTests/Fixtures");

const access = await import(path.join(dist, "data/access.js"));
const notes = await import(path.join(dist, "data/notes.js"));
const tasks = await import(path.join(dist, "data/tasks.js"));
const learning = await import(path.join(dist, "content/learning.js"));
const policy = await import(path.join(dist, "governance/policy.js"));

const store = fs.mkdtempSync(path.join(os.tmpdir(), "phren-fixtures-"));
const project = "myproj";
fs.mkdirSync(path.join(store, project), { recursive: true });
// A root manifest so path helpers treat this directory as a store root.
fs.writeFileSync(path.join(store, "phren.root.yaml"), "installMode: shared\nsyncMode: workspace-git\n");

fs.rmSync(fixturesDir, { recursive: true, force: true });
fs.mkdirSync(fixturesDir, { recursive: true });

function must(result, label) {
  if (result && result.ok === false) {
    throw new Error(`${label} failed: ${result.message}`);
  }
  return result;
}

function snapshot(name, relPath) {
  const src = path.join(store, relPath);
  const dest = path.join(fixturesDir, name);
  fs.copyFileSync(src, dest);
  console.log(`wrote ${name}`);
}

function writeJson(name, value) {
  fs.writeFileSync(path.join(fixturesDir, name), JSON.stringify(value, null, 2) + "\n");
  console.log(`wrote ${name}`);
}

// --- FINDINGS.md ------------------------------------------------------------

must(learning.addFindingToFile(store, project, "[pattern] Always validate JWT expiry before refresh", undefined, {
  provenance: { source: "human", machine: "test-machine", actor: "tester", tool: "phren-ios" },
}), "add finding 1");
must(learning.addFindingToFile(store, project, "[decision] Chose SQLite FTS5 over embeddings for v1 search", undefined, {
  scope: "builder",
}), "add finding 2");
must(learning.addFindingToFile(store, project, "Plain finding with no tag and no options"), "add finding 3");
snapshot("findings-after-add.md", `${project}/FINDINGS.md`);

must(access.editFinding(store, project, "Plain finding with no tag", "Edited finding text that replaced the plain one"), "edit finding");
snapshot("findings-after-edit.md", `${project}/FINDINGS.md`);

must(access.removeFinding(store, project, "Chose SQLite FTS5 over embeddings"), "remove finding");
snapshot("findings-after-remove.md", `${project}/FINDINGS.md`);

const parsedFindings = must(access.readFindings(store, project), "read findings");
writeJson("findings-parsed.json", parsedFindings.data);

// --- review.md --------------------------------------------------------------

must(policy.appendReviewQueue(store, project, "Review", [
  "- [pitfall] Session hooks fire twice when both MCP and hooks mode are enabled [confidence 0.85] <!-- source:agent machine:test-machine model:test-model -->",
  "- Low-confidence auto capture that should look risky [confidence 0.4]",
]), "append review queue");
must(policy.appendReviewQueue(store, project, "Stale", [
  "- Finding older than its decay window",
]), "append stale queue");
snapshot("review-seeded.md", `${project}/review.md`);

const queue = must(access.readReviewQueue(store, project), "read review queue");
writeJson("review-parsed.json", queue.data);

// Approve the first item, snapshot; then reject the second (which also
// touches FINDINGS.md — tolerated there since these entries aren't in it).
must(access.approveQueueItem(store, project, queue.data[0].line), "approve queue item");
snapshot("review-after-approve.md", `${project}/review.md`);

must(access.rejectQueueItem(store, project, queue.data[1].line), "reject queue item");
snapshot("review-after-reject.md", `${project}/review.md`);

const queue2 = must(access.readReviewQueue(store, project), "re-read review queue");
must(access.editQueueItem(store, project, queue2.data[0].line, "Edited stale entry text"), "edit queue item");
snapshot("review-after-edit.md", `${project}/review.md`);

// --- notes ------------------------------------------------------------------

const noteDate = "2026-07-25";
const noteTime = new Date("2026-07-25T14:30:05.000Z");
const n1 = must(notes.addNote(store, project, "First note of the day\n\nWith a second paragraph.", { date: noteDate, now: noteTime }), "add note 1");
must(notes.addNote(store, project, "Second note, single line", { date: noteDate, now: new Date("2026-07-25T15:00:00.000Z") }), "add note 2");
snapshot("notes-after-add.md", `${project}/notes/${noteDate}.md`);

must(notes.editNote(store, project, n1.data.stableId, "First note, edited"), "edit note");
must(notes.markNotePromoted(store, project, n1.data.stableId), "mark promoted");
snapshot("notes-after-edit-promote.md", `${project}/notes/${noteDate}.md`);

const parsedNotes = must(notes.listNotes(store, project), "list notes");
writeJson("notes-parsed.json", parsedNotes.data.map(({ path: _p, ...rest }) => rest));

// --- tasks.md ---------------------------------------------------------------

must(tasks.addTask(store, project, "Ship the iOS app [high]", { createdAt: "2026-07-20T10:00:00.000Z" }), "add task 1");
must(tasks.addTask(store, project, "Write fixture generator"), "add task 2");
must(tasks.addTask(store, project, "Investigate flaky sync test [low]"), "add task 3");
snapshot("tasks-after-add.md", `${project}/tasks.md`);

must(tasks.completeTask(store, project, "Write fixture generator"), "complete task");
snapshot("tasks-after-complete.md", `${project}/tasks.md`);

must(tasks.updateTask(store, project, "Investigate flaky sync test", { text: "Investigate flaky sync test on CI", priority: "medium", section: "Active" }), "update task");
snapshot("tasks-after-update.md", `${project}/tasks.md`);

const parsedTasks = must(tasks.readTasks(store, project), "read tasks");
const { path: _p, ...taskDoc } = parsedTasks.data;
writeJson("tasks-parsed.json", taskDoc);

fs.rmSync(store, { recursive: true, force: true });
console.log("done");
