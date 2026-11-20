// rextore-agent's OpenCode plugin. Installed by rextore-agent's install.sh
// as plugins/rextore-agent/tui.ts in OpenCode's config folder.
//
// Rex has no hook for OpenCode, so this records which session the TUI in a
// Rex pane shows, for rextore to reopen it there after Rex restarts. It
// appends one JSON line per change to $XDG_STATE_HOME/rextore-agent/panes.jsonl
// (~/.local/state/... by default):
//
//   {"agent":"opencode","event":"shown","block":"block:…","id":"ses_…","cwd":"…","timestamp":"…"}
//
// and an "event":"quit" line when you quit OpenCode, but not when a signal
// ends it, as a shutdown or a Rex server stop does.

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const dir = join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "rextore-agent");

export default {
  id: "rextore-agent",
  setup(ctx: any) {
    const block = process.env.REX_BLOCK;
    if (!block) return;

    const record = (event: string, id: string) => {
      try {
        mkdirSync(dir, { recursive: true, mode: 0o700 });
        const line = { agent: "opencode", event, block, id, cwd: process.cwd(), timestamp: new Date().toISOString() };
        appendFileSync(join(dir, "panes.jsonl"), JSON.stringify(line) + "\n");
      } catch {
        // Recording is best effort; it never gets in OpenCode's way.
      }
    };

    // The pane's conversation is the session the TUI shows. A subagent's
    // session opens in the same view and belongs to its parent's.
    let shown: string | undefined;
    const check = () => {
      const route = ctx.ui?.router?.current?.();
      if (route?.type !== "session" || !route.sessionID) return;
      const root = ctx.data?.session?.root;
      const id = (typeof root === "function" && root(route.sessionID)) || route.sessionID;
      if (id !== shown) {
        shown = id;
        record("shown", id);
      }
    };
    check();
    // Polling the route once a second needs nothing from OpenCode's UI library.
    const timer = setInterval(check, 1000);
    (timer as any).unref?.();

    // OpenCode ends on SIGTERM and SIGHUP itself; these only note the signal.
    let signalled = false;
    const note = () => {
      signalled = true;
    };
    process.on("SIGTERM", note);
    process.on("SIGHUP", note);
    const quit = () => {
      if (shown && !signalled) record("quit", shown);
      shown = undefined;
    };
    process.on("exit", quit);

    return () => {
      clearInterval(timer);
      process.off("SIGTERM", note);
      process.off("SIGHUP", note);
      process.off("exit", quit);
      quit();
    };
  },
};
