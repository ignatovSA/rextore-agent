#!/bin/sh
# Installs the plugin for the Rex server on this machine: links
# rextore-agent.lua into Rex's config folder, loads it from init.lua, and
# reloads the config. `sh install.sh --uninstall` undoes it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
init=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
dir=$(dirname "$init")
line='require("rextore-agent").setup{}'

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$dir/rextore-agent.lua"
  if [ -f "$init" ] && grep -qF 'require("rextore-agent")' "$init"; then
    tmp=$(mktemp)
    grep -vF 'require("rextore-agent")' "$init" > "$tmp" || true
    cat "$tmp" > "$init"
    rm -f "$tmp"
  fi
  rex config reload
  echo "uninstalled from $dir"
  exit 0
fi

mkdir -p "$dir"
ln -sfn "$here/rextore-agent.lua" "$dir/rextore-agent.lua"
touch "$init"
grep -qF 'require("rextore-agent")' "$init" || printf '%s\n' "$line" >> "$init"
rex config check "$init"
rex config reload
echo "installed: $dir/rextore-agent.lua -> $here/rextore-agent.lua"
