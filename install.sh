#!/bin/bash
# Local install for a checkout. The marketplace path is `omarchy plugin add`.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DEST="$CONFIG_HOME/omarchy/plugins/apach.dropdown"
HYPR_DIR="$CONFIG_HOME/hypr"
STAMP="$(date +%Y%m%d%H%M%S)"

echo "Installing Omarchy Dropdown from $REPO"
mkdir -p "$(dirname "$DEST")"
if [[ -e $DEST ]]; then
  echo "Replacing $DEST (backup: $DEST.bak.$STAMP)"
  mv "$DEST" "$DEST.bak.$STAMP"
fi
mkdir -p "$DEST"
rsync -a --exclude='.git' --exclude='.github' --exclude='scripts' --exclude='tests' --exclude='docs/screenshots' "$REPO/" "$DEST/"

mkdir -p "$CONFIG_HOME/omarchy"
if [[ ! -f $CONFIG_HOME/omarchy/dropdown.json ]]; then
  cp "$REPO/config/dropdown.example.json" "$CONFIG_HOME/omarchy/dropdown.json"
  echo "Created $CONFIG_HOME/omarchy/dropdown.json"
fi

if [[ -d $HYPR_DIR ]]; then
  if [[ ! -f $HYPR_DIR/dropdown.lua ]]; then
    cp "$REPO/hypr/dropdown.lua" "$HYPR_DIR/dropdown.lua"
    echo "Created $HYPR_DIR/dropdown.lua"
  else
    echo "Kept existing $HYPR_DIR/dropdown.lua"
    if ! grep -q 'define_submap("apach-dropdown"' "$HYPR_DIR/dropdown.lua"; then
      cat >> "$HYPR_DIR/dropdown.lua" <<'LUA'

-- Bare Escape while a dropdown is visible.
hl.define_submap("apach-dropdown", function()
  hl.bind("Escape", function()
    hl.dispatch(hl.dsp.exec_cmd("omarchy-shell apach.dropdown reduce"))
    hl.dispatch(hl.dsp.submap("reset"))
  end)
end)
LUA
      echo "Added the Escape submap to $HYPR_DIR/dropdown.lua"
    fi
    if ! grep -q 'dropdown-binds.lua' "$HYPR_DIR/dropdown.lua"; then
      cat >> "$HYPR_DIR/dropdown.lua" <<'LUA'

-- Direct application shortcuts configured in Dropdown (Manage → D).
local generatedBinds = (os.getenv("HOME") or "") .. "/.config/hypr/dropdown-binds.lua"
local generatedFile = io.open(generatedBinds, "r")
if generatedFile then
  generatedFile:close()
  dofile(generatedBinds)
end
LUA
      echo "Added the direct-shortcut loader to $HYPR_DIR/dropdown.lua"
    fi
  fi
  if [[ -f $HYPR_DIR/hyprland.lua ]] && ! grep -q 'require("hypr.dropdown")' "$HYPR_DIR/hyprland.lua"; then
    cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.bak.$STAMP"
    python3 - "$HYPR_DIR/hyprland.lua" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
for i, line in enumerate(lines):
    if 'require("hypr.bindings")' in line:
        lines.insert(i + 1, 'require("hypr.dropdown")\n')
        break
else:
    lines.append('\nrequire("hypr.dropdown")\n')
with open(path, "w") as f:
    f.writelines(lines)
PY
    echo "Added require(\"hypr.dropdown\") to $HYPR_DIR/hyprland.lua"
  fi
fi

omarchy-shell shell rescanPlugins || true
omarchy plugin enable apach.dropdown || true
# Restore the bar placement recorded by uninstall.sh, if any.
placement=""
if [[ -f $CONFIG_HOME/omarchy/dropdown.bar-placement.json ]]; then
  placement="$(python3 - "$CONFIG_HOME/omarchy/dropdown.bar-placement.json" <<'PLACEMENT'
import json, sys
try:
    p = json.load(open(sys.argv[1]))
    if p.get("section") in ("left", "center", "right") and isinstance(p.get("index"), int):
        print(p["section"], p["index"])
except Exception:
    pass
PLACEMENT
)"
fi
if [[ -n $placement ]]; then
  omarchy bar put apach.dropdown --section "${placement% *}" --index "${placement#* }" >/dev/null 2>&1 \
    || omarchy bar put apach.dropdown --section right >/dev/null 2>&1 || true
else
  omarchy bar put apach.dropdown --section right >/dev/null 2>&1 || true
fi

if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null
  if [[ -n $(hyprctl configerrors 2>/dev/null) ]]; then
    echo "Hyprland reported configuration errors:" >&2
    hyprctl configerrors >&2
  fi
fi

cat <<EOF

Installed apach.dropdown.

  Prefix          Super + Alt + ;   (Super + ; also opens the palette)
  Palette          press d for Discord, m to manage apps, ? for help
  Remove binds     delete ~/.config/hypr/dropdown.lua and the
                   require("hypr.dropdown") line from hyprland.lua

Change the prefixes in ~/.config/hypr/dropdown.lua, then run: hyprctl reload
Settings and schema: README.md and ~/.config/omarchy/dropdown.json
EOF
