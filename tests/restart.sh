#!/bin/sh
# Restart test: runs a throwaway Rex server on its own socket and state
# directory, never the one your Rex app uses.
#
#   sh tests/restart.sh
#
# It starts the server with an init.lua that loads the plugin, opens a pane,
# stops the server (which saves the pane), writes a fake Claude transcript for
# that pane, and starts the server again. Rex restores the pane under the same
# ID, and the plugin must type the resume command into it by itself. `echo`
# stands in for `claude`.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
rexbin=$(readlink -f "$(command -v rex)")
tmp=$(mktemp -d /tmp/rcr.XXXXXX)
sock="unix://$tmp/s.sock"
pid=""

fail() { echo "FAIL: $*" >&2; [ -f "$tmp/server.log" ] && tail -20 "$tmp/server.log" >&2; exit 1; }
r() { "$rexbin" -S "$sock" --autostart=false "$@"; }

cleanup() {
  r server stop --discard --state-dir "$tmp/rex-state" >/dev/null 2>&1 || true
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -n "${KEEP:-}" ] && echo "kept $tmp" >&2 || rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/config" "$tmp/projects/-scratch"
ln -s "$here/rextore-agent.lua" "$tmp/config/rextore-agent.lua"
cat > "$tmp/config/init.lua" <<EOF
require("rextore-agent").setup{
  projects_dir = "$tmp/projects",
  state_dir = "$tmp/state",
  command = "echo resumed",
}
EOF

# Like the Rex app: the binary's full path, a bare PATH, REX_SERVER set, and
# none of this pane's Rex variables.
start_server() {
  env -i HOME="$HOME" USER="${USER:-}" SHELL="${SHELL:-/bin/sh}" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    REX_SERVER="$sock" \
    "$rexbin" server run --listen "$sock" --state-dir "$tmp/rex-state" \
    --config "$tmp/config/init.lua" >>"$tmp/server.log" 2>&1 &
  pid=$!
  i=0
  until r server status >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -gt 50 ] && fail "the test server did not start"
    sleep 0.2
  done
}

wait_prompt() {
  i=0
  until r block call -s "$1" -b "$2" input_mode 2>/dev/null | jq -e '.canonical == false' >/dev/null; do
    i=$((i + 1)); [ "$i" -gt 75 ] && fail "the shell never reached its prompt"
    sleep 0.2
  done
}

# First run: a session with one pane.
start_server
created=$(r new e2e -c "$tmp" --json)
session=$(printf '%s' "$created" | jq -er '.session_id')
block=$(printf '%s' "$created" | jq -er '.initial_windows[0].block_ids[0]')
wait_prompt "$session" "$block"
echo "ok: test server up, pane $block"

r server stop >/dev/null
wait "$pid" 2>/dev/null || true
pid=""
echo "ok: test server stopped"

# A Claude conversation that ran in that pane.
id=$(uuidgen | tr 'A-Z' 'a-z')
content=$(printf "You're running in a Rex terminal.\n\nREX_BLOCK=%s\n" "$block" | jq -Rs .)
printf '%s\n' \
  "{\"parentUuid\":null,\"attachment\":{\"type\":\"hook_success\",\"hookName\":\"SessionStart:startup\",\"hookEvent\":\"SessionStart\",\"content\":$content},\"type\":\"attachment\",\"cwd\":\"$tmp\",\"sessionId\":\"$id\",\"timestamp\":\"2026-01-01T00:00:00.000Z\"}" \
  > "$tmp/projects/-scratch/$id.jsonl"

# Second run: Rex restores the pane, and the plugin types into it.
start_server
r block call -s "$session" -b "$block" process >/dev/null 2>&1 || fail "the pane was not restored under the same ID"
echo "ok: test server restarted, pane restored under the same ID"

want="cd '$tmp' && echo resumed --resume $id"
i=0
until r capture -s "$session" -b "$block" --trim --unwrap 2>/dev/null | grep -F -e "$want" >/dev/null; do
  i=$((i + 1)); [ "$i" -gt 60 ] && fail "nothing typed within 60s: $(r capture -s "$session" -b "$block" --trim --unwrap | tail -3)"
  sleep 1
done
echo "ok: the resume command was typed by itself after ${i}s"

r capture -s "$session" -b "$block" --trim --unwrap | grep -E "^resumed --resume $id\$" >/dev/null \
  && fail "the command ran, but press_enter is off"
jq -e '.done == true' "$tmp/state/state.json" >/dev/null || fail "state not marked done: $(cat "$tmp/state/state.json")"
jq -e '.typed | length == 1' "$tmp/state/last-run.json" >/dev/null || fail "last run: $(cat "$tmp/state/last-run.json")"
echo "ok: typed once, not run, state recorded"

# A config reload must not type again.
r send-key -s "$session" -b "$block" ctrl+u >/dev/null
r config reload >/dev/null
sleep 5
r capture -s "$session" -b "$block" --trim --unwrap | tail -1 | grep -F -e "--resume" >/dev/null \
  && fail "a config reload typed the command again"
echo "ok: a config reload does not type again"

# The palette action runs inside the server and covers the session it runs in.
plan=$(env -u REX_SESSION -u REX_BLOCK "$rexbin" -S "$sock" --autostart=false do -s "$session" rextore dry_run=true --json)
printf '%s' "$plan" | jq -e --arg b "$block" '.ready | map(.block_id) | index($b) != null' >/dev/null \
  || fail "the action inside the server: $plan"
echo "ok: the action inside the server finds the pane in its session"

echo "all restart checks passed"
