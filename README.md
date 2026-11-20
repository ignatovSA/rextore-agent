# rextore-agent

Rex restores your panes. rextore brings back the agent conversations in them.

A [Rex](https://www.superlogical.com/rex) plugin that reopens Claude Code
conversations in the panes Rex restores after its server restarts.

Rex brings back your sessions, tabs, and panes after a restart, but each pane
comes back with a fresh shell. The Claude Code conversations that ran in them
are gone. After a restart, rextore runs
`cd <folder> && claude --resume <conversation>` in each pane that ran one, so
the conversations come back by themselves. With `press_enter = false` it only
types the commands, and you press Enter in the panes you want back.

It needs no daemon and installs no hooks. It's one Lua file loaded from Rex's
`init.lua`.

## How it works

Rex's agent hook (`rex __internal session-start --agent claude`, which
`rex skill setup` installs) prints the pane's ID, `REX_BLOCK=block:…`, into
every Claude Code conversation started in a Rex pane. Claude Code saves that
output in the conversation's transcript under `~/.claude/projects`. Rex
restores panes under the IDs they had, so the transcripts are enough to work
out which conversation each restored pane ran:

- A conversation belongs to the pane named in its latest Rex hook entry. If
  you resumed it in another pane, it moves there.
- A pane that ran several conversations gets the one active most recently,
  judged by the last entry in each transcript.
- Rex's hook text has to be the start of a `SessionStart` hook entry. A
  transcript that merely mentions a pane ID, such as a tool's output, doesn't
  count.

Only panes waiting at a fresh shell prompt get typed into. The plugin clears
the prompt with Ctrl-E and Ctrl-U first. It skips panes where something else
is running, such as Claude Code itself.

The search uses [ripgrep](https://github.com/BurntSushi/ripgrep) when it's
installed: under a second for gigabytes of transcripts. Without it, the plugin
falls back to `find` and `grep`. It then reads only transcripts changed since
the oldest open pane was created, which can still take several seconds.

## Install

```sh
git clone https://github.com/ignatovSA/rextore-agent
cd rextore-agent
sh install.sh
```

`install.sh` links `rextore-agent.lua` into Rex's config folder
(`~/.config/rex`, or the folder of `$REX_CONFIG`). It adds this line to
`init.lua`, then reloads the config:

```lua
require("rextore-agent").setup{}
```

Run `sh install.sh --uninstall` to undo both.

## Use

**After a restart** nothing is needed. When the Rex server starts, the plugin
waits up to a minute for the restored shells, then runs the resume command in
each pane that ran a conversation. It runs once per server start. A later
`rex config reload` doesn't run it again.

**From the command palette**, run *Resume Claude Conversations*. It does the
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
  press_enter = false,      -- only type the commands; you press Enter
  key = "shift+cmd+r",      -- bind the action to a key
}
```

| Option | Default | Meaning |
| --- | --- | --- |
| `on_start` | `true` | Type the resume commands once after the server starts. |
| `press_enter` | `true` | Press Enter after typing. `false` leaves each command at its prompt. |
| `command` | `"claude"` | What starts Claude Code. Your shell's alias or function for it applies. |
| `wait` | `60` | Seconds the startup run waits for restored shells to reach a prompt. |
| `projects_dir` | `$CLAUDE_CONFIG_DIR/projects` or `~/.claude/projects` | Where the transcripts are. |
| `state_dir` | `$XDG_STATE_HOME/rextore-agent` or `~/.local/state/rextore-agent` | Where it records the last startup run (`last-run.json`). |
| `rg` | first of `/opt/homebrew/bin/rg`, `/usr/local/bin/rg`, `/usr/bin/rg` | Path to ripgrep; `false` never uses it. |
| `rex` | the server's own binary | The `rex` CLI the startup helper runs. |
| `path` | found through `package.path` | This file, if you keep it somewhere `require` finds under another name. |
| `key` | none | A key for the action. |

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
- **It can't tell whether you'd quit Claude Code** in a pane before the
  restart. The pane's most recent conversation comes back either way. Set
  `press_enter = false` if you'd rather choose.
- **A reply cut off by the restart doesn't continue by itself.** Ask it to
  continue.
- **Typing races with you.** If you type into a restored pane at the same
  moment, the line can get mixed. In a shell with a vi keymap, Ctrl-U clears
  only what's before the cursor.
- **Model, effort, and permission mode** come back only as far as Claude
  Code's own `--resume` brings them back.
- **Only Claude Code is covered**, not Codex or other agents.
- **Tested on macOS** with Rex 0.1.0-preview.14. The Linux path (finding the
  `rex` binary through `/proc`) is untested.

## Tests

From a Rex pane, in the repository:

```sh
rex do tests/run.lua    # unit tests, in Rex's own Lua
sh tests/e2e.sh         # opens a scratch tab, uses echo in place of claude
sh tests/restart.sh     # a throwaway Rex server: start, stop, restore, check
```

None of them touch your real transcripts or panes. `restart.sh` runs its own
Rex server on a separate socket and state folder. `E2E_RG=false sh tests/e2e.sh`
tests the fallback without ripgrep.

## License

MIT. See [LICENSE](LICENSE).
