-- rextore-agent.lua: reopen agent conversations in the panes Rex restores
-- after its server restarts.
--
-- Rex's agent hook (`rex __internal session-start --agent ...`) tells each
-- Claude Code and Codex session which pane it runs in, REX_BLOCK=<pane id>,
-- and both agents keep that text in the session's log. Rex brings panes back
-- under the same IDs, so the logs alone say which conversation each restored
-- pane ran. No daemon, no extra hooks.
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
local PREFIX = "You're running in a Rex terminal."
local RG_CANDIDATES = { "/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg" }

local config = {
  on_start = true,      -- run the resume commands once after the server starts
  press_enter = true,   -- press Enter after typing; false leaves each command at its prompt
  agents = {},          -- false turns an agent off, such as { codex = false }
  commands = {},        -- what starts an agent, such as { claude = "claude --model opus" }
  dirs = {},            -- where an agent's logs are, if not in the default place
  state_dir = nil,      -- default: $XDG_STATE_HOME/rextore-agent, else ~/.local/state/...
  rg = nil,             -- path to ripgrep; default: the first one found; false: never
  rex = nil,            -- rex CLI for the startup helper; default: the server's own binary
  key = nil,            -- optional key for the action, such as "shift+cmd+r"
  path = nil,           -- this file, for the startup helper; default: found via package.path
  wait = 60,            -- seconds the startup run waits for restored shells
}
-- What setup() hands on to the startup run, which reads no init.lua.
local OPTION_NAMES = {
  "press_enter", "agents", "commands", "dirs", "state_dir", "rg", "wait",
}

-- Merges options into config; table options merge key by key.
local function configure(opts)
  for k, v in pairs(opts or {}) do
    if type(v) == "table" and type(config[k]) == "table" then
      for k2, v2 in pairs(v) do config[k][k2] = v2 end
    else
      config[k] = v
    end
  end
end

-- Pure helpers ---------------------------------------------------------------

local function shquote(s)
  return "'" .. (s:gsub("'", [['\'']])) .. "'"
end

-- A shell word: as it is when it holds nothing a shell reads specially.
local function shword(s)
  if s:match("^[%w%-%./_:=@+]+$") then return s end
  return shquote(s)
end

local function str(v) return type(v) == "string" and v or nil end

-- Seconds since the epoch encoded in a UUIDv7, such as a Rex block ID.
local function uuid7_seconds(id)
  local a, b = tostring(id):match("(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-7%x%x%x%-")
  if not a then return nil end
  return tonumber(a .. b, 16) / 1000
end

-- Rex's Lua refuses patterns over very long strings, and agents' log lines
-- can be megabytes, so long text is only ever searched with plain finds.

