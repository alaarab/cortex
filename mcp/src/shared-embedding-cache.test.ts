import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import * as fs from "fs";
import * as path from "path";
import * as shared from "./shared.js";
import { EmbeddingCache } from "./shared-embedding-cache.js";
import { makeTempDir } from "./test-helpers.js";

describe("EmbeddingCache.load", () => {
  let tmp: { path: string; cleanup: () => void };

  beforeEach(() => {
    tmp = makeTempDir("embedding-cache-");
    vi.restoreAllMocks();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    tmp.cleanup();
  });

  it("logs corrupt cache files instead of silently treating them as missing", async () => {
    const runtimeDir = path.join(tmp.path, ".runtime");
    fs.mkdirSync(runtimeDir, { recursive: true });
    fs.writeFileSync(path.join(runtimeDir, "embeddings.json"), "{bad json");
    const debugSpy = vi.spyOn(shared, "debugLog").mockImplementation(() => {});

    const cache = new EmbeddingCache(tmp.path);
    await cache.load();

    expect(cache.size()).toBe(0);
    expect(debugSpy).toHaveBeenCalledWith(expect.stringContaining("EmbeddingCache load failed"));
  });

  it("keeps missing cache files quiet", async () => {
    const debugSpy = vi.spyOn(shared, "debugLog").mockImplementation(() => {});

    const cache = new EmbeddingCache(tmp.path);
    await cache.load();

    expect(cache.size()).toBe(0);
    expect(debugSpy).not.toHaveBeenCalled();
  });
});
