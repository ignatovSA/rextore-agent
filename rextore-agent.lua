-- rextore-agent.lua: reopen Claude Code conversations in the panes Rex
-- restores after its server restarts.
--
-- Rex's agent hook (`rex __internal session-start --agent claude`) prints
-- REX_BLOCK=<pane id> into every Claude Code conversation it starts, and
-- Claude Code keeps that output in the conversation's transcript. Rex brings
-- panes back under the same IDs, so the transcripts alone say which
-- conversation each restored pane ran. No daemon, no extra hooks.
--
-- Load it from ~/.config/rex/init.lua:
--
--   require("rextore-agent").setup{}
--
-- The same file runs as a `rex do` script for every session at once:
--
--   rex do ~/.config/rex/rextore-agent.lua all=true [dry_run=true]
--
-- See README.md.

local M = {}

local TERMINAL = "com.superlogical.terminal"
local CONTENT_PREFIX = "You're running in a Rex terminal."
-- The raw transcript line of Rex's SessionStart hook output. Inside a JSON
-- string (a tool's output that merely mentions it) the quotes are escaped, so
-- this fixed string only matches the hook record itself.
local MARKER = '"hookEvent":"SessionStart","content":"' .. CONTENT_PREFIX
local RG_CANDIDATES = { "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg" }

local config = {
  on_start = true,      -- type the resume commands once after the server starts
  press_enter = true,   -- press Enter after typing; false leaves each command at its prompt
  command = "claude",   -- what starts Claude Code; your shell alias or function applies
  projects_dir = nil,   -- default: $CLAUDE_CONFIG_DIR/projects, else ~/.claude/projects
  state_dir = nil,      -- default: $XDG_STATE_HOME/rextore-agent, else ~/.local/state/...
  rg = nil,             -- path to ripgrep; default: the first one found; false: never
  rex = nil,            -- rex CLI for the startup helper; default: the server's own binary
  key = nil,            -- optional key for the action, such as "shift+cmd+r"
  path = nil,           -- this file, for the startup helper; default: found via package.path
  wait = 60,            -- seconds the startup run waits for restored shells
}
local OPTION_NAMES = {
  "press_enter", "command", "projects_dir", "state_dir", "rg", "wait",
}

-- Pure helpers ---------------------------------------------------------------

local function shquote(s)
  return "'" .. (s:gsub("'", [['\'']])) .. "'"
end

-- Seconds since the epoch encoded in a UUIDv7, such as a Rex block ID.
local function uuid7_seconds(id)
  local a, b = tostring(id):match("(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-7%x%x%x%-")
  if not a then return nil end
  return tonumber(a .. b, 16) / 1000
end

-- Turns search output ("path:line" per match) into hook records.
local function parse_records(output)
  local records = {}
  for line in tostring(output):gmatch("[^\n]+") do
    local path, json = line:match("^(.-%.jsonl):(.*)$")
    if path then
      local ok, obj = pcall(rex.json.decode, json)
      local att = ok and type(obj) == "table" and obj.attachment
      if type(att) == "table" and obj.type == "attachment"
          and att.hookEvent == "SessionStart"
          and type(att.content) == "string"
          and att.content:sub(1, #CONTENT_PREFIX) == CONTENT_PREFIX then
        local block = att.content:match("REX_BLOCK=(block:[%x%-]+)")
        local id = path:match("([^/]+)%.jsonl$")
        if block and id and id:match("^[%w%-]+$") then
          records[#records + 1] = {
            path = path, id = id, block = block,
            cwd = type(obj.cwd) == "string" and obj.cwd or nil,
            ts = type(obj.timestamp) == "string" and obj.timestamp or "",
          }
        end
      end
    end
  end
  return records
end

-- The conversation each live pane ran last. A conversation belongs to the
-- pane its latest record names (it moves when resumed elsewhere); a pane
-- that ran several gets the one active most recently.
local function plan(records, live, activity)
  local latest = {}
  for _, r in ipairs(records) do
    local cur = latest[r.id]
    if not cur or r.ts >= cur.ts then latest[r.id] = r end
  end
  local by_block = {}
  for _, r in pairs(latest) do
    if live[r.block] then
      r.active = activity(r.path, r.ts) or r.ts
      local cur = by_block[r.block]
      if not cur or r.active > cur.active then by_block[r.block] = r end
    end
  end
  return by_block
end

local function command_line(conv, command)
  local cmd = command .. " --resume " .. conv.id
  if conv.cwd and conv.cwd ~= "" then
    cmd = "cd " .. shquote(conv.cwd) .. " && " .. cmd
  end
  -- The leading space keeps it out of a history that ignores such lines.
  return " " .. cmd
end

-- Ctrl-E and Ctrl-U clear whatever is on the prompt first.
local function keystrokes(conv, command, enter)
  return "\5\21" .. command_line(conv, command) .. (enter and "\r" or "")
end

-- Environment ----------------------------------------------------------------

local function home() return os.getenv("HOME") or "" end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function projects_dir()
  if config.projects_dir then return config.projects_dir end
  local base = os.getenv("CLAUDE_CONFIG_DIR")
  if not base or base == "" then base = home() .. "/.claude" end
  return base .. "/projects"
end

local function state_dir()
  if config.state_dir then return config.state_dir end
  local base = os.getenv("XDG_STATE_HOME")
  if not base or base == "" then base = home() .. "/.local/state" end
  return base .. "/rextore-agent"
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, data)
  rex.exec({ "/bin/mkdir", "-p", state_dir() })
  local f = io.open(path, "w")
  if not f then return end
  f:write(data)
  f:close()
end

-- ISO time of a transcript's last entry, read from the end of the file.
local function last_activity(path, fallback)
  local f = io.open(path, "rb")
  if not f then return fallback end
  local size = f:seek("end")
  local span, best = 65536, nil
  while true do
    local start = math.max(0, size - span)
    f:seek("set", start)
    local data = f:read(size - start) or ""
    for ts in data:gmatch('"timestamp":"([^"]+)"') do
      if not best or ts > best then best = ts end
    end
    if best or start == 0 or span >= 8388608 then break end
    span = span * 8
  end
  f:close()
  return best or fallback
end

local function find_rg()
  if config.rg == false then return nil end
  if config.rg then return config.rg end
  for _, p in ipairs(RG_CANDIDATES) do
    if exists(p) then return p end
  end
end

-- Finds every Rex hook record under dir. Without ripgrep, only transcripts
-- modified after `since` are read, since the system grep is slow on gigabytes.
local function search(dir, since)
  if not exists(dir) then return "" end
  local rg = find_rg()
  local r, err
  if rg then
    r, err = rex.exec({
      rg, "--fixed-strings", "--no-ignore", "--hidden", "--with-filename",
      "--no-heading", "--no-line-number", "--no-messages",
      "--glob", "*.jsonl", "--glob", "!**/subagents/**", MARKER, dir,
    }, { timeout = 60 })
  else
    local argv = { "find", dir, "-name", "*.jsonl", "!", "-path", "*/subagents/*" }
    if since then
      argv[#argv + 1] = "-newermt"
      argv[#argv + 1] = os.date("%Y-%m-%d %H:%M:%S", math.floor(since))
    end
    for _, a in ipairs({ "-exec", "grep", "-HF", MARKER, "{}", "+" }) do
      argv[#argv + 1] = a
    end
    r, err = rex.exec(argv, { env = { PATH = "/usr/bin:/bin", LC_ALL = "C" }, timeout = 180 })
  end
  if not r then return nil, err end
  if r.timed_out then return nil, "the transcript search timed out" end
  return r.stdout or ""
end

-- Rex ------------------------------------------------------------------------

-- Terminal panes on this machine: in one session, or in every session.
-- An action in init.lua reaches only the session it runs in; a `rex do`
-- script reaches any session it attaches to.
local function live_panes(only_session)
  local status = rex.call("server.status") or {}
  local list, err = rex.call("session.list")
  if not list then error("session.list failed: " .. tostring(err), 0) end
  local panes = {}
  for _, s in ipairs(list.sessions or {}) do
    if not only_session or s.session_id == only_session then
      local bl, berr = rex.call("session.list_blocks", { session_id = s.session_id })
      if not bl and tostring(berr):find("not attached", 1, true) and rex.session.attach then
        rex.session.attach{ session_id = s.session_id }
        bl = rex.call("session.list_blocks", { session_id = s.session_id })
      end
      for _, b in ipairs((bl and bl.blocks) or {}) do
        local here = not status.host_id or not b.host_id or b.host_id == status.host_id
        if b.creator_name == TERMINAL and here then
          panes[#panes + 1] = {
            session_id = s.session_id, session = s.label or "", block_id = b.block_id,
          }
        end
      end
    end
  end
  return panes, status
end

-- "ready": a login shell waiting at its prompt. "starting": its shell isn't
-- there yet, or is still reading its startup files. "busy": something else runs.
local function pane_state(p)
  local where = { session_id = p.session_id, block_id = p.block_id }
  local proc = rex.block.call(TERMINAL, "process", where)
  local fg = proc and proc.foreground
  if not fg then return "starting" end
  local argv0 = fg.argv0 or fg.name or ""
  if argv0:sub(1, 1) ~= "-" then
    if fg.name == "login" then return "starting" end
    return "busy", argv0
  end
  local mode = rex.block.call(TERMINAL, "input_mode", where)
  if mode and mode.canonical then return "starting" end
  return "ready"
end

-- The transcripts are searched once per server instance; later runs reuse it.
local cache = {}

local function candidates(panes, instance)
  if not (cache.instance and cache.instance == instance and cache.by_block) then
    local live, oldest = {}, nil
    for _, p in ipairs(panes) do
      live[p.block_id] = true
      local t = uuid7_seconds(p.block_id)
      if t and (not oldest or t < oldest) then oldest = t end
    end
    local out, err = search(projects_dir(), oldest and (oldest - 86400))
    if not out then error("rextore: " .. tostring(err), 0) end
    cache = { instance = instance, by_block = plan(parse_records(out), live, last_activity) }
  end
  local items = {}
  for _, p in ipairs(panes) do
    local conv = cache.by_block[p.block_id]
    if conv then
      local state, detail = pane_state(p)
      items[#items + 1] = {
        pane = p, conv = conv, state = state, detail = detail,
        command = command_line(conv, config.command),
      }
    end
  end
  return items
end

local function report(item)
  return {
    session = item.pane.session, block_id = item.pane.block_id,
    conversation = item.conv.id, cwd = item.conv.cwd, last_active = item.conv.active,
    state = item.state, detail = item.detail, command = item.command,
  }
end

local function type_into(item, enter)
  local r, err = rex.block.call(TERMINAL, "write", {
    session_id = item.pane.session_id, block_id = item.pane.block_id,
    data = keystrokes(item.conv, config.command, enter),
  })
  return r ~= nil, err
end

-- One pass: type into every ready pane not typed into yet.
local function pass(only_session, enter, dry_run, typed)
  local panes, status = live_panes(only_session)
  local done = dry_run and "ready" or "typed"
  local result = { [done] = {}, pending = {}, skipped = {} }
  for _, it in ipairs(candidates(panes, status.instance_id)) do
    local id = it.pane.block_id
    if typed and typed[id] then
      -- typed on an earlier pass
    elseif it.state == "ready" then
      local ok, err = true, nil
      if not dry_run then ok, err = type_into(it, enter) end
      if ok then
        if typed then typed[id] = it.conv.id end
        result[done][#result[done] + 1] = report(it)
      else
        it.detail = tostring(err)
        result.skipped[#result.skipped + 1] = report(it)
      end
    elseif it.state == "starting" then
      result.pending[#result.pending + 1] = report(it)
    else
      result.skipped[#result.skipped + 1] = report(it)
    end
  end
  return result, status
end

local function load_state()
  local ok, obj = pcall(rex.json.decode, read_file(state_dir() .. "/state.json") or "")
  return (ok and type(obj) == "table") and obj or {}
end

-- After a server start: every session, waiting while restored shells start,
-- once per server instance.
local function startup(enter)
  local status = rex.call("server.status") or {}
  local instance = status.instance_id or ""
  local state = load_state()
  if state.instance == instance and state.done then
    return { note = "already handled for this server" }
  end
  state = { instance = instance, typed = {} }

  local all = { typed = {}, pending = {}, skipped = {} }
  local deadline = os.time() + (tonumber(config.wait) or 60)
  while true do
    local r = pass(nil, enter, false, state.typed)
    for _, x in ipairs(r.typed) do all.typed[#all.typed + 1] = x end
    all.pending, all.skipped = r.pending, r.skipped
    if #r.pending == 0 or os.time() >= deadline then break end
    rex.sleep(1)
  end

  state.done = true
  write_file(state_dir() .. "/state.json", rex.json.encode(state))
  write_file(state_dir() .. "/last-run.json", rex.json.encode(all))
  return all
end

-- The action ---------------------------------------------------------------

local function run(ctx, args)
  args = args or {}
  if not ctx.session_id then
    error("run it from a Rex pane, or pass -s SESSION", 0)
  end
  local enter = args.press_enter
  if enter == nil then enter = config.press_enter end
  local result = pass(ctx.session_id, enter, args.dry_run)
  return result
end

-- Startup helper -------------------------------------------------------------

-- Runs detached from init.lua, whose parent is the process loading it. It
-- acts only when that is a Rex server started moments ago, not on a config
-- reload or `rex config check`, and runs this file as a `rex do` script.
local HELPER = [[
p=$PPID
case "$(ps -o command= -p "$p" 2>/dev/null)" in
  *" server run"*|*" server start"*) ;;
  *) exit 0 ;;
esac
t=$(ps -o etime= -p "$p" 2>/dev/null | tr -d ' ')
case "$t" in
  ??:??) [ "${t%%:*}" -lt 2 ] || exit 0 ;;
  *) exit 0 ;;
esac
rex=$REXTORE_REX
if [ -z "$rex" ]; then
  if [ -r "/proc/$p/exe" ]; then rex=$(readlink "/proc/$p/exe"); else rex=$(ps -o comm= -p "$p"); fi
fi
i=0
while [ "$i" -lt 10 ]; do
  sleep 2
  "$rex" --autostart=false do "$REXTORE_SCRIPT" --args "$REXTORE_ARGS" \
    >/dev/null 2>&1 && exit 0
  i=$((i + 1))
done
]]

-- This file's path, for the helper to run it as a script. Rex loads chunks
-- without their file names, but package.path starts with the config folder.
local function self_path()
  if config.path then return config.path end
  for template in (package.path or ""):gmatch("[^;]+") do
    local p = template:gsub("%?", "rextore-agent")
    if p:sub(1, 1) == "/" and exists(p) then return p end
  end
end

local function start_helper()
  local script = self_path()
  if not script then
    rex.log("warn", "rextore: can't find rextore-agent.lua; set the path option")
    return
  end
  local opts = {}
  for _, k in ipairs(OPTION_NAMES) do opts[k] = config[k] end
  rex.exec.start({ "/bin/sh", "-c", HELPER }, {
    detach = true,
    stdout = false,
    stderr = false,
    env = {
      REXTORE_REX = config.rex or false,
      REXTORE_SCRIPT = script,
      REXTORE_ARGS = rex.json.encode({ startup = true, options = opts }),
    },
  })
end

-- Setup ----------------------------------------------------------------------

function M.setup(opts)
  for k, v in pairs(opts or {}) do config[k] = v end

  rex.action{
    name = "rextore",
    title = "Resume Claude Conversations",
    description = "Type the resume command for the Claude Code conversation each "
      .. "pane of this session ran, into the panes waiting at a prompt.",
    keywords = "rextore claude resume restore agent conversation",
    args = { dry_run = "boolean?", press_enter = "boolean?" },
    run = run,
  }
  if config.key then rex.bind(config.key, "rextore") end

  -- rex.args exists only in `rex do` scripts; the helper belongs to a server.
  if config.on_start and rex.args == nil then start_helper() end
  return M
end

-- `rex do rextore-agent.lua all=true`, and the startup helper's run.
function M.script(args)
  for k, v in pairs(args.options or {}) do config[k] = v end
  for _, k in ipairs(OPTION_NAMES) do
    if args[k] ~= nil then config[k] = args[k] end
  end
  if args.startup then return startup(config.press_enter) end
  return (pass(nil, config.press_enter, args.dry_run))
end

-- For tests.
M._internal = {
  shquote = shquote,
  uuid7_seconds = uuid7_seconds,
  parse_records = parse_records,
  plan = plan,
  command_line = command_line,
  keystrokes = keystrokes,
  MARKER = MARKER,
}

if rex.args ~= nil and (rex.args.all or rex.args.startup) then
  return M.script(rex.args)
end
return M
