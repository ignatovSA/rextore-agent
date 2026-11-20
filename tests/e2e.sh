#!/bin/sh
# End-to-end test against the running Rex server. Run it from a Rex pane:
#
#   sh tests/e2e.sh
#
# It opens a scratch tab in your session without focusing it, gives that pane
# a fake Claude transcript in a temporary projects directory, runs the action
# with `echo` standing in for `claude`, checks what was typed, and closes the
# tab. Your real transcripts and panes are not touched.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
: "${REX_SESSION:?run this from a Rex pane}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rextore-agent-e2e.XXXXXX")
window=""
cleanup() {
  [ -n "$window" ] && rex window close -s "$REX_SESSION" "$window" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

created=$(rex window new -s "$REX_SESSION" resume-e2e -c "$tmp" --focus=false --json)
window=$(printf '%s' "$created" | jq -er '.window_id')
block=$(printf '%s' "$created" | jq -er '.block_ids[0]')

# Wait for the shell's prompt: the line editor turns canonical mode off.
i=0
until rex block call -s "$REX_SESSION" -b "$block" input_mode 2>/dev/null | jq -e '.canonical == false' >/dev/null; do
  i=$((i + 1)); [ "$i" -gt 50 ] && fail "the scratch shell never reached its prompt"
  sleep 0.2
done
sleep 0.5

id=$(uuidgen | tr 'A-Z' 'a-z')
mkdir -p "$tmp/projects/-scratch"
content=$(printf "You're running in a Rex terminal.\n\nREX_BLOCK=%s\n" "$block" | jq -Rs .)
printf '%s\n' \
  "{\"parentUuid\":null,\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"SessionStart:startup\",\"hookEvent\":\"SessionStart\",\"content\":$content},\"type\":\"attachment\",\"cwd\":\"$tmp\",\"sessionId\":\"$id\",\"timestamp\":\"2026-01-01T00:00:00.000Z\"}" \
  "{\"type\":\"user\",\"timestamp\":\"2026-01-01T00:05:00.000Z\"}" \
  > "$tmp/projects/-scratch/$id.jsonl"

cat > "$tmp/dev.lua" <<EOF
dofile("$here/rextore-agent.lua").setup{
  on_start = false,
  dirs = { claude = "$tmp/projects", codex = "$tmp/codex", opencode = "$tmp/panes" },
  commands = { claude = "echo resumed", codex = "echo codex-resumed", opencode = "echo oc-resumed" },
  state_dir = "$tmp/state",
  rg = ${E2E_RG:-nil},
}
EOF
act() { rex do "$tmp/dev.lua" --action rextore "$@" --json; }
screen() { rex capture -s "$REX_SESSION" -b "$block" --trim --unwrap; }

# 1. The plan finds the scratch pane, ready at its prompt.
plan=$(act dry_run=true)
printf '%s' "$plan" | jq -e --arg b "$block" --arg id "$id" \
  '.ready | map(select(.block_id == $b)) | length == 1 and .[0].conversation == $id and .[0].last_active == "2026-01-01T00:05:00.000Z"' \
  >/dev/null || fail "dry run: $plan"
echo "ok: dry run finds the pane, ready, with its last activity"

# 2. With press_enter off, the command is typed and left at the prompt.
act press_enter=false >/dev/null
sleep 0.5
screen | grep -F "cd '$tmp' && echo resumed --resume $id" >/dev/null || fail "typed command not on screen: $(screen | tail -3)"
screen | grep -E "^resumed --resume $id\$" >/dev/null && fail "the command ran without Enter"
echo "ok: the command is typed, not run"

# 3. Typing again replaces the line instead of appending to it; by default
# Enter runs it.
act >/dev/null
sleep 1
screen | grep -E "^resumed --resume $id\$" >/dev/null || fail "Enter did not run it: $(screen | tail -3)"
screen | grep -F -e "--resume $id cd" >/dev/null && fail "the second typing appended to the first"
echo "ok: retyping clears the prompt first, and Enter runs it by default"

# 4. As a script, it covers every session; dry_run types nothing.
script() { rex do "$here/rextore-agent.lua" --args "$1" --json; }
opts="{\"dirs\":{\"claude\":\"$tmp/projects\",\"codex\":\"$tmp/codex\"},\"commands\":{\"claude\":\"echo resumed\",\"codex\":\"echo codex-resumed\"},\"state_dir\":\"$tmp/state\",\"wait\":5,\"press_enter\":false,\"rg\":${E2E_RG:-null}}"
all=$(script "{\"all\":true,\"dry_run\":true,\"options\":$opts}")
printf '%s' "$all" | jq -e --arg b "$block" '.ready | map(.block_id) | index($b) != null' >/dev/null || fail "all sessions: $all"
echo "ok: the script finds the pane across sessions"

# 5. The startup run types once per server instance.
first=$(script "{\"startup\":true,\"options\":$opts}")
printf '%s' "$first" | jq -e '.typed | length == 1' >/dev/null || fail "startup run: $first"
sleep 0.5
screen | tail -1 | grep -F "echo resumed --resume $id" >/dev/null || fail "startup typed nothing: $(screen | tail -2)"
second=$(script "{\"startup\":true,\"options\":$opts}")
printf '%s' "$second" | jq -e '.note == "already handled for this server"' >/dev/null || fail "second startup run: $second"
echo "ok: the startup run types once per server instance"

# 6. Codex: a newer session in the same pane wins, if it ran Rex's hook in the
# pane itself. A session run through Codex's app-server daemon ("vscode")
# carries the daemon's pane and doesn't count, however new.
codex_log() { # file id source time
  mkdir -p "$(dirname "$1")"
  printf '%s\n' \
    "{\"timestamp\":\"$4\",\"type\":\"session_meta\",\"payload\":{\"id\":\"$2\",\"cwd\":\"$tmp\",\"originator\":\"codex-tui\",\"source\":\"$3\"}}" \
    "{\"timestamp\":\"$4\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":$content}]}}" \
    > "$1"
}
cid=$(uuidgen | tr 'A-Z' 'a-z')
codex_log "$tmp/codex/2026/01/01/rollout-a-$cid.jsonl" "$cid" cli 2026-01-01T00:10:00.000Z
codex_log "$tmp/codex/2026/01/01/rollout-b.jsonl" "$(uuidgen | tr 'A-Z' 'a-z')" vscode 2026-01-01T00:20:00.000Z
plan=$(act dry_run=true)
printf '%s' "$plan" | jq -e --arg b "$block" --arg id "$cid" \
  '.ready | map(select(.block_id == $b)) | .[0].agent == "codex" and .[0].conversation == $id' \
  >/dev/null || fail "codex dry run: $plan"
