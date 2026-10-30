#!/bin/bash
# Regenerate the public screenshots with only the three standard Omarchy
# defaults, on an empty workspace. Your real config, state and direct binds are
# backed up first and restored by the EXIT trap.
#
# Requirements: grim, ImageMagick (`magick`), wtype, jq/python3, omarchy.
# Usage: ./scripts/screenshots.sh [monitor] [workspace]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/docs/screenshots"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/dropdown.json"
BINDS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/dropdown-binds.lua"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/dropdown-state.json"
MONITOR="${1:-$(hyprctl monitors -j | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')}"
WORKSPACE="${2:-}"
TMP="$(mktemp -d)"

for tool in grim magick wtype hyprctl omarchy-shell; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

mkdir -p "$OUT" "$TMP"
restore() {
  echo "Restoring your configuration..."
  if [[ -f $TMP/dropdown.json ]]; then cp "$TMP/dropdown.json" "$CONFIG"; fi
  if [[ -f $TMP/dropdown-binds.lua ]]; then cp "$TMP/dropdown-binds.lua" "$BINDS"; fi
  if [[ -f $TMP/dropdown-state.json ]]; then cp "$TMP/dropdown-state.json" "$STATE"; fi
  omarchy restart shell >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap restore EXIT

cp "$CONFIG" "$TMP/dropdown.json"
cp "$BINDS" "$TMP/dropdown-binds.lua" 2>/dev/null || true
cp "$STATE" "$TMP/dropdown-state.json" 2>/dev/null || true

cat > "$CONFIG" <<'JSON'
{
  "schemaVersion": 1,
  "settings": {
    "screen": "auto",
    "autoHideOnFocusLoss": true,
    "autoHideDelayMs": 5000,
    "topApps": 5,
    "geometry": {
      "preset": "medium",
      "placement": "top",
      "edge": "top",
      "widthPercent": 60,
      "heightPercent": 80,
      "topOffset": 12,
      "sideMargin": 0
    },
    "animations": {
      "mode": "slide+fade",
      "durationMs": 180,
      "easing": "outCubic",
      "reducedMotion": false,
      "windowSlide": true
    },
    "tabs": { "position": "top" }
  },
  "apps": {
    "system.terminal": { "enabled": true, "key": "t" },
    "system.agent": { "enabled": true, "key": "i" },
    "system.files": { "enabled": true, "key": "f" }
  }
}
JSON

omarchy restart shell >/dev/null 2>&1
sleep 9

# Choose an empty workspace AFTER the restart: restored personal windows can
# land on the workspace that was free before the restart.
if [[ -z $WORKSPACE ]]; then
  WORKSPACE=$(hyprctl workspaces -j | python3 -c '
import json, sys
monitor = sys.argv[1]
free = [w for w in json.load(sys.stdin)
        if w.get("monitor") == monitor and w.get("windows") == 0
        and not str(w.get("name", "")).startswith("special")]
print(free[0]["name"] if free else "10")
' "$MONITOR")
fi
hyprctl dispatch "hl.dsp.focus({ monitor = \"$MONITOR\" })" >/dev/null 2>&1 || true
hyprctl dispatch "hl.dsp.focus({ workspace = \"$WORKSPACE\" })" >/dev/null 2>&1 || true
sleep 0.8
# If a restored window still occupies it, try the next empty workspace once.
count=$(hyprctl activeworkspace -j | python3 -c 'import json,sys; print(json.load(sys.stdin).get("windows",0))')
if [[ $count != 0 ]]; then
  WORKSPACE=$(hyprctl workspaces -j | python3 -c '
import json, sys
monitor = sys.argv[1]
free = [w for w in json.load(sys.stdin)
        if w.get("monitor") == monitor and w.get("windows") == 0
        and not str(w.get("name", "")).startswith("special")]
print(free[0]["name"] if free else "10")
' "$MONITOR")
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$WORKSPACE\" })" >/dev/null 2>&1 || true
  sleep 0.8
fi

# Do not show a real shell prompt (user@host) in the Preview capture.
omarchy-shell apach.dropdown closeApp system.terminal >/dev/null 2>&1 || true
sleep 1.2

omarchy-shell apach.dropdown openOn "$MONITOR" >/dev/null 2>&1
sleep 0.8
grim -o "$MONITOR" "$TMP/palette.png"
wtype -k space
sleep 0.9
grim -o "$MONITOR" "$TMP/drawer.png"
wtype -k Escape
sleep 0.4

wtype -k m; sleep 0.5; wtype "system."; sleep 0.6; grim -o "$MONITOR" "$TMP/manage.png"
wtype -k Escape; sleep 0.3
wtype -k s; sleep 0.8; grim -o "$MONITOR" "$TMP/settings.png"
wtype -k Escape; sleep 0.3
wtype -k a; sleep 0.8; grim -o "$MONITOR" "$TMP/animations.png"
wtype -k Escape; sleep 0.3
wtype -k k; sleep 0.8; grim -o "$MONITOR" "$TMP/shortcuts.png"
wtype -k Escape; sleep 0.3
wtype -k b; sleep 0.8; grim -o "$MONITOR" "$TMP/bar.png"
# The bar view closes the palette on Escape, so reopen before the next view.
wtype -k Escape; sleep 0.4
omarchy-shell apach.dropdown openOn "$MONITOR" >/dev/null 2>&1
sleep 0.8
wtype -k p; sleep 0.8; grim -o "$MONITOR" "$TMP/preview.png"
wtype -k Escape; sleep 0.3
wtype "?"; sleep 0.8; grim -o "$MONITOR" "$TMP/help.png"
wtype -k Escape; sleep 0.3
wtype -k Escape; sleep 0.5

# Crop the central card. Keeps the screenshots comparable across monitor sizes.
size=$(magick identify -format '%wx%h' "$TMP/palette.png")
W=${size%x*}; H=${size#*x}
CW=$(( W > 1100 ? 1040 : W - 80 ))
CH=$(( H > 1200 ? 1000 : H - 120 ))
OX=$(( (W - CW) / 2 ))
OY=24

for name in palette drawer manage settings animations shortcuts bar preview help; do
  height=$CH
  [[ $name == manage ]] && height=700
  [[ $name == settings ]] && height=$(( H - OY - 20 ))
  [[ $name == preview ]] && height=820
  outname="$name-card"
  [[ $name == bar ]] && outname="bar-placement-card"
  magick "$TMP/$name.png" -crop "${CW}x${height}+${OX}+${OY}" +repage "$OUT/$outname.png"
done

magick montage \
  "$OUT/palette-card.png" "$OUT/drawer-card.png" \
  "$OUT/manage-card.png" "$OUT/settings-card.png" \
  "$OUT/animations-card.png" "$OUT/shortcuts-card.png" \
  "$OUT/bar-placement-card.png" "$OUT/preview-card.png" \
  "$OUT/help-card.png" \
  -thumbnail 460x560 -tile 3x3 -geometry +8+8 -depth 8 -strip "$OUT/cards-contact.png"

echo "Wrote screenshots to $OUT"
