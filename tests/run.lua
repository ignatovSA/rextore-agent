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

-- A transcript line as Claude Code writes Rex's SessionStart hook output,
-- with its keys in Claude Code's order (rex.json.encode would sort them).
local function hook_line(path, block, opts)
  opts = opts or {}
  local content = (opts.prefix or "You're running in a Rex terminal.")
    .. "\n\n```text\nREX_SESSION=session:01a1a73e-b63c-70fa-9d94-39ea38299b01\nREX_BLOCK="
    .. block .. "\n```\n"
  local s = rex.json.encode
  return path .. ":" .. '{"parentUuid":null,"isSidechain":false,"attachment":{'
    .. '"type":"hook_success","hookName":"SessionStart:startup","toolUseID":"t1",'
    .. '"hookEvent":' .. s(opts.event or "SessionStart") .. ',"content":' .. s(content) .. '},'
    .. '"type":' .. s(opts.type or "attachment") .. ','
    .. '"cwd":' .. s(opts.cwd or "/Users/me/project") .. ','
    .. '"timestamp":' .. s(opts.ts or "2026-11-20T10:00:00.000Z") .. '}'
end

local B1 = "block:01a1f65e-59dd-7ebd-9661-414687dfb0d0"
local B2 = "block:01a1abb7-61b5-7655-b3de-4e81f4013e18"
local P = "/Users/me/.claude/projects/-Users-me-project/"

-- shquote
eq("shquote plain", I.shquote("/a b"), "'/a b'")
eq("shquote quote", I.shquote("it's"), [['it'\''s']])

-- uuid7_seconds: the block IDs Rex hands out are UUIDv7
eq("uuid7", math.floor(I.uuid7_seconds("block:0193a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")), math.floor(0x0193a1b2c3d4 / 1000))
eq("uuid7 not v7", I.uuid7_seconds("block:01a1f65e-59dd-4ebd-9661-414687dfb0d0"), nil)

-- parse_records keeps only Rex's hook records
do
  local out = table.concat({
    hook_line(P .. "aaaa-1111.jsonl", B1),
    hook_line(P .. "bbbb-2222.jsonl", B2, { event = "PreToolUse" }),
    hook_line(P .. "cccc-3333.jsonl", B2, { prefix = "Something else." }),
    hook_line(P .. "dddd-4444.jsonl", B2, { type = "user" }),
    P .. "eeee-5555.jsonl:{not json",
    "garbage without a path",
  }, "\n")
  local recs = I.parse_records(out)
  eq("parse count", #recs, 1)
  eq("parse id", recs[1] and recs[1].id, "aaaa-1111")
  eq("parse block", recs[1] and recs[1].block, B1)
  eq("parse cwd", recs[1] and recs[1].cwd, "/Users/me/project")
end

-- parse_records: a path holding a colon still splits at ".jsonl:"
do
  local recs = I.parse_records(hook_line("/tmp/a:b/ffff-6666.jsonl", B1))
  eq("parse colon path", recs[1] and recs[1].id, "ffff-6666")
end

-- plan
do
  local function rec(id, block, ts) return { id = id, block = block, ts = ts, path = id } end
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

  -- panes that no longer exist are ignored
  by = I.plan({ rec("a", B2, "2026-11-19T00:00:00Z") }, { [B1] = true }, act)
  eq("plan dead pane", by[B2], nil)

  -- without a readable transcript the record's own time counts
  by = I.plan({ rec("zzz", B1, "2026-11-19T00:00:00Z") }, { [B1] = true }, function() return nil end)
  eq("plan fallback activity", by[B1] and by[B1].active, "2026-11-19T00:00:00Z")
end

-- command_line and keystrokes
do
  local conv = { id = "7d8390e5-e69c-4b1f-b174-5d8f79fd23a5", cwd = "/Users/me/it's here" }
  eq("command", I.command_line(conv, "claude"),
    [[ cd '/Users/me/it'\''s here' && claude --resume 7d8390e5-e69c-4b1f-b174-5d8f79fd23a5]])
  eq("command no cwd", I.command_line({ id = "x" }, "claude"), " claude --resume x")
  eq("keys clear first", I.keystrokes({ id = "x" }, "claude", false), "\5\21 claude --resume x")
  eq("keys enter", I.keystrokes({ id = "x" }, "claude", true), "\5\21 claude --resume x\r")
end

-- The marker matches the raw hook record but not an escaped mention of it.
do
  local line = hook_line(P .. "aaaa-1111.jsonl", B1)
  eq("marker in record", line:find(I.MARKER, 1, true) ~= nil, true)
  local mention = rex.json.encode({ type = "user", content = line })
  eq("marker not in mention", mention:find(I.MARKER, 1, true) == nil, true)
end

if #failures > 0 then
  for _, f in ipairs(failures) do io.stderr:write("FAIL " .. f .. "\n") end
  io.stderr:write(string.format("%d of %d checks failed\n", #failures, count))
  rex.stop(1)
end
return string.format("ok: %d checks passed", count)
