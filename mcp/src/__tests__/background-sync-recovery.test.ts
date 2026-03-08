import { beforeEach, afterEach, describe, expect, it } from "vitest";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { makeTempDir } from "../test-helpers.js";

function git(cwd: string, args: string[], encoding: "utf8" | null = null): string {
  return execFileSync("git", args, { cwd, stdio: ["ignore", "pipe", "pipe"], encoding: encoding ?? undefined as any }).toString();
}

function configureRepo(repo: string) {
  execFileSync("git", ["config", "user.email", "test@test.com"], { cwd: repo, stdio: "ignore" });
  execFileSync("git", ["config", "user.name", "test"], { cwd: repo, stdio: "ignore" });
}

describe("handleBackgroundSync recovery", () => {
  let tmp: { path: string; cleanup: () => void };
  const origCortexPath = process.env.CORTEX_PATH;

  beforeEach(() => {
    tmp = makeTempDir("cortex-bg-sync-recovery-");
  });

  afterEach(() => {
    if (origCortexPath === undefined) delete process.env.CORTEX_PATH;
    else process.env.CORTEX_PATH = origCortexPath;
    tmp.cleanup();
  });

  it("recovers from non-fast-forward push by pull-rebase and retrying push", async () => {
    const remote = path.join(tmp.path, "remote.git");
    const repoA = path.join(tmp.path, "repo-a");
    const repoB = path.join(tmp.path, "repo-b");

    execFileSync("git", ["init", "--bare", remote], { stdio: "ignore" });
    execFileSync("git", ["clone", remote, repoA], { stdio: "ignore" });
    execFileSync("git", ["clone", remote, repoB], { stdio: "ignore" });
    configureRepo(repoA);
    configureRepo(repoB);

    fs.mkdirSync(path.join(repoA, "demo"), { recursive: true });
    fs.writeFileSync(path.join(repoA, "demo", "backlog.md"), "# backlog\n\n## Active\n\n- Base task\n");
    execFileSync("git", ["add", "."], { cwd: repoA, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "base"], { cwd: repoA, stdio: "ignore" });
    execFileSync("git", ["push", "-u", "origin", "master"], { cwd: repoA, stdio: "ignore" });

    execFileSync("git", ["pull", "--quiet"], { cwd: repoB, stdio: "ignore" });

    fs.writeFileSync(path.join(repoA, "demo", "backlog.md"), "# backlog\n\n## Active\n\n- Base task\n- Remote task\n");
    execFileSync("git", ["add", "."], { cwd: repoA, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "remote"], { cwd: repoA, stdio: "ignore" });
    execFileSync("git", ["push"], { cwd: repoA, stdio: "ignore" });

    fs.writeFileSync(path.join(repoB, "demo", "summary.md"), "# summary\n\nlocal only\n");
    execFileSync("git", ["add", "."], { cwd: repoB, stdio: "ignore" });
    execFileSync("git", ["commit", "-m", "local"], { cwd: repoB, stdio: "ignore" });

    process.env.CORTEX_PATH = repoB;
    const { handleBackgroundSync } = await import("../cli-hooks-session.js");
    await handleBackgroundSync();

    execFileSync("git", ["pull", "--quiet"], { cwd: repoA, stdio: "ignore" });
    const summary = fs.readFileSync(path.join(repoA, "demo", "summary.md"), "utf8");
    expect(summary).toContain("local only");

    const runtime = JSON.parse(fs.readFileSync(path.join(repoB, ".governance", "runtime-health.json"), "utf8"));
    expect(runtime.lastSync.lastPushStatus).toBe("saved-pushed");
    expect(runtime.lastSync.lastPullStatus).toBe("ok");
  });
});
