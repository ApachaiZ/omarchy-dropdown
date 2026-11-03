#!/bin/bash
# Remove the plugin's code and keyboard integration. Application data and the
# user's session are never touched.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DEST="$CONFIG_HOME/omarchy/plugins/apach.dropdown"
STAMP="$(date +%Y%m%d%H%M%S)"

# Remember where the bar widget lived so a later reinstall can restore it.
python3 - "$CONFIG_HOME/omarchy/shell.json" "$CONFIG_HOME/omarchy/dropdown.bar-placement.json" <<'PLACEMENT'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(src))
except Exception:
    sys.exit(0)
if not isinstance(data, dict):
    sys.exit(0)
bar = data.get("bar")
layout = bar.get("layout") if isinstance(bar, dict) else None
if not isinstance(layout, dict):
    sys.exit(0)
for section in ("left", "center", "right"):
    entries = layout.get(section)
    if not isinstance(entries, list):
        continue
    for index, entry in enumerate(entries):
        if isinstance(entry, dict) and entry.get("id") == "apach.dropdown":
            try:
                with open(dst, "w") as out:
                    json.dump({"section": section, "index": index}, out)
            except Exception:
                sys.exit(0)
            print("Saved bar placement:", section, index)
            sys.exit(0)
PLACEMENT

echo "Restoring any parked dropdown windows..."
omarchy-shell -q apach.dropdown restoreAll || true
omarchy-shell -q shell hide apach.dropdown || true

# Clear the generated direct binds before the service is destroyed. The
# service also does this when it notices the plugin is disabled, but doing it
# here keeps the operation idempotent if the service is already gone.
echo "Clearing generated direct shortcuts..."
omarchy-shell -q apach.dropdown cleanup >/dev/null 2>&1 || true

echo "Disabling apach.dropdown..."
omarchy plugin disable apach.dropdown >/dev/null 2>&1 || true

if [[ -e $DEST ]]; then
  # Keep the removed copy outside the plugin scan root, otherwise the shell
  # still discovers its manifest and keeps loading a dead plugin.
  BACKUP_DIR="$CONFIG_HOME/omarchy/plugin-backups"
  mkdir -p "$BACKUP_DIR"
  mv "$DEST" "$BACKUP_DIR/apach.dropdown.removed.$STAMP"
  echo "Moved plugin code to $BACKUP_DIR/apach.dropdown.removed.$STAMP (delete it when you are satisfied)."
fi

HYPR_DIR="$CONFIG_HOME/hypr"
if [[ -f $HYPR_DIR/hyprland.lua ]]; then
  cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.bak.$STAMP"
  python3 - "$HYPR_DIR/hyprland.lua" <<'PY'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
lines = [line for line in lines if 'require("hypr.dropdown")' not in line]
with open(path, "w") as f:
    f.writelines(lines)
PY
  echo "Removed require(\"hypr.dropdown\") from $HYPR_DIR/hyprland.lua"
fi

rm -f "$HYPR_DIR/dropdown-binds.lua"

if [[ -f $HYPR_DIR/dropdown.lua ]]; then
  if [[ -f $REPO/hypr/dropdown.lua ]] && cmp -s "$HYPR_DIR/dropdown.lua" "$REPO/hypr/dropdown.lua"; then
    rm -f "$HYPR_DIR/dropdown.lua"
    echo "Removed the unmodified $HYPR_DIR/dropdown.lua"
  else
    echo "Kept $HYPR_DIR/dropdown.lua because it has local changes."
  fi
fi

if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null 2>&1 || true
fi

cat <<EOF

Removed apach.dropdown.
Kept:
  $CONFIG_HOME/omarchy/dropdown.json        (your settings)
  ${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/dropdown-state.json  (ephemeral, can be deleted)
Application profiles, browser sessions and launchers were never modified.
EOF
