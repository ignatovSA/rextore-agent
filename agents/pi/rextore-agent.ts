// rextore-agent's Pi extension. Installed by rextore-agent's install.sh as
// extensions/rextore-agent.ts in Pi's agent folder.
//
// Rex has no hook for Pi, so this records which session an interactive Pi in
// a Rex pane runs, for rextore to reopen it there after Rex restarts. It
// appends one JSON line per session start to
// $XDG_STATE_HOME/rextore-agent/panes.jsonl (~/.local/state/... by default):
//
//   {"agent":"pi","event":"shown","block":"block:…","id":"…","file":"…","cwd":"…","timestamp":"…"}
//
// and an "event":"quit" line when you quit Pi, but not when a signal ends it,
// as a shutdown or a Rex server stop does.

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const dir = join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "rextore-agent");

export default function (pi: any) {
  const block = process.env.REX_BLOCK;
  if (!block) return;

  const record = (event: string, ctx: any) => {
    try {
      const id = ctx.sessionManager.getSessionId();
      const file = ctx.sessionManager.getSessionFile();
      // A session kept only in memory can't be reopened.
      if (!id || !file) return;
      mkdirSync(dir, { recursive: true, mode: 0o700 });
      const line = { agent: "pi", event, block, id, file, cwd: process.cwd(), timestamp: new Date().toISOString() };
      appendFileSync(join(dir, "panes.jsonl"), JSON.stringify(line) + "\n");
    } catch {
      // Recording is best effort; it never gets in Pi's way.
    }
  };

  // Pi ends on SIGTERM and SIGHUP itself and reports that end as a quit too;
  // these only note the signal.
  let signalled = false;
  const note = () => {
    signalled = true;
  };

  pi.on("session_start", (_event: any, ctx: any) => {
    // Only an interactive Pi owns its pane; `pi -p` and the like don't.
    if (ctx.mode !== "tui") return;
    process.off("SIGTERM", note);
    process.off("SIGHUP", note);
    process.on("SIGTERM", note);
    process.on("SIGHUP", note);
    record("shown", ctx);
  });

  pi.on("session_shutdown", (event: any, ctx: any) => {
    if (ctx.mode !== "tui") return;
    if (event?.reason === "quit" && !signalled) record("quit", ctx);
  });
}
