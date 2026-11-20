-- Unit tests for rextore-agent.lua. Run from the repository root:
--
--   rex do tests/run.lua
--
-- They use Rex's own Lua (5.1 with rex.json), touch no session and type
-- into no pane.

local M = dofile("rextore-agent.lua")
local I = M._internal

local failures, count = {}, 0

local function eq(name, got, want)
  count = count + 1
  if got ~= want then
    failures[#failures + 1] = string.format("%s: got %s, want %s", name, tostring(got), tostring(want))
  end
end

local s = rex.json.encode
local B1 = "block:01a1f65e-59dd-7ebd-9661-414687dfb0d0"
local B2 = "block:01a1abb7-61b5-7655-b3de-4e81f4013e18"

local function rex_text(block, prefix)
  return (prefix or "You're running in a Rex terminal.")
    .. "\n\n```text\nREX_SESSION=session:01a1a73e-b63c-70fa-9d94-39ea38299b01\nREX_BLOCK="
    .. block .. "\n```\n"
end

-- A transcript line as Claude Code writes Rex's SessionStart hook output,
-- with its keys in Claude Code's order (rex.json.encode would sort them).
local function claude_line(path, block, opts)
  opts = opts or {}
  return path .. ":" .. '{"parentUuid":null,"isSidechain":false,"attachment":{'
    .. '"type":"hook_success","hookName":"SessionStart:startup","toolUseID":"t1",'
    .. '"hookEvent":' .. s(opts.event or "SessionStart") .. ',"content":' .. s(rex_text(block, opts.prefix)) .. '},'
    .. '"type":' .. s(opts.type or "attachment") .. ','
    .. '"cwd":' .. s(opts.cwd or "/Users/me/project") .. ','
    .. '"timestamp":' .. s(opts.ts or "2026-11-20T10:00:00.000Z") .. '}'
end

-- A Codex log line holding Rex's hook output, in Codex's key order.
local function codex_line(path, block, opts)
  opts = opts or {}
  return path .. ":" .. '{"timestamp":' .. s(opts.ts or "2026-11-20T10:00:00.000Z")
    .. ',"ordinal":11,"type":"response_item","payload":{"type":"message","id":"msg_1",'
    .. '"role":' .. s(opts.role or "developer") .. ',"content":[{"type":"input_text","text":'
    .. s(rex_text(block)) .. '}]}}'
end

local P = "/Users/me/.claude/projects/-Users-me-project/"
local C = "/Users/me/.codex/sessions/2026/11/20/"

-- shquote and shword
eq("shquote plain", I.shquote("/a b"), "'/a b'")
eq("shquote quote", I.shquote("it's"), [['it'\''s']])
eq("shword safe", I.shword("/a/b-c_d.jsonl"), "/a/b-c_d.jsonl")
eq("shword space", I.shword("/a b/c.jsonl"), "'/a b/c.jsonl'")

-- uuid7_seconds: the block IDs Rex hands out are UUIDv7
eq("uuid7", math.floor(I.uuid7_seconds("block:0193a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")), math.floor(0x0193a1b2c3d4 / 1000))
eq("uuid7 not v7", I.uuid7_seconds("block:01a1f65e-59dd-4ebd-9661-414687dfb0d0"), nil)

-- Claude Code: only Rex's SessionStart hook records count
do
  local out = table.concat({
    claude_line(P .. "aaaa-1111.jsonl", B1),
    claude_line(P .. "bbbb-2222.jsonl", B2, { event = "PreToolUse" }),
    claude_line(P .. "cccc-3333.jsonl", B2, { prefix = "Something else." }),
    claude_line(P .. "dddd-4444.jsonl", B2, { type = "user" }),
    P .. "eeee-5555.jsonl:{not json",
    "garbage without a path",
  }, "\n")
  local recs = I.parse_records("claude", out)
  eq("claude count", #recs, 1)
  eq("claude id", recs[1] and recs[1].id, "aaaa-1111")
  eq("claude block", recs[1] and recs[1].block, B1)
  eq("claude cwd", recs[1] and recs[1].cwd, "/Users/me/project")
  eq("claude agent", recs[1] and recs[1].agent, "claude")
  recs = I.parse_records("claude", claude_line("/tmp/a:b/ffff-6666.jsonl", B1))
  eq("claude colon path", recs[1] and recs[1].id, "ffff-6666")
end

-- Codex: only sessions that ran Rex's hook in their own pane count
do
  local metas = {
    [C .. "tui.jsonl"] = { id = "01a1aaaa-0000-7000-8000-000000000001", cwd = "/w", originator = "codex-tui", source = "cli" },
    [C .. "exec.jsonl"] = { id = "01a1aaaa-0000-7000-8000-000000000002", cwd = "/w", originator = "codex_exec", source = "exec" },
    [C .. "daemon.jsonl"] = { id = "01a1aaaa-0000-7000-8000-000000000004", cwd = "/w", originator = "codex-tui", source = "vscode" },
    [C .. "sub.jsonl"] = {
      id = "01a1aaaa-0000-7000-8000-000000000003", cwd = "/w", originator = "codex-tui",
      agent_path = "/root/review", source = { subagent = { thread_spawn = {} } },
    },
  }
  local function meta(path) return metas[path] end
  local out = table.concat({
    codex_line(C .. "tui.jsonl", B1),
    codex_line(C .. "exec.jsonl", B1),
    codex_line(C .. "sub.jsonl", B1),
    codex_line(C .. "daemon.jsonl", B1),
    codex_line(C .. "tui.jsonl", B2, { role = "user" }),
    codex_line(C .. "missing-meta.jsonl", B2),
  }, "\n")
  local recs = I.parse_records("codex", out, meta)
  eq("codex count", #recs, 1)
  eq("codex id from meta", recs[1] and recs[1].id, "01a1aaaa-0000-7000-8000-000000000001")
  eq("codex block", recs[1] and recs[1].block, B1)
  eq("codex cwd", recs[1] and recs[1].cwd, "/w")
end

-- panes.jsonl, which rextore's own agent plugins write
do
  local function pane_line(t) return s(t) end
  local text = table.concat({
    pane_line({ agent = "opencode", event = "shown", block = B1, id = "ses_abc", cwd = "/w", timestamp = "2026-11-20T10:00:00.000Z" }),
    pane_line({ agent = "opencode", event = "quit", block = B1, id = "ses_abc", cwd = "/w", timestamp = "2026-11-20T11:00:00.000Z" }),
    pane_line({ agent = "pi", event = "shown", block = B2, id = "p1", timestamp = "2026-11-20T10:00:00.000Z" }),
    pane_line({ agent = "opencode", event = "shown", block = "not a block", id = "ses_x" }),
    pane_line({ agent = "opencode", event = "shown", block = B2, id = "bad id; rm -rf ~" }),
    "{not json",
  }, "\n")
  local recs = I.parse_panes("opencode", text)
  eq("panes count", #recs, 2)
  eq("panes id with underscore", recs[1] and recs[1].id, "ses_abc")
  eq("panes shown", recs[1] and recs[1].ended, false)
  eq("panes quit", recs[2] and recs[2].ended, true)
  eq("panes other agent", #I.parse_panes("pi", text), 1)

  -- a session quit on purpose isn't reopened; shown again later, it is
  local by = I.plan(recs, { [B1] = true }, function() return nil end)
  eq("plan skips a quit session", by[B1], nil)
  recs[#recs + 1] = { agent = "opencode", id = "ses_abc", block = B1, cwd = "/w", ts = "2026-11-20T12:00:00.000Z", ended = false }
  by = I.plan(recs, { [B1] = true }, function() return nil end)
  eq("plan reopens a session shown after its quit", by[B1] and by[B1].id, "ses_abc")
  eq("opencode command", I.command_line(by[B1], "opencode"), " cd '/w' && opencode --session ses_abc")
end

-- plan
do
  local function rec(id, block, ts, agent) return { id = id, block = block, ts = ts, path = id, agent = agent or "claude" } end
  local activity = { a = "2026-11-20T09:00:00Z", b = "2026-11-20T11:00:00Z", c = "2026-11-20T12:00:00Z" }
  local function act(path) return activity[path] end

  -- a pane gets the conversation active most recently
  local by = I.plan({ rec("a", B1, "2026-11-19T00:00:00Z"), rec("b", B1, "2026-11-18T00:00:00Z") },
    { [B1] = true }, act)
  eq("plan newest wins", by[B1] and by[B1].id, "b")

  -- a conversation resumed in another pane belongs to that pane only
  by = I.plan({
    rec("c", B1, "2026-11-19T00:00:00Z"),
    rec("c", B2, "2026-11-20T00:00:00Z"),
  }, { [B1] = true, [B2] = true }, act)
  eq("plan moved: old pane", by[B1], nil)
  eq("plan moved: new pane", by[B2] and by[B2].id, "c")

  -- the newest conversation wins across agents too
  by = I.plan({ rec("a", B1, "2026-11-19T00:00:00Z", "claude"), rec("b", B1, "2026-11-19T00:00:00Z", "codex") },
    { [B1] = true }, act)
  eq("plan across agents", by[B1] and by[B1].agent, "codex")

  -- the same ID under two agents is two conversations
  by = I.plan({ rec("c", B1, "2026-11-19T00:00:00Z", "claude"), rec("c", B2, "2026-11-20T00:00:00Z", "codex") },
    { [B1] = true, [B2] = true }, act)
  eq("plan ids per agent", by[B1] and by[B1].agent, "claude")

  -- panes that no longer exist are ignored
  by = I.plan({ rec("a", B2, "2026-11-19T00:00:00Z") }, { [B1] = true }, act)
  eq("plan dead pane", by[B2], nil)

  -- without a readable log the record's own time counts
  by = I.plan({ rec("zzz", B1, "2026-11-19T00:00:00Z") }, { [B1] = true }, function() return nil end)
  eq("plan fallback activity", by[B1] and by[B1].active, "2026-11-19T00:00:00Z")
end

-- command_line and keystrokes
do
  local conv = { agent = "claude", id = "7d8390e5-e69c-4b1f-b174-5d8f79fd23a5", cwd = "/Users/me/it's here" }
  eq("claude command", I.command_line(conv, "claude"),
    [[ cd '/Users/me/it'\''s here' && claude --resume 7d8390e5-e69c-4b1f-b174-5d8f79fd23a5]])
  eq("command no cwd", I.command_line({ agent = "claude", id = "x" }, "claude"), " claude --resume x")
  eq("codex command", I.command_line({ agent = "codex", id = "x", cwd = "/w" }, "codex"), " cd '/w' && codex resume x")
  eq("custom command", I.command_line({ agent = "claude", id = "x" }, "claude --model opus"), " claude --model opus --resume x")
  eq("keys clear first", I.keystrokes({ agent = "claude", id = "x" }, "claude", false), "\5\21 claude --resume x")
  eq("keys enter", I.keystrokes({ agent = "claude", id = "x" }, "claude", true), "\5\21 claude --resume x\r")
end

-- Each marker matches the raw hook line but not an escaped mention of it.
do
  local lines = { claude = claude_line(P .. "a.jsonl", B1), codex = codex_line(C .. "a.jsonl", B1) }
  for agent, line in pairs(lines) do
    local marker = I.AGENTS[agent].marker
    eq(agent .. " marker in record", line:find(marker, 1, true) ~= nil, true)
    local mention = s({ type = "user", content = line })
    eq(agent .. " marker not in mention", mention:find(marker, 1, true) == nil, true)
  end
end

if #failures > 0 then
  for _, f in ipairs(failures) do io.stderr:write("FAIL " .. f .. "\n") end
  io.stderr:write(string.format("%d of %d checks failed\n", #failures, count))
  rex.stop(1)
end
return string.format("ok: %d checks passed", count)