-- Each line of text, without its newline.
local function each_line(text)
  local pos = 1
  return function()
    if pos > #text then return nil end
    local nl = text:find("\n", pos, true) or (#text + 1)
    local line = text:sub(pos, nl - 1)
    pos = nl + 1
    return line
  end
end

-- The pane ID in Rex's hook text, which starts with PREFIX.
local function rex_block(text)
  if type(text) ~= "string" or text:sub(1, #PREFIX) ~= PREFIX then return nil end
  local at = text:find("REX_BLOCK=block:", 1, true)
  return at and text:sub(at + 10, at + 60):match("^block:[%x%-]+")
end

local function home() return os.getenv("HOME") or "" end

local function env_dir(var, fallback)
  local v = os.getenv(var)
  if v and v ~= "" then return v end
  return home() .. fallback
end

-- Whether a Codex session's pane ID is its own. Rex's hook reports the
-- REX_BLOCK of the process that runs it. A session the Codex TUI runs itself
-- (source "cli") runs it in its pane. One it runs through Codex's shared
-- app-server daemon (source "vscode") runs it in the daemon, which reports the
-- pane the daemon was started from. `codex exec` runs and subagents carry the
-- pane of whatever started them.
local function codex_own_pane(meta)
  return meta.source == "cli" and meta.originator ~= "codex_exec"
    and type(meta.agent_path) ~= "string"
end

-- Agents ---------------------------------------------------------------------

-- For each agent: where its logs are, the raw text of the lines that hold
-- Rex's hook output, how to read one such line, and how to resume. Inside a
-- JSON string, such as a tool's output that merely mentions the hook text,
-- the quotes are escaped, so a marker matches only the hook's own line.
--
-- Rex has no hook for some agents. For those, rextore's own plugin records
-- the session each pane shows in panes.jsonl, and `panes = true` reads that.
local AGENTS = {
  claude = {
    command = "claude",
    dir = function() return env_dir("CLAUDE_CONFIG_DIR", "/.claude") .. "/projects" end,
    marker = '"hookEvent":"SessionStart","content":"' .. PREFIX,
    -- One transcript per conversation, named after it.
    record = function(path, obj)
      local att = obj.attachment
      if obj.type ~= "attachment" or type(att) ~= "table" or att.hookEvent ~= "SessionStart" then
        return nil
      end
      local block = rex_block(att.content)
      if not block then return nil end
      return { id = path:match("([^/]+)%.jsonl$"), block = block, cwd = str(obj.cwd), ts = str(obj.timestamp) }
    end,
    resume = function(c) return { "--resume", c.id } end,
  },
  codex = {
    command = "codex",
    dir = function() return env_dir("CODEX_HOME", "/.codex") .. "/sessions" end,
    marker = '"type":"input_text","text":"' .. PREFIX,
    -- Rex's hook output is a developer message. The session's ID, folder and
    -- kind are in the session_meta on the log's first line.
    record = function(path, obj, meta)
      local p = obj.payload
      if obj.type ~= "response_item" or type(p) ~= "table" or p.type ~= "message"
          or p.role ~= "developer" or type(p.content) ~= "table" then
        return nil
      end
      local block
      for _, c in ipairs(p.content) do
        block = block or (type(c) == "table" and rex_block(c.text)) or nil
      end
      if not block then return nil end
      local m = meta(path)
      if not m or not codex_own_pane(m) then return nil end
      return { id = str(m.id), block = block, cwd = str(m.cwd), ts = str(obj.timestamp) }
    end,
    resume = function(c) return { "resume", c.id } end,
  },
  opencode = {
    command = "opencode",
    panes = true, -- from agents/opencode/tui.ts
    resume = function(c) return { "--session", c.id } end,
  },
  pi = {
    command = "pi",
    panes = true, -- from agents/pi/rextore-agent.ts
    -- Pi reopens a session from its file.
    resume = function(c) return { "--session", c.file or c.id } end,
  },
}
local AGENT_ORDER = { "claude", "codex", "opencode", "pi" }

-- Where rextore's agent plugins record panes. They read no options, so this
-- is always the default state folder.
local function panes_dir()
  return env_dir("XDG_STATE_HOME", "/.local/state") .. "/rextore-agent"
end

local function command_of(agent)
  return config.commands[agent] or AGENTS[agent].command
end

-- Records -------------------------------------------------------------------

local function first_line_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local line = f:read("*l")
  f:close()
  local ok, obj = pcall(rex.json.decode, line or "")
  return ok and type(obj) == "table" and obj or nil
end

local function codex_meta(path)
  local obj = first_line_json(path)
  if obj and obj.type == "session_meta" and type(obj.payload) == "table" then return obj.payload end
end

-- Turns search output ("path:line" per match) into an agent's records.
local function parse_records(agent, output, meta)
  local read = AGENTS[agent].record
  local memo = {}
  local function cached(path)
    if memo[path] == nil then memo[path] = (meta or codex_meta)(path) or false end
    return memo[path] or nil
  end
  local records = {}
  for line in each_line(tostring(output)) do
    local cut = line:find(".jsonl:", 1, true)
    if cut then
      local path, json = line:sub(1, cut + 5), line:sub(cut + 7)
      local ok, obj = pcall(rex.json.decode, json)
      local r = ok and type(obj) == "table" and read(path, obj, cached) or nil
      if r and r.block and type(r.id) == "string" and r.id:match("^[%w_%-]+$") then
        r.agent, r.path, r.ts = agent, path, r.ts or ""
        records[#records + 1] = r
      end
    end
  end
  return records
end

-- The lines rextore's plugins write to panes.jsonl, for one agent. "shown"
-- means a pane shows the session; "quit" means it was closed on purpose, not
-- ended by a signal, so it isn't reopened.
local function parse_panes(agent, text)
  local records = {}
  for line in each_line(tostring(text)) do
    local ok, obj = pcall(rex.json.decode, line)
    -- Pi's IDs can hold a "/"; every word typed is shell-quoted anyway.
    if ok and type(obj) == "table" and obj.agent == agent
        and type(obj.id) == "string" and obj.id ~= "" and not obj.id:find("%c")
        and type(obj.block) == "string" and obj.block:match("^block:[%x%-]+$") then
      records[#records + 1] = {
        agent = agent, id = obj.id, block = obj.block, cwd = str(obj.cwd),
        ts = str(obj.timestamp) or "", file = str(obj.file), path = str(obj.file),
        ended = obj.event == "quit",
      }
    end
  end
  return records
end

-- The conversation each live pane ran last. A conversation belongs to the
-- pane its latest record names (it moves when resumed elsewhere), unless that
-- record says it was quit; a pane that ran several gets the one active most
-- recently.
local function plan(records, live, activity)
  local latest = {}
  for _, r in ipairs(records) do
    local key = r.agent .. ":" .. r.id
    local cur = latest[key]
    if not cur or r.ts >= cur.ts then latest[key] = r end
  end
  local by_block = {}
  for _, r in pairs(latest) do
    if live[r.block] and not r.ended then
      r.active = activity(r.path, r.ts) or r.ts
      local cur = by_block[r.block]
      if not cur or r.active > cur.active then by_block[r.block] = r end
    end
  end
  return by_block
end

local function command_line(conv, command)
  local words = { command }
  for _, a in ipairs(AGENTS[conv.agent].resume(conv)) do words[#words + 1] = shword(a) end
  local cmd = table.concat(words, " ")
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

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function state_dir()
  if config.state_dir then return config.state_dir end
  return env_dir("XDG_STATE_HOME", "/.local/state") .. "/rextore-agent"
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

-- ISO time of a log's last entry, read from the end of the file.
local function last_activity(path, fallback)
  local f = path and io.open(path, "rb")
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

-- Finds the lines holding `marker` under dir. Without ripgrep, only logs
-- modified after `since` are read, since the system grep is slow on gigabytes.
local function search(dir, marker, since)
  if not exists(dir) then return "" end
  local rg = find_rg()
  local r, err
  if rg then
    r, err = rex.exec({
      rg, "--fixed-strings", "--no-ignore", "--hidden", "--with-filename",
      "--no-heading", "--no-line-number", "--no-messages",
      "--glob", "*.jsonl", "--glob", "!**/subagents/**", marker, dir,
    }, { timeout = 60 })
  else
    local argv = { "find", dir, "-name", "*.jsonl", "!", "-path", "*/subagents/*" }
    if since then
      argv[#argv + 1] = "-newermt"
      argv[#argv + 1] = os.date("%Y-%m-%d %H:%M:%S", math.floor(since))
    end
    for _, a in ipairs({ "-exec", "grep", "-HF", marker, "{}", "+" }) do
      argv[#argv + 1] = a
    end
    r, err = rex.exec(argv, { env = { PATH = "/usr/bin:/bin", LC_ALL = "C" }, timeout = 180 })
  end
  if not r then return nil, err end
  if r.timed_out then return nil, "the search timed out" end
  return r.stdout or ""
end

-- Every enabled agent's records. One that can't be searched is left out.
local function all_records(since)
  local records = {}
  for _, agent in ipairs(AGENT_ORDER) do
    local def = AGENTS[agent]
    if config.agents[agent] ~= false and def.panes then
      local text = read_file((config.dirs[agent] or panes_dir()) .. "/panes.jsonl")
      for _, r in ipairs(parse_panes(agent, text or "")) do records[#records + 1] = r end
    elseif config.agents[agent] ~= false then
      local out, err = search(config.dirs[agent] or def.dir(), def.marker, since)
      if out then
        for _, r in ipairs(parse_records(agent, out)) do records[#records + 1] = r end
      else
        rex.log("warn", "rextore: " .. agent .. ": " .. tostring(err))
      end
    end
  end
  return records
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

-- The logs are searched once per server instance; later runs reuse it.
local cache = {}

local function candidates(panes, instance)
  if not (cache.instance and cache.instance == instance and cache.by_block) then
    local live, oldest = {}, nil
    for _, p in ipairs(panes) do
      live[p.block_id] = true
      local t = uuid7_seconds(p.block_id)
      if t and (not oldest or t < oldest) then oldest = t end
    end
    local records = all_records(oldest and (oldest - 86400))
    cache = { instance = instance, by_block = plan(records, live, last_activity) }
  end
  local items = {}
  for _, p in ipairs(panes) do
    local conv = cache.by_block[p.block_id]
    if conv then
      local state, detail = pane_state(p)
      items[#items + 1] = {
        pane = p, conv = conv, state = state, detail = detail,
        command = command_line(conv, command_of(conv.agent)),
      }
    end
  end
  return items
end

local function report(item)
  return {
    session = item.pane.session, block_id = item.pane.block_id,
    agent = item.conv.agent, conversation = item.conv.id, cwd = item.conv.cwd,
    last_active = item.conv.active, state = item.state, detail = item.detail,
    command = item.command,
  }
end

local function type_into(item, enter)
  local r, err = rex.block.call(TERMINAL, "write", {
    session_id = item.pane.session_id, block_id = item.pane.block_id,
    data = keystrokes(item.conv, command_of(item.conv.agent), enter),
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
  configure(opts)

  rex.action{
    name = "rextore",
    title = "Resume Agent Conversations",
    description = "Resume the agent conversation each pane of this session ran, "
      .. "in the panes waiting at a prompt.",
    keywords = "rextore claude codex opencode pi resume restore agent conversation",
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
  configure(args.options)
  for _, k in ipairs(OPTION_NAMES) do
    if args[k] ~= nil and type(args[k]) ~= "table" then config[k] = args[k] end
  end
  if args.startup then return startup(config.press_enter) end
  return (pass(nil, config.press_enter, args.dry_run))
end

-- For tests.
M._internal = {
  AGENTS = AGENTS,
  shquote = shquote,
  shword = shword,
  uuid7_seconds = uuid7_seconds,
  parse_records = parse_records,
  parse_panes = parse_panes,
  plan = plan,
  command_line = command_line,
  keystrokes = keystrokes,
}

if rex.args ~= nil and (rex.args.all or rex.args.startup) then
  return M.script(rex.args)
end
return M
