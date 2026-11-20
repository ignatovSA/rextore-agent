# rextore-agent

Rex restores your panes. rextore brings back the agent conversations in them.

A [Rex](https://www.superlogical.com/rex) plugin that reopens agent
conversations in the panes Rex restores after its server restarts.

Rex brings back your sessions, tabs, and panes after a restart, but each pane
comes back with a fresh shell. The agent conversations that ran in them are
gone. After a restart, rextore runs the agent's resume command in each pane
that ran one, such as `cd <folder> && claude --resume <conversation>`, so the
conversations come back by themselves. With `press_enter = false` it only
types the commands, and you press Enter in the panes you want back.

It needs no daemon. It's one Lua file loaded from Rex's `init.lua`, plus a
small plugin for each agent Rex has no hook for.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/install.sh | sh
```

`install.sh` downloads `rextore-agent.lua` and its agent plugins to
`~/.local/share/rextore-agent` (`$XDG_DATA_HOME/rextore-agent`), and links
`rextore-agent.lua` into Rex's config folder (`~/.config/rex`, or the folder of
`$REX_CONFIG`). It adds this line to `init.lua`, then reloads the config:

```lua
require("rextore-agent").setup{}
```

Run the same command again to update. To undo all of it, downloaded files
included:

```sh
curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/install.sh | sh -s -- --uninstall
```

<details>
<summary>By hand</summary>

Without running any script, put the files in place yourself:

1. Save [`rextore-agent.lua`](rextore-agent.lua) in Rex's config folder,
   `~/.config/rex` (or `$XDG_CONFIG_HOME/rex`):

   ```sh
   mkdir -p ~/.config/rex
   curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/rextore-agent.lua \
     -o ~/.config/rex/rextore-agent.lua
   ```

2. Add this line to `~/.config/rex/init.lua`, creating the file if needed:

   ```lua
   require("rextore-agent").setup{}
   ```

3. Load it with `rex config reload`, or by restarting Rex.

4. For OpenCode, save [`agents/opencode/tui.ts`](agents/opencode/tui.ts) as
   `plugins/rextore-agent/tui.ts` in OpenCode's config folder:

   ```sh
   mkdir -p ~/.config/opencode/plugins/rextore-agent
   curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/agents/opencode/tui.ts \
     -o ~/.config/opencode/plugins/rextore-agent/tui.ts
   ```

5. For Pi, save [`agents/pi/rextore-agent.ts`](agents/pi/rextore-agent.ts) in
   Pi's `extensions` folder:

   ```sh
   mkdir -p ~/.pi/agent/extensions
   curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/agents/pi/rextore-agent.ts \
     -o ~/.pi/agent/extensions/rextore-agent.ts
   ```

Steps 4 and 5 are only for the agents you use. To update, save the files
again. To uninstall, delete them and the `require` line, then run
`rex config reload`.

</details>

## How it works

Rex's agent hook (`rex __internal session-start --agent …`) tells each
session it starts which Rex pane it runs in, `REX_BLOCK=block:…`, and the
agent keeps that text in the session's log. Rex restores panes under the IDs
they had, so the logs are enough to work out which conversation each restored
pane ran:

- A conversation belongs to the pane named in its latest Rex hook entry. If
  you resumed it in another pane, it moves there.
- A pane that ran several conversations, from any agent, gets the one active
  most recently, judged by the last entry in each log.
- Rex's hook text has to be the start of the hook's own entry. A log that
  merely mentions a pane ID, such as in a tool's output, doesn't count.

Only panes waiting at a fresh shell prompt get typed into. The plugin clears
the prompt with Ctrl-E and Ctrl-U first. It skips panes where something else
is running, such as the agent itself.

The search uses [ripgrep](https://github.com/BurntSushi/ripgrep) when it's
installed: under a second for gigabytes of logs. Without it, the plugin falls
back to `find` and `grep`. It then reads only logs changed since the oldest
open pane was created, which can still take several seconds.

## Agents

| Agent | Where rextore finds the pane | Resume command |
| --- | --- | --- |
| Claude Code | Rex's hook output in the transcripts under `~/.claude/projects` | `claude --resume <id>` |
| Codex | Rex's hook output in the session logs under `~/.codex/sessions` | `codex resume <id>` |
| OpenCode | rextore's OpenCode plugin, in `~/.local/state/rextore-agent/panes.jsonl` | `opencode --session <id>` |
| Pi | rextore's Pi extension, in the same `panes.jsonl` | `pi --session <file>` |

## Compared with rexume and rexurrect

Two other projects bring agent conversations back after a Rex restart.
[rexume](https://github.com/Entwining/rexume) builds on Rex's own restore, as
rextore does. [rexurrect](https://github.com/cemcatik/rexurrect) is
tmux-resurrect for Rex: it saves and restores whole sessions itself. As of
rexume 0.1.26 and rexurrect 0.4.0:

| | rextore-agent | rexume | rexurrect |
| --- | --- | --- | --- |
| Restores | the conversation in each pane Rex restores | the conversation in each pane Rex restores | whole sessions from its own snapshots: layout, folders, earlier output, last commands |
| Layout and pane IDs | Rex's own, saved about a second after each change | Rex's own | its last snapshot, saved every 15 minutes by default; replaces Rex's copies, with new IDs |
| Agents | Claude Code, Codex, OpenCode, Pi | Claude Code, Codex, OpenCode, Pi, omp | Claude Code, Codex, and Neovim with a `Session.vim` |
| Learns the pane from | Rex's hook output in the agents' logs; its own plugins for OpenCode and Pi | its own hooks and plugins, and a daemon following Rex's events | its own hook, which you add to each agent |
| **Runs in the background** | **nothing; a one-shot helper at server start** | **a daemon, as a login item** | **a save job, every 15 minutes by default, as a login item** |
| Adds to the agents | an OpenCode plugin and a Pi extension | 4 Claude Code hooks, a Claude Code plugin, a Codex hook, OpenCode, Pi and omp plugins, a skill | one hook each for Claude Code and Codex |
| Made of | one Lua file in `init.lua`, two small TypeScript plugins | a Rust program | a Rust program |
| Starts the conversation | yes, unless `press_enter = false` | yes | types the command; `auto_resume` starts it |
| Continues a reply the restart cut off | no | yes, once | no |
| Keeps model, effort, permission mode | as far as each agent's resume does | yes, and Claude Code's launch flags and provider | as far as each agent's resume does; Claude Code's flags are dropped |
| Leaves a conversation you quit closed | OpenCode and Pi only | yes; it watches each pane live | if quit before its last save, or any time with its zsh recorder |
| Brings back earlier output | no | no | yes |
| Also | | hands workers' results back to an orchestrator agent | restores Neovim sessions and any program you define |

Pick rexume for the most complete agent recovery, and rexurrect if you want
scrollback and Neovim back too. Pick rextore if you want the smallest
footprint: no daemon and no binary, with Rex's own restore doing the rest.

## Use

**After a restart** nothing is needed. When the Rex server starts, the plugin
waits up to a minute for the restored shells, then runs the resume command in
each pane that ran a conversation. It runs once per server start. A later
`rex config reload` doesn't run it again.

**From the command palette**, run *Resume Agent Conversations*. It does the
same for the panes of the current session that wait at a prompt. From a shell
in a Rex pane:

```sh
rex do rextore                 # this session
rex do rextore dry_run=true    # show what it would type
```

**For every session at once**, run the same file as a script:

```sh
rex do ~/.config/rex/rextore-agent.lua all=true dry_run=true
rex do ~/.config/rex/rextore-agent.lua all=true
```

An action in `init.lua` can only reach the session it runs in. The startup run
and `all=true` run as `rex do` scripts, which can reach every session.

## Options

Pass them to `setup`:

```lua
require("rextore-agent").setup{
  press_enter = false,                      -- only type the commands; you press Enter
  agents = { codex = false },               -- leave an agent out
  commands = { claude = "claude --model opus" },
  key = "shift+cmd+r",                      -- bind the action to a key
}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `on_start` | `true` | Run the resume commands once after the server starts. |
| `press_enter` | `true` | Press Enter after typing. `false` leaves each command at its prompt. |
| `agents` | all on | `false` for an agent leaves it out, such as `{ codex = false }`. |
| `commands` | `claude`, `codex`, `opencode`, `pi` | What starts each agent. Your shell's alias or function for it applies. |
| `dirs` | see below | Where each agent's logs are, such as `{ claude = "/elsewhere/projects" }`. |
| `wait` | `60` | Seconds the startup run waits for restored shells to reach a prompt. |
| `state_dir` | `$XDG_STATE_HOME/rextore-agent` or `~/.local/state/rextore-agent` | Where it records the last startup run (`last-run.json`). |
| `rg` | first of `/opt/homebrew/bin/rg`, `/usr/local/bin/rg`, `/usr/bin/rg` | Path to ripgrep; `false` never uses it. |
| `rex` | the server's own binary | The `rex` CLI the startup helper runs. |
| `path` | found through `package.path` | This file, if you keep it somewhere `require` finds under another name. |
| `key` | none | A key for the action. |

The default `dirs` are `$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects`
for Claude Code, `$CODEX_HOME/sessions` or `~/.codex/sessions` for Codex, and
the folder holding `panes.jsonl` for OpenCode and Pi.

## How the startup run works

`init.lua` can't call Rex's API while it loads, and in this version of Rex it
can't handle events or set timers either. So `setup` starts one short-lived,
detached shell helper. The helper checks that its parent process is a Rex
server started less than two minutes ago. That rules out a `rex config reload`
or a `rex config check`. It then runs this file as a `rex do` script, which
attaches to every session, waits for the restored shells, types, and exits.

Once Rex runs `rex.on` handlers from `init.lua`, the helper can go away.

## Limits

- **Old conversations aren't covered.** Only conversations started after Rex's
  agent hook was installed carry a pane ID. The same goes for a conversation
  from before the hook that you resumed but haven't used since.
- **Codex sessions run through Codex's app-server daemon aren't covered**,
  because their logs name the daemon's pane.
- **OpenCode and Pi sessions from before their plugin was installed aren't
  covered.** The plugins have been tested only against mocked plugin APIs, not
  a real OpenCode or Pi.
- **For Claude Code and Codex, it can't tell whether you'd quit the agent** in
  a pane before the restart. The pane's most recent conversation comes back
  either way. Set `press_enter = false` if you'd rather choose. The OpenCode
  and Pi plugins record a quit, so those two are spared this.
- **A reply cut off by the restart doesn't continue by itself.** Ask it to
  continue.
- **Typing races with you.** If you type into a restored pane at the same
  moment, the line can get mixed. In a shell with a vi keymap, Ctrl-U clears
  only what's before the cursor.
- **Model, effort, and permission mode** come back only as far as each agent's
  own resume brings them back.
- **Tested on macOS** with Rex 0.1.0-preview.14. The Linux path (finding the
  `rex` binary through `/proc`) is untested.

## Tests

From a Rex pane, in the repository:

```sh
rex do tests/run.lua    # unit tests, in Rex's own Lua
node tests/opencode.mjs # the OpenCode plugin, against a mocked context
node tests/pi.mjs       # the Pi extension, against a mocked API
sh tests/e2e.sh         # opens a scratch tab, uses echo in place of the agents
sh tests/restart.sh     # a throwaway Rex server: start, stop, restore, check
```

None of them touch your real logs or panes. `restart.sh` runs its own Rex
server on a separate socket and state folder. `E2E_RG=false sh tests/e2e.sh`
tests the fallback without ripgrep.

## License

MIT. See [LICENSE](LICENSE).