act >/dev/null
sleep 1
screen | grep -E "^codex-resumed resume $cid\$" >/dev/null || fail "codex resume did not run: $(screen | tail -3)"
echo "ok: a newer Codex session wins, and runs as codex resume"

# 7. OpenCode: what rextore's plugin recorded in panes.jsonl. A session shown
# later wins; once quit, it doesn't come back, and the pane falls back to its
# previous conversation.
mkdir -p "$tmp/panes"
pane_line() { # agent event id time
  printf '{"agent":"%s","event":"%s","block":"%s","id":"%s","cwd":"%s","timestamp":"%s"}\n' "$1" "$2" "$block" "$3" "$tmp" "$4" >> "$tmp/panes/panes.jsonl"
}
pane_line opencode shown ses_e2e 2026-01-01T00:30:00.000Z
plan=$(act dry_run=true)
printf '%s' "$plan" | jq -e --arg b "$block" '.ready | map(select(.block_id == $b)) | .[0].agent == "opencode" and .[0].conversation == "ses_e2e"' \
  >/dev/null || fail "opencode dry run: $plan"
act >/dev/null
sleep 1
screen | grep -E "^oc-resumed --session ses_e2e\$" >/dev/null || fail "opencode resume did not run: $(screen | tail -3)"
pane_line opencode quit ses_e2e 2026-01-01T00:31:00.000Z
plan=$(act dry_run=true)
printf '%s' "$plan" | jq -e --arg b "$block" '.ready | map(select(.block_id == $b)) | .[0].agent == "codex"' \
  >/dev/null || fail "after an OpenCode quit: $plan"
echo "ok: an OpenCode session from the plugin's record wins, and a quit one doesn't come back"

echo "all end-to-end checks passed"
