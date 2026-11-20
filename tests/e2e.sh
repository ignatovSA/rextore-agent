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
  projects_dir = "$tmp/projects",
  state_dir = "$tmp/state",
  command = "echo resumed",
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

# 2. Without Enter, the command is typed and left at the prompt.
act >/dev/null
sleep 0.5
screen | grep -F "cd '$tmp' && echo resumed --resume $id" >/dev/null || fail "typed command not on screen: $(screen | tail -3)"
screen | grep -E "^resumed --resume $id\$" >/dev/null && fail "the command ran without Enter"
echo "ok: the command is typed, not run"

# 3. Typing again replaces the line instead of appending to it; Enter runs it.
act press_enter=true >/dev/null
sleep 1
screen | grep -E "^resumed --resume $id\$" >/dev/null || fail "Enter did not run it: $(screen | tail -3)"
screen | grep -F -e "--resume $id cd" >/dev/null && fail "the second typing appended to the first"
echo "ok: retyping clears the prompt first, and press_enter runs it"

# 4. As a script, it covers every session; dry_run types nothing.
script() { rex do "$here/rextore-agent.lua" --args "$1" --json; }
opts="{\"projects_dir\":\"$tmp/projects\",\"state_dir\":\"$tmp/state\",\"command\":\"echo resumed\",\"wait\":5,\"rg\":${E2E_RG:-null}}"
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

echo "all end-to-end checks passed"
