#!/bin/sh
# Installs rextore for the Rex server on this machine: links rextore-agent.lua
# into Rex's config folder, loads it from init.lua, links the plugins for the
# agents Rex has no hook for, and reloads the config.
# `sh install.sh --uninstall` undoes it.
#
# Without a checkout next to it, as when piped from curl, it downloads the
# files to ~/.local/share/rextore-agent first:
#
#   curl -fsSL https://raw.githubusercontent.com/ignatovSA/rextore-agent/main/install.sh | sh
#
# REXTORE_URL picks where to download from, such as a tag or a commit.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
url=${REXTORE_URL:-https://raw.githubusercontent.com/ignatovSA/rextore-agent/main}
files="rextore-agent.lua agents/opencode/tui.ts agents/pi/rextore-agent.ts"
downloaded=""
if [ ! -f "$here/rextore-agent.lua" ]; then
  here=${XDG_DATA_HOME:-$HOME/.local/share}/rextore-agent
  downloaded=1
fi
init=${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}
dir=$(dirname "$init")
line='require("rextore-agent").setup{}'
opencode=${OPENCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/opencode}
pi=${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}

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
  if [ -L "$pi/extensions/rextore-agent.ts" ]; then
    rm -f "$pi/extensions/rextore-agent.ts"
    echo "removed the Pi extension"
  fi
  if [ -n "$downloaded" ] && [ -f "$here/rextore-agent.lua" ]; then
    rm -f $(for f in $files; do printf '%s ' "$here/$f"; done)
    rmdir "$here/agents/opencode" "$here/agents/pi" "$here/agents" "$here" 2>/dev/null || true
    echo "removed the downloaded files from $here"
  fi
  rex config reload
  echo "uninstalled from $dir"
  exit 0
fi

if [ -n "$downloaded" ]; then
  for f in $files; do
    mkdir -p "$here/$(dirname "$f")"
    curl -fsSL "$url/$f" -o "$here/$f.part"
    mv "$here/$f.part" "$here/$f"
  done
  echo "downloaded from $url to $here"
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

# Pi loads extensions/*.ts from its agent folder by itself.
if [ -d "$pi" ]; then
  mkdir -p "$pi/extensions"
  ln -sfn "$here/agents/pi/rextore-agent.ts" "$pi/extensions/rextore-agent.ts"
  echo "Pi extension: $pi/extensions/rextore-agent.ts"
fi

rex config check "$init"
rex config reload
echo "installed: $dir/rextore-agent.lua -> $here/rextore-agent.lua"
