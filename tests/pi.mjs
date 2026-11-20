// Tests agents/pi/rextore-agent.ts against a mocked Pi extension API.
// Run from the repository root with Node 22.18 or later:
//
//   node tests/pi.mjs
//
// It writes only to a temporary folder.

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const state = mkdtempSync(join(tmpdir(), "rextore-pi-"));
process.env.XDG_STATE_HOME = state;
process.env.REX_BLOCK = "block:01a1aaaa-0000-7000-8000-000000000001";
const { default: extension } = await import("../agents/pi/rextore-agent.ts");

const file = join(state, "rextore-agent", "panes.jsonl");
const lines = () =>
  existsSync(file) ? readFileSync(file, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)) : [];

// What Pi hands an extension: `on` to register handlers, and a context per event.
const load = () => {
  const handlers = {};
  extension({ on: (name, fn) => (handlers[name] = fn) });
  return handlers;
};
const ctx = (id, mode = "tui", sessionFile = `/s/${id}.jsonl`) => ({
  mode,
  sessionManager: { getSessionId: () => id, getSessionFile: () => sessionFile },
});

try {
  let pi = load();
  pi.session_start({}, ctx("p1"));
  let last = lines().at(-1);
  assert.deepEqual(
    { agent: last.agent, event: last.event, id: last.id, file: last.file, block: last.block, cwd: last.cwd },
    { agent: "pi", event: "shown", id: "p1", file: "/s/p1.jsonl", block: process.env.REX_BLOCK, cwd: process.cwd() },
    "an interactive session start is recorded",
  );

  pi.session_start({}, ctx("p2"));
  assert.equal(lines().at(-1).id, "p2", "switching to another session records it");

  pi.session_shutdown({ reason: "quit" }, ctx("p2"));
  assert.deepEqual({ event: lines().at(-1).event, id: lines().at(-1).id }, { event: "quit", id: "p2" }, "a quit is recorded");
  const count = lines().length;

  pi.session_shutdown({ reason: "new" }, ctx("p2"));
  assert.equal(lines().length, count, "ending a session for another one isn't a quit");

  pi.session_start({}, ctx("p3", "print"));
  pi.session_start({}, ctx("p4", "tui", null));
  assert.equal(lines().length, count, "print mode and in-memory sessions are not recorded");

  // A signal, as at a shutdown or a Rex server stop, is not a quit.
  pi = load();
  pi.session_start({}, ctx("p5"));
  process.emit("SIGTERM");
  pi.session_shutdown({ reason: "quit" }, ctx("p5"));
  assert.equal(lines().at(-1).event, "shown", "a signal records no quit");

  // Outside a Rex pane nothing is registered.
  delete process.env.REX_BLOCK;
  assert.deepEqual(load(), {}, "nothing is registered outside Rex");

  console.log("ok: pi extension checks passed");
} finally {
  process.removeAllListeners("SIGTERM");
  process.removeAllListeners("SIGHUP");
  rmSync(state, { recursive: true, force: true });
}
