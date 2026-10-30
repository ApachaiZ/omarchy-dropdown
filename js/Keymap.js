// Pure key routing for the palette and the all-apps drawer.
//
// Qt event objects never reach this module: the overlay converts an event to
// a key name with nameForCode(), then asks paletteIntent() what should happen.
// Keeping the decision table here makes every branch testable without a
// compositor, and keeps Overlay.qml focused on rendering.

var KEY_NAMES = {
  "16777216": "escape",
  "16777217": "tab",
  "16777218": "backtab",
  "16777219": "backspace",
  "16777220": "return",
  "16777221": "enter",
  "16777222": "insert",
  "16777223": "delete",
  "16777224": "pause",
  "16777225": "print",
  "16777232": "home",
  "16777233": "end",
  "16777234": "left",
  "16777235": "up",
  "16777236": "right",
  "16777237": "down",
  "16777238": "pageup",
  "16777239": "pagedown",
  "32": "space"
}

function nameForCode(code) {
  return KEY_NAMES[String(code)] || ""
}

// Number of card columns that fit in a drawer of the given width. Mirrors the
// Grid inside AllAppsDrawer.qml so keyboard movement always matches the
// rendered layout.
function columnsForWidth(width, cardWidth) {
  var w = Number(width) || 0
  var min = Number(cardWidth) || 168
  if (w < min * 2) return 1
  if (w < min * 3) return 2
  return 3
}

// Move a grid selection by one card. Returns -1 when the move leaves the grid
// upward, which the overlay turns into "collapse the drawer".
function moveInGrid(index, count, columns, dx, dy) {
  var total = Number(count) || 0
  if (total <= 0) return -1
  var cols = Math.max(1, Number(columns) || 1)
  var current = Number(index) || 0
  if (current < 0) current = 0
  if (current >= total) current = total - 1
  var row = Math.floor(current / cols)
  var col = current % cols
  var nextRow = row + (Number(dy) || 0)
  if (nextRow < 0) return -1
  var nextCol = col + (Number(dx) || 0)
  if (nextCol < 0) nextCol = 0
  if (nextCol > cols - 1) nextCol = cols - 1
  var target = nextRow * cols + nextCol
  if (target >= total) {
    // Moving down from the last row stays put; moving right on a short last
    // row clamps to its last card.
    if ((Number(dy) || 0) > 0) return current
    target = total - 1
  }
  return target
}

function commandForKey(commands, key) {
  var value = String(key || "")
  if (!value) return ""
  var source = commands || {}
  for (var name in source) if (String(source[name]) === value) return name
  return ""
}

// Decide what a palette key press means.
//
// input:
//   key        one of nameForCode(), or "" for a printable character
//   text       printable text, already filtered by the caller
//   commands   palette command map (name -> single character)
//   appKeys    map of palette key -> app id
//   drawerOpen drawer visibility
//   drawerIndex / drawerCount / columns   current grid state
//
// returns { action, ... }:
//   drawer-toggle | drawer-open | drawer-close | drawer-exit
//   drawer-move (index) | drawer-activate (index)
//   commit | back | command (name) | app (key) | text (key) | none
function paletteIntent(input) {
  var value = input || {}
  var key = String(value.key || "")
  var text = String(value.text || "")
  var open = value.drawerOpen === true
  var count = Number(value.drawerCount) || 0
  var index = Number(value.drawerIndex) || 0
  var columns = Math.max(1, Number(value.columns) || 1)

  if (key === "escape") return { action: open ? "drawer-close" : "back" }
  if (key === "space" && count > 0) return { action: "drawer-toggle" }
  if (key === "return" || key === "enter") {
    return open ? { action: "drawer-activate", index: index } : { action: "commit" }
  }
  if (key === "up") {
    if (!open) return { action: "none" }
    var up = moveInGrid(index, count, columns, 0, -1)
    return up < 0 ? { action: "drawer-exit" } : { action: "drawer-move", index: up }
  }
  if (key === "down") {
    if (!open) return count > 0 ? { action: "drawer-open", index: 0 } : { action: "none" }
    return { action: "drawer-move", index: moveInGrid(index, count, columns, 0, 1) }
  }
  if (key === "left") {
    return open ? { action: "drawer-move", index: moveInGrid(index, count, columns, -1, 0) } : { action: "none" }
  }
  if (key === "right") {
    return open ? { action: "drawer-move", index: moveInGrid(index, count, columns, 1, 0) } : { action: "none" }
  }
  if (key !== "") return { action: "none" }

  if (!text) return { action: "none" }
  var lower = text.toLowerCase()
  var command = commandForKey(value.commands, lower)
  if (command) return { action: "command", name: command, key: lower }
  var appKeys = value.appKeys || {}
  if (appKeys[lower]) return { action: "app", key: lower, appId: String(appKeys[lower]) }
  return { action: "text", key: lower, text: text }
}

if (typeof module !== "undefined") {
  module.exports = {
    KEY_NAMES: KEY_NAMES,
    nameForCode: nameForCode,
    columnsForWidth: columnsForWidth,
    moveInGrid: moveInGrid,
    commandForKey: commandForKey,
    paletteIntent: paletteIntent
  }
}
