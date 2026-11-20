#!/bin/sh
# Installs rextore for the Rex server on this machine: links rextore-agent.lua
# into Rex's config folder, loads it from init.lua, links the plugins for the
# agents Rex has no hook for, and reloads the config.
# `sh install.sh --uninstall` undoes it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
init=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
dir=$(dirname "$init")
line='require("rextore-agent").setup{}'
opencode=${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$dir/rextore-agent.lua"
  if [ -f "$init" ] && grep -qF 'require("rextore-agent")' "$init"; then
    tmp=$(mktemp)
    grep -vF 'require("rextore-agent")' "$init" > "$tmp" || true
    cat "$tmp" > "$init"
    rm -f "$tmp"
  fi
  if [ -L "$opencode/plugins/rextore-agent/tui.ts" ]; then
    rm -f "$opencode/plugins/rextore-agent/tui.ts"
    rmdir "$opencode/plugins/rextore-agent" 2>/dev/null || true
    echo "removed the OpenCode plugin"
  fi
  rex config reload
  echo "uninstalled from $dir"
  exit 0
fi

mkdir -p "$dir"
ln -sfn "$here/rextore-agent.lua" "$dir/rextore-agent.lua"
touch "$init"
grep -qF 'require("rextore-agent")' "$init" || printf '%s\n' "$line" >> "$init"

# OpenCode loads plugins/<name>/tui.ts from its config folder by itself.
if [ -d "$opencode" ]; then
  mkdir -p "$opencode/plugins/rextore-agent"
  ln -sfn "$here/agents/opencode/tui.ts" "$opencode/plugins/rextore-agent/tui.ts"
  echo "OpenCode plugin: $opencode/plugins/rextore-agent/tui.ts"
fi

rex config check "$init"
rex config reload
echo "installed: $dir/rextore-agent.lua -> $here/rextore-agent.lua"
