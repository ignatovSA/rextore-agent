// Tests agents/opencode/tui.ts against a mocked OpenCode TUI plugin context.
// Run from the repository root with Node 22.18 or later:
//
//   node tests/opencode.mjs
//
// It writes only to a temporary folder.

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const state = mkdtempSync(join(tmpdir(), "rextore-opencode-"));
process.env.XDG_STATE_HOME = state;
process.env.REX_BLOCK = "block:01a1aaaa-0000-7000-8000-000000000001";
const { default: plugin } = await import("../agents/opencode/tui.ts");

const file = join(state, "rextore-agent", "panes.jsonl");
const lines = () =>
  existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];
const tick = () => new Promise((done) => setTimeout(done, 1100));

let route = { type: "home" };
const ctx = {
  ui: { router: { current: () => route } },
  // A subagent's session belongs to its parent's.
  data: { session: { root: (id) => (id === "ses_child" ? "ses_root" : id) } },
};

try {
  let dispose = plugin.setup(ctx);
  assert.equal(plugin.id, "rextore-agent");
  assert.equal(lines().length, 0, "the home screen records nothing");

  route = { type: "session", sessionID: "ses_child" };
  await tick();
  let all = lines();
  assert.equal(all.length, 1, "a shown session is recorded");
  assert.deepEqual(
    { agent: all[0].agent, event: all[0].event, id: all[0].id, block: all[0].block, cwd: all[0].cwd },
    { agent: "opencode", event: "shown", id: "ses_root", block: process.env.REX_BLOCK, cwd: process.cwd() },
  );
  assert.match(all[0].timestamp, /^\d{4}-\d\d-\d\dT/);

  await tick();
  assert.equal(lines().length, 1, "the same session is recorded once");

  route = { type: "session", sessionID: "ses_other" };
  await tick();
  assert.equal(lines().at(-1).id, "ses_other", "switching sessions records the new one");

  dispose();
  assert.deepEqual(
    { event: lines().at(-1).event, id: lines().at(-1).id },
    { event: "quit", id: "ses_other" },
    "quitting records a quit",
  );
  const count = lines().length;

  // A signal, as at a shutdown or a Rex server stop, is not a quit.
  dispose = plugin.setup(ctx);
  assert.equal(lines().at(-1).event, "shown", "a new TUI records the session it opens on");
  process.emit("SIGTERM");
  dispose();
  assert.equal(lines().length, count + 1, "a signal records no quit");

  // Outside a Rex pane nothing is recorded.
  delete process.env.REX_BLOCK;
  assert.equal(plugin.setup(ctx), undefined);
  await tick();
  assert.equal(lines().length, count + 1, "nothing is recorded outside Rex");

  console.log("ok: opencode plugin checks passed");
} finally {
  rmSync(state, { recursive: true, force: true });
}
