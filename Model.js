// Pure helpers for Omarchy Dropdown. No QML or shell access, so every function
// here is covered by tests/model.test.mjs.

var SCHEMA_VERSION = 1

// Keys proposed for the three optional system applications. They are only
// reserved while the application itself is enabled.
var SYSTEM_KEYS = { terminal: "t", agent: "i", files: "f" }

var DEFAULT_COMMANDS = {
  help: "?",
  manage: "m",
  preview: "p",
  settings: "s",
  motion: "a",
  shortcuts: "k",
  bar: "b",
  hide: "h",
  quit: "q",
  popout: "'",
  nextWindow: "w"
}

var DEFAULT_CONFIG = {
  schemaVersion: SCHEMA_VERSION,
  settings: {
    autoHideDelayMs: 5000,
    screen: "auto",
    geometry: {
      preset: "medium",
      placement: "top",
      edge: "top",
      widthPercent: 60,
      heightPercent: 80,
      topOffset: 12,
      sideMargin: 0
    },
    animations: {
      mode: "slide+fade",
      durationMs: 180,
      easing: "outCubic",
      reducedMotion: false
    },
    autoHideOnFocusLoss: true,
    topApps: 5,
    tabs: {
      position: "top"
    },
    commands: DEFAULT_COMMANDS
  },
  apps: {
    "system.terminal": { enabled: false, key: "t" },
    "system.agent": { enabled: false, key: "i" },
    "system.files": { enabled: false, key: "f" }
  }
}

var GEOMETRY_PRESETS = {
  compact: { widthPercent: 45, heightPercent: 65 },
  medium: { widthPercent: 60, heightPercent: 80 },
  large: { widthPercent: 75, heightPercent: 90 }
}

var ANIMATION_MODES = [
  "none", "slide", "fade", "slide+fade",
  "scale", "scale+fade", "zoom", "zoom+fade",
  "bounce", "bounce+fade", "slideH", "slideH+fade"
]
var TABS_POSITIONS = ["top", "bottom"]
var EDGES = ["top", "bottom", "left", "right"]
var PLACEMENTS = ["center", "top", "bottom", "left", "right"]
var EASINGS = ["outCubic", "outQuart", "outBack", "linear"]
var MIN_WIDTH = 320
var MIN_HEIGHT = 240

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function clamp(value, min, max) {
  var n = Number(value)
  if (!isFinite(n)) return min
  return Math.max(min, Math.min(max, n))
}

function stripDesktop(id) {
  var value = String(id || "").trim()
  if (value.slice(-8) === ".desktop") value = value.slice(0, -8)
  return value
}

function desktopId(id) {
  var value = stripDesktop(id)
  return value ? value + ".desktop" : ""
}

// Split a Desktop Entry Exec line into an argv vector. Handles double quotes
// and backslash escapes, then removes field codes. Used for entries whose
// parsed `command` is unavailable; the shell's DesktopEntry.command is
// preferred wherever it exists.
function parseExec(command) {
  var out = []
  var token = null
  var quote = false
  var escape = false
  var text = String(command || "")
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i)
    if (escape) {
      token = (token === null ? "" : token) + ch
      escape = false
      continue
    }
    if (quote) {
      if (ch === "\\") { escape = true; continue }
      if (ch === '"') { quote = false; continue }
      token = (token === null ? "" : token) + ch
      continue
    }
    if (ch === '"') {
      quote = true
      if (token === null) token = ""
      continue
    }
    if (ch === " " || ch === "\t" || ch === "\n") {
      if (token !== null) { out.push(token); token = null }
      continue
    }
    if (ch === "\\") {
      escape = true
      if (token === null) token = ""
      continue
    }
    token = (token === null ? "" : token) + ch
  }
  if (token !== null) out.push(token)
  var cleaned = []
  for (var j = 0; j < out.length; j++) {
    var value = out[j]
    if (/^%[a-zA-Z]$/.test(value)) continue
    value = value.replace(/%%/g, "\u0000").replace(/%[a-zA-Z]/g, "").replace(/\u0000/g, "%")
    if (value.length > 0) cleaned.push(value)
  }
  return cleaned
}

// Returns the http(s) URL of an Omarchy web app, or "" for other entries.
// Omarchy installs web apps as `Exec=omarchy-launch-webapp <url>`; a desktop
// application that merely looks like a browser must not be treated as one.
function webappUrl(entry) {
  if (!entry) return ""
  var argv = []
  if (entry.command && entry.command.length) argv = entry.command.slice()
  else argv = parseExec(entry.execString)
  var index = -1
  for (var i = 0; i < argv.length; i++) {
    var token = String(argv[i] || "")
    if (/(^|\/)omarchy-launch-webapp$/.test(token)) { index = i; break }
  }
  if (index < 0) return ""
  for (var j = index + 1; j < argv.length; j++) {
    var candidate = String(argv[j] || "")
    if (!candidate || candidate.charAt(0) === "-") continue
    if (/^https?:\/\//i.test(candidate)) return candidate
    return ""
  }
  return ""
}

function isWebappEntry(entry) {
  return webappUrl(entry) !== ""
}

// Chromium-family PWAs installed by the browser itself do not use
// omarchy-launch-webapp. They expose either a `chrome-...-Default`
// StartupWMClass or an `--app=` / `--app-id=` flag.
function isBrowserWebapp(entry) {
  if (!entry || isWebappEntry(entry)) return false
  var cls = String(entry.startupClass || "").toLowerCase()
  if (/^(chrome|chromium|brave|vivaldi|microsoft-edge|opera|helium)-/.test(cls)
      && (cls.indexOf("__") >= 0 || /-default$/.test(cls))) return true
  var argv = entry.command && entry.command.length ? entry.command.slice() : parseExec(entry.execString)
  for (var i = 0; i < argv.length; i++) {
    var token = String(argv[i] || "")
    if (/^--app(-id)?=/.test(token)) return true
  }
  return false
}

function browserWebappUrl(entry) {
  if (!entry) return ""
  var argv = entry.command && entry.command.length ? entry.command.slice() : parseExec(entry.execString)
  for (var i = 0; i < argv.length; i++) {
    var token = String(argv[i] || "")
    if (token.indexOf("--app=") === 0) {
      var value = token.slice(6)
      if (/^https?:\/\//i.test(value)) return value
    }
  }
  return ""
}

function urlParts(url) {
  var text = String(url || "")
  var match = /^([a-z][a-z0-9+.-]*):\/\/([^\/?#]*)([^?#]*)/i.exec(text)
  if (!match) return null
  var authority = match[2]
  var host = authority
  if (host.indexOf("@") >= 0) host = host.slice(host.lastIndexOf("@") + 1)
  if (host.charAt(0) === "[") {
    var end = host.indexOf("]")
    host = end >= 0 ? host.slice(0, end + 1) : host
  } else {
    var colon = host.indexOf(":")
    if (colon >= 0) host = host.slice(0, colon)
  }
  host = host.toLowerCase()
  var path = String(match[3] || "")
  if (path.charAt(0) === "/") path = path.slice(1)
  return { scheme: match[1].toLowerCase(), host: host, path: path }
}

// Chromium's app window class: chrome-<host>__<path with "/" as "_">-Default.
// The port is not part of the class. Confirmed on Omarchy 4 / Hyprland 0.56:
//   https://youtube.com/          -> chrome-youtube.com__-Default
//   https://discord.com/channels/@me -> chrome-discord.com__channels_@me-Default
function webappClass(url, prefix) {
  var parts = urlParts(url)
  if (!parts) return ""
  return String(prefix || "chrome") + "-" + parts.host + "__" +
    parts.path.replace(/\//g, "_") + "-Default"
}

var BROWSER_PREFIXES = ["chrome", "chromium", "brave", "vivaldi", "microsoft-edge", "opera", "helium"]

function webappClassMatches(cls, url) {
  var value = String(cls || "").toLowerCase()
  if (!value) return false
  for (var i = 0; i < BROWSER_PREFIXES.length; i++) {
    if (value === webappClass(url, BROWSER_PREFIXES[i]).toLowerCase()) return true
  }
  // Paths can be normalized by the browser (trailing slash, app-specific
  // redirect). A unique host prefix is still considerably more precise than
  // matching the browser's generic class.
  var parts = urlParts(url)
  if (!parts || !parts.host) return false
  for (var j = 0; j < BROWSER_PREFIXES.length; j++) {
    if (value.indexOf(BROWSER_PREFIXES[j] + "-" + parts.host + "__") === 0) return true
  }
  return false
}

// Short stable hash for special-workspace names. djb2 is enough: collisions
// only need to be rare, and the full app id is kept in the state file.
function hash(text) {
  var value = 5381
  var source = String(text || "")
  for (var i = 0; i < source.length; i++) {
    value = ((value << 5) + value + source.charCodeAt(i)) >>> 0
  }
  return value.toString(36)
}

function specialWorkspace(appId) {
  var slug = String(appId || "").toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 40)
  if (!slug) slug = "app"
  return "special:dropdown-" + slug + "-" + hash(appId)
}

function specialPrefix() {
  return "special:dropdown-"
}

function isManagedSpecial(name) {
  var value = String(name || "")
  // Current Hyprland builds cannot create a new named special workspace at
  // runtime, so Dropdown falls back to the unnamed special workspace.
  if (value === "special" || value === "special:special") return true
  return value.indexOf(specialPrefix()) === 0
}

// Hyprland's event socket reports addresses without the "0x" prefix while
// hyprctl clients reports them with it. Compare and dispatch in one form.
function normalizeAddress(address) {
  var value = String(address || "").trim().toLowerCase()
  if (/^[0-9a-f]+$/.test(value)) value = "0x" + value
  return /^0x[0-9a-f]+$/.test(value) ? value : ""
}

function validAddress(address) {
  return normalizeAddress(address) !== ""
}

function parseClients(raw) {
  var out = []
  try {
    var list = JSON.parse(String(raw || ""))
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length; i++) {
      var c = list[i]
      if (!c) continue
      var workspace = c.workspace && c.workspace.name ? String(c.workspace.name) : ""
      out.push({
        address: String(c.address || ""),
        class: String(c.class || ""),
        initialClass: String(c.initialClass || ""),
        title: String(c.title || ""),
        pid: Number(c.pid || 0),
        workspace: workspace,
        monitor: Number(c.monitor || 0),
        floating: c.floating === true,
        fullscreen: Number(c.fullscreen || 0),
        at: Array.isArray(c.at) ? c.at : [0, 0],
        size: Array.isArray(c.size) ? c.size : [0, 0],
        mapped: c.mapped !== false
      })
    }
  } catch (e) {
    return []
  }
  return out
}

function parseMonitors(raw) {
  var out = []
  try {
    var list = JSON.parse(String(raw || ""))
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      if (!m || m.disabled === true) continue
      var reserved = Array.isArray(m.reserved) && m.reserved.length === 4
        ? m.reserved.map(function(v) { return Math.max(0, Number(v) || 0) })
        : [0, 0, 0, 0]
      var special = m.specialWorkspace && m.specialWorkspace.name
        ? String(m.specialWorkspace.name) : ""
      out.push({
        id: Number(m.id || 0),
        name: String(m.name || ""),
        x: Number(m.x || 0),
        y: Number(m.y || 0),
        width: Number(m.width || 0),
        height: Number(m.height || 0),
        scale: Number(m.scale || 1),
        transform: Number(m.transform || 0),
        reserved: reserved,
        focused: m.focused === true,
        activeWorkspace: m.activeWorkspace && m.activeWorkspace.name
          ? String(m.activeWorkspace.name) : "",
        specialWorkspace: special
      })
    }
  } catch (e) {
    return []
  }
  return out
}

// Logical layout box for a monitor. Hyprland reports the untransformed mode
// in width/height; a 90°/270° transform swaps the layout extents.
function monitorBox(monitor) {
  if (!monitor) return null
  var swap = Number(monitor.transform || 0) % 2 === 1
  var scale = Number(monitor.scale || 1)
  if (!isFinite(scale) || scale <= 0) scale = 1
  // Hyprland reports the physical mode in width/height (and x/y are already
  // layout/logical coordinates). Divide by scale before using the box for
  // window geometry; otherwise 60 % of a 3440 px output is 3440 px wide and
  // the window is not actually centred after the compositor applies scale.
  var logicalWidth = monitor.width / scale
  var logicalHeight = monitor.height / scale
  return {
    x: monitor.x,
    y: monitor.y,
    width: swap ? logicalHeight : logicalWidth,
    height: swap ? logicalWidth : logicalHeight,
    reserved: monitor.reserved || [0, 0, 0, 0]
  }
}

function geometryFor(monitor, globalGeometry, override) {
  var box = monitorBox(monitor)
  if (!box) return { x: 0, y: 0, width: MIN_WIDTH, height: MIN_HEIGHT, edge: "top" }
  var base = globalGeometry || {}
  var own = override || {}
  var edge = EDGES.indexOf(String(base.edge || "top")) >= 0 ? String(base.edge || "top") : "top"
  var placement = PLACEMENTS.indexOf(String(base.placement || "top")) >= 0
    ? String(base.placement || "top") : "top"
  var widthPercent = clamp(own.widthPercent !== undefined ? own.widthPercent : base.widthPercent, 20, 100)
  var heightPercent = clamp(own.heightPercent !== undefined ? own.heightPercent : base.heightPercent, 20, 100)
  var topOffset = clamp(base.topOffset, 0, 400)
  var sideMargin = clamp(base.sideMargin, 0, 400)
  var reserved = box.reserved
  var left = reserved[0] || 0
  var top = reserved[1] || 0
  var right = reserved[2] || 0
  var bottom = reserved[3] || 0
  var bottomGap = 12
  var availableWidth = Math.max(MIN_WIDTH, box.width - left - right - sideMargin * 2)
  var availableHeight = Math.max(MIN_HEIGHT, box.height - top - bottom - topOffset - bottomGap)
  var width = Math.round(availableWidth * widthPercent / 100)
  var height = Math.round(availableHeight * heightPercent / 100)
  width = clamp(width, MIN_WIDTH, availableWidth)
  height = clamp(height, MIN_HEIGHT, availableHeight)
  var centeredX = box.x + left + sideMargin + Math.round((availableWidth - width) / 2)
  var centeredY = box.y + top + Math.round((availableHeight - height) / 2)
  var x = centeredX
  var y = centeredY
  if (placement === "top") {
    y = box.y + top + topOffset
  } else if (placement === "bottom") {
    y = box.y + box.height - bottom - topOffset - height
  } else if (placement === "left") {
    x = box.x + left + sideMargin
  } else if (placement === "right") {
    x = box.x + box.width - right - sideMargin - width
  }
  // center: both axes in the usable area. top/bottom centre horizontally;
  // left/right centre vertically.
  return { x: x, y: y, width: width, height: height, edge: edge, placement: placement }
}

// Off-screen start position for the slide-in. The window is moved just past
// the requested edge, then tweened to `final`.
function slideStart(monitor, final, edge, margin) {
  var box = monitorBox(monitor)
  var gap = clamp(margin === undefined ? 24 : margin, 0, 200)
  if (!box || !final) return { x: final ? final.x : 0, y: final ? final.y : 0 }
  var direction = EDGES.indexOf(String(edge || "top")) >= 0 ? String(edge || "top") : "top"
  var start = { x: final.x, y: final.y }
  // Start at the screen edge itself (not outside it): the user sees the
  // dropdown leave the top/left/right/bottom border and settle in its target
  // position. `margin` is kept for callers that want a small inset.
  if (direction === "top") start.y = box.y - final.height - gap
  else if (direction === "bottom") start.y = box.y + box.height + gap
  else if (direction === "left") start.x = box.x - final.width - gap
  else if (direction === "right") start.x = box.x + box.width + gap
  return start
}

function monitorForName(monitors, name) {
  var target = String(name || "")
  for (var i = 0; i < monitors.length; i++) {
    if (monitors[i].name === target) return monitors[i]
  }
  for (var j = 0; j < monitors.length; j++) {
    if (monitors[j].focused) return monitors[j]
  }
  return monitors.length > 0 ? monitors[0] : null
}

// Does this Hyprland client belong to the managed application? `app` carries
// the expected class/url/desktop id; `pid` is set for plugin-launched terminal
// instances.
function windowMatches(app, win) {
  if (!app || !win) return false
  var cls = String(win.class || "").toLowerCase()
  var icls = String(win.initialClass || "").toLowerCase()
  var title = String(win.title || "").toLowerCase()
  var name = String(app.name || "").toLowerCase()
  if (app.kind === "webapp") {
    if (app.url && (webappClassMatches(win.class, app.url) || webappClassMatches(win.initialClass, app.url))) return true
    var expected = String(app.expectedClass || "").toLowerCase()
    if (expected && (cls === expected || icls === expected)) return true
    return name.length >= 3 && title.indexOf(name) >= 0
  }
  if (app.kind === "system" && (app.system === "terminal" || app.system === "agent")) {
    var expected = String(app.expectedClass || "").toLowerCase()
    if (expected && (cls === expected || icls === expected)) return true
    if (app.pid && Number(win.pid) === Number(app.pid)) return true
    return false
  }
  // File manager and any other desktop entry: StartupWMClass, then the
  // desktop id, then the display name. Ordinary windows are still excluded by
  // the address snapshot taken before launch.
  var startup = String(app.startupClass || "").toLowerCase()
  if (startup && (cls === startup || icls === startup)) return true
  var id = String(app.desktopId || app.id || "").toLowerCase()
  var bare = stripDesktop(id)
  if (bare && (cls === bare || icls === bare)) return true
  if (name.length >= 3 && (cls.indexOf(name.replace(/\s+/g, "")) >= 0 || title.indexOf(name) >= 0)) return true
  return false
}

var SHORTCUT_MODIFIERS = ["SUPER", "CTRL", "ALT", "SHIFT"]

// Named keys accepted after the modifiers. Hyprland stores named keys in
// lowercase in `hyprctl binds -j`, so luaShortcutKey() lowercases them while
// letters, digits and function keys keep their canonical form.
var NAMED_KEYS = [
  "LEFT", "RIGHT", "UP", "DOWN", "TAB", "SPACE", "RETURN", "BACKSPACE",
  "DELETE", "HOME", "END", "PAGEUP", "PAGEDOWN", "INSERT",
  "COMMA", "PERIOD", "SLASH", "SEMICOLON", "APOSTROPHE", "MINUS", "EQUAL",
  "GRAVE", "BACKSLASH", "BRACKETLEFT", "BRACKETRIGHT"
]

var SHORTCUT_KEY_ALIASES = {
  "ESC": "ESCAPE", "ESCAPE": "ESCAPE",
  "PAGE_UP": "PAGEUP", "PAGE_UP_": "PAGEUP", "PRIOR": "PAGEUP",
  "PAGE_DOWN": "PAGEDOWN", "NEXT": "PAGEDOWN",
  "DEL": "DELETE", "INS": "INSERT", "RET": "RETURN", "ENTER": "RETURN",
  "PGUP": "PAGEUP", "PGDN": "PAGEDOWN",
  "ARROWLEFT": "LEFT", "ARROWRIGHT": "RIGHT", "ARROWUP": "UP", "ARROWDOWN": "DOWN",
  "SPACEBAR": "SPACE", "COMMA": "COMMA"
}

// Normalize a Hyprland chord used for a direct app shortcut. Letters, digits,
// F1-F24, arrows, Tab, Space, Return, navigation and common punctuation are
// accepted, with at least Super/Alt/Ctrl. Returning "" means the value is
// invalid (or empty, which clears the shortcut).
function normalizeShortcut(value) {
  var parts = String(value || "").toUpperCase().split("+")
  var modifiers = {}
  var key = ""
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim()
    if (!part) continue
    if (part === "CONTROL") part = "CTRL"
    if (part === "META" || part === "WIN" || part === "LOGO") part = "SUPER"
    if (SHORTCUT_MODIFIERS.indexOf(part) >= 0) {
      modifiers[part] = true
      continue
    }
    if (key) return ""
    key = SHORTCUT_KEY_ALIASES[part] || part
  }
  if (!key) return ""
  var named = NAMED_KEYS.indexOf(key) >= 0 || key === "ESCAPE"
  var letterOrDigit = /^(?:[A-Z]|[0-9])$/.test(key)
  var functionKey = /^F(?:[1-9]|1[0-9]|2[0-4])$/.test(key)
  if (!named && !letterOrDigit && !functionKey) return ""
  // Escape is reserved by the dropdown submap and must not be shadowed.
  if (key === "ESCAPE") return ""
  var ordered = []
  for (var m = 0; m < SHORTCUT_MODIFIERS.length; m++)
    if (modifiers[SHORTCUT_MODIFIERS[m]]) ordered.push(SHORTCUT_MODIFIERS[m])
  if (ordered.length === 0) return ""
  if (ordered.length === 1 && ordered[0] === "SHIFT") return ""
  ordered.push(key)
  return ordered.join(" + ")
}

// Hyprland reports xkb keysym names. Most match our canonical name, but the
// page keys are "Prior"/"Next" in the bind list (PAGEUP/PAGEDOWN are invalid).
function hyprBindKey(value) {
  var key = shortcutKey(value)
  if (!key) return ""
  if (key === "PAGEUP") return "Prior"
  if (key === "PAGEDOWN") return "Next"
  return key
}

// The generated bind file uses the same spelling Hyprland reports.
function luaShortcutKey(value) {
  return hyprBindKey(value)
}

// Propose a free direct chord for an app. Used by the shortcut capture as a
// one-key default (Enter applies it); the async Hyprland check still has the
// final say for binds owned outside Dropdown.
function suggestShortcut(name, usedShortcuts) {
  var used = {}
  for (var i = 0; i < (usedShortcuts || []).length; i++) {
    var normalized = normalizeShortcut(usedShortcuts[i])
    if (normalized) used[normalized] = true
  }
  var initials = String(name || "").toLowerCase().replace(/[^a-z]/g, "")
  var alphabet = "abcdefghijklmnopqrstuvwxyz"
  var order = initials + alphabet
  for (var j = 0; j < order.length; j++) {
    var chord = "SUPER + SHIFT + " + order.charAt(j).toUpperCase()
    if (!used[chord]) return chord
  }
  for (var d = 1; d <= 9; d++) {
    chord = "SUPER + ALT + " + d
    if (!used[chord]) return chord
  }
  for (var f = 1; f <= 12; f++) {
    chord = "SUPER + ALT + F" + f
    if (!used[chord]) return chord
  }
  return ""
}

// URLs are the only user-provided value that reaches a launcher. Restrict them
// to a plain http(s) URL with no control characters or quote smuggling.
function isSafeUrl(value) {
  var url = String(value || "").trim()
  if (url.length < 8 || url.length > 2048) return false
  if (!/^https?:\/\//i.test(url)) return false
  if (/[\u0000-\u001f\u007f"'\\]/.test(url)) return false
  if (/\s/.test(url)) return false
  return true
}

function shortcutParts(value) {
  var chord = normalizeShortcut(value)
  return chord ? chord.split(" + ") : []
}

function shortcutModmask(value) {
  var parts = shortcutParts(value)
  var mask = 0
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] === "SUPER") mask += 64
    else if (parts[i] === "CTRL") mask += 4
    else if (parts[i] === "ALT") mask += 8
    else if (parts[i] === "SHIFT") mask += 1
  }
  return mask
}

function shortcutKey(value) {
  var parts = shortcutParts(value)
  return parts.length > 0 ? parts[parts.length - 1] : ""
}

function commandValues(commands) {
  var out = []
  var source = commands || DEFAULT_COMMANDS
  for (var name in source) {
    var key = String(source[name] || "")
    if (key.length === 1) out.push(key)
  }
  return out
}

function reservedKeys(enabledSystem, commands) {
  var out = commandValues(commands)
  var enabled = enabledSystem || {}
  for (var key in SYSTEM_KEYS) {
    if (enabled[key] === true) out.push(SYSTEM_KEYS[key])
  }
  return out
}

function firstFreeKey(name, usedKeys, reserved) {
  var used = {}
  for (var i = 0; i < (usedKeys || []).length; i++) used[String(usedKeys[i])] = true
  for (var r = 0; r < (reserved || []).length; r++) used[String(reserved[r])] = true
  var letters = "abcdefghijklmnopqrstuvwxyz"
  var label = String(name || "").toLowerCase()
  for (var j = 0; j < label.length; j++) {
    var ch = label.charAt(j)
    if (/[a-z]/.test(ch) && !used[ch]) return ch
  }
  for (var k = 0; k < letters.length; k++) {
    if (!used[letters.charAt(k)]) return letters.charAt(k)
  }
  for (var d = 3; d <= 9; d++) {
    if (!used[String(d)]) return String(d)
  }
  return ""
}

// key -> [appId, ...]. Used by the UI to explain conflicts instead of letting
// one application win silently.
function keyConflicts(apps) {
  var counts = {}
  for (var i = 0; i < (apps || []).length; i++) {
    var app = apps[i]
    if (!app || app.enabled !== true) continue
    var key = String(app.key || "")
    if (!key) continue
    if (!counts[key]) counts[key] = []
    counts[key].push(String(app.id || app.name || ""))
  }
  var out = {}
  for (var k in counts) if (counts[k].length > 1) out[k] = counts[k]
  return out
}

function validateKey(key, appId, apps, enabledSystem, commands) {
  var value = String(key || "")
  if (value.length !== 1) return { ok: false, error: "Use a single character." }
  var reserved = reservedKeys(enabledSystem, commands)
  if (reserved.indexOf(value) >= 0) {
    return { ok: false, error: "\"" + value + "\" is a palette command. Pick another key." }
  }
  for (var i = 0; i < (apps || []).length; i++) {
    var app = apps[i]
    if (!app || app.enabled !== true || String(app.id) === String(appId)) continue
    if (String(app.key || "") === value) {
      return { ok: false, error: "\"" + value + "\" is already used by " + (app.name || app.id) + "." }
    }
  }
  return { ok: true, error: "" }
}

function enabledSystemMap(config) {
  var apps = config && config.apps ? config.apps : {}
  return {
    terminal: !!(apps["system.terminal"] && apps["system.terminal"].enabled),
    agent: !!(apps["system.agent"] && apps["system.agent"].enabled),
    files: !!(apps["system.files"] && apps["system.files"].enabled)
  }
}

// Merge a file on disk with the defaults, dropping anything invalid rather
// than making the whole configuration unusable.
function validateConfig(raw) {
  var warnings = []
  var config = clone(DEFAULT_CONFIG)
  var parsed = null
  if (typeof raw === "string") {
    try { parsed = JSON.parse(raw) } catch (e) { warnings.push("Invalid JSON; defaults restored.") }
  } else if (isPlainObject(raw)) {
    parsed = raw
  }
  if (!isPlainObject(parsed)) return { config: config, warnings: warnings }

  if (parsed.schemaVersion !== undefined && Number(parsed.schemaVersion) !== SCHEMA_VERSION) {
    warnings.push("Unsupported schema version " + parsed.schemaVersion + "; kept known values.")
  }
  var settings = isPlainObject(parsed.settings) ? parsed.settings : {}
  var geometry = isPlainObject(settings.geometry) ? settings.geometry : {}
  var animations = isPlainObject(settings.animations) ? settings.animations : {}

  if (typeof settings.screen === "string" && settings.screen.length > 0 && settings.screen.length < 128)
    config.settings.screen = settings.screen

  var hideDelay = Number(settings.autoHideDelayMs)
  if (isFinite(hideDelay)) config.settings.autoHideDelayMs = clamp(hideDelay, 0, 30000)

  if (typeof geometry.preset === "string" && (geometry.preset === "custom" || GEOMETRY_PRESETS[geometry.preset])) {
    config.settings.geometry.preset = geometry.preset
  }
  if (typeof geometry.edge === "string" && EDGES.indexOf(geometry.edge) >= 0) {
    config.settings.geometry.edge = geometry.edge
  }
  if (typeof geometry.placement === "string" && PLACEMENTS.indexOf(geometry.placement) >= 0) {
    config.settings.geometry.placement = geometry.placement
  }
  if (geometry.widthPercent !== undefined) config.settings.geometry.widthPercent = clamp(geometry.widthPercent, 20, 100)
  if (geometry.heightPercent !== undefined) config.settings.geometry.heightPercent = clamp(geometry.heightPercent, 20, 100)
  if (geometry.topOffset !== undefined) config.settings.geometry.topOffset = clamp(geometry.topOffset, 0, 400)
  if (geometry.sideMargin !== undefined) config.settings.geometry.sideMargin = clamp(geometry.sideMargin, 0, 400)

  if (typeof animations.mode === "string") {
    var mode = animations.mode
    if (mode === "slideFade" || mode === "fadeSlide") mode = "slide+fade"
    if (ANIMATION_MODES.indexOf(mode) >= 0) config.settings.animations.mode = mode
  }
  if (animations.durationMs !== undefined) config.settings.animations.durationMs = clamp(animations.durationMs, 0, 800)
  if (typeof animations.easing === "string" && EASINGS.indexOf(animations.easing) >= 0)
    config.settings.animations.easing = animations.easing
  if (typeof animations.reducedMotion === "boolean") config.settings.animations.reducedMotion = animations.reducedMotion
  if (typeof settings.autoHideOnFocusLoss === "boolean") config.settings.autoHideOnFocusLoss = settings.autoHideOnFocusLoss
  if (settings.topApps !== undefined)
    config.settings.topApps = Math.round(clamp(settings.topApps, 3, 7))

  var tabs = isPlainObject(settings.tabs) ? settings.tabs : {}
  if (typeof tabs.position === "string" && TABS_POSITIONS.indexOf(tabs.position) >= 0)
    config.settings.tabs.position = tabs.position

  if (isPlainObject(settings.commands)) {
    var commands = {}
    for (var name in DEFAULT_COMMANDS) {
      var candidate = settings.commands[name]
      if (typeof candidate === "string" && candidate.length === 1) commands[name] = candidate
      else commands[name] = DEFAULT_COMMANDS[name]
    }
    // Resolve duplicates deterministically: the first command keeps the key,
    // later ones fall back to their default only if that default is free.
    var used = {}
    for (var cname in DEFAULT_COMMANDS) {
      var key = commands[cname]
      if (!used[key]) { used[key] = true; continue }
      if (!used[DEFAULT_COMMANDS[cname]]) { commands[cname] = DEFAULT_COMMANDS[cname]; used[DEFAULT_COMMANDS[cname]] = true }
      else commands[cname] = ""
    }
    config.settings.commands = commands
  }

  if (isPlainObject(parsed.apps)) {
    for (var id in parsed.apps) {
      var entry = parsed.apps[id]
      if (!isPlainObject(entry)) continue
      if (!config.apps[id]) config.apps[id] = {}
      var target = config.apps[id]
      if (typeof entry.enabled === "boolean") target.enabled = entry.enabled
      if (typeof entry.key === "string" && entry.key.length <= 1) target.key = entry.key
      if (typeof entry.launchAtLogin === "boolean") target.launchAtLogin = entry.launchAtLogin
      if (typeof entry.shortcut === "string") {
        var shortcut = normalizeShortcut(entry.shortcut)
        if (shortcut) target.shortcut = shortcut
      }
      if (entry.uses !== undefined) target.uses = Math.max(0, Math.floor(Number(entry.uses) || 0))
      if (entry.lastUsed !== undefined) target.lastUsed = Math.max(0, Number(entry.lastUsed) || 0)
      if (typeof entry.url === "string") {
        if (isSafeUrl(entry.url)) target.url = entry.url
        else warnings.push("Ignored unsafe URL for " + id + ".")
      }
      if (isPlainObject(entry.geometry)) {
        var own = {}
        if (entry.geometry.widthPercent !== undefined) own.widthPercent = clamp(entry.geometry.widthPercent, 20, 100)
        if (entry.geometry.heightPercent !== undefined) own.heightPercent = clamp(entry.geometry.heightPercent, 20, 100)
        if (own.widthPercent !== undefined || own.heightPercent !== undefined) target.geometry = own
      }
    }
  }

  var usedShortcuts = {}
  for (var appId in config.apps) {
    var appConfig = config.apps[appId]
    if (!appConfig || appConfig.enabled !== true || !appConfig.shortcut) continue
    if (usedShortcuts[appConfig.shortcut]) delete appConfig.shortcut
    else usedShortcuts[appConfig.shortcut] = appId
  }
  return { config: config, warnings: warnings }
}

function setPath(object, path, value) {
  var parts = String(path || "").split(".")
  var node = object
  for (var i = 0; i < parts.length - 1; i++) {
    if (!isPlainObject(node[parts[i]])) node[parts[i]] = {}
    node = node[parts[i]]
  }
  node[parts[parts.length - 1]] = value
}

function getPath(object, path, fallback) {
  var parts = String(path || "").split(".")
  var node = object
  for (var i = 0; i < parts.length; i++) {
    if (!isPlainObject(node) || node[parts[i]] === undefined) return fallback
    node = node[parts[i]]
  }
  return node
}

function stateLabel(state) {
  var labels = {
    stopped: "Stopped",
    launching: "Launching",
    visible: "Visible",
    hidden: "Hidden",
    closing: "Closing",
    error: "Error"
  }
  return labels[String(state || "")] || "Stopped"
}

function applyPreset(geometry, preset) {
  var values = GEOMETRY_PRESETS[preset]
  if (!values) return geometry
  return {
    preset: preset,
    placement: geometry.placement || "top",
    edge: geometry.edge || "top",
    widthPercent: values.widthPercent,
    heightPercent: values.heightPercent,
    topOffset: geometry.topOffset,
    sideMargin: geometry.sideMargin
  }
}

// Local-time HH:MM:SS for logs and the state file. Kept out of the UI.
// Parse this widget's place in ~/.config/omarchy/shell.json. Returns the
// current section, its 0-based index and every section's size.
function parseBarPlacement(raw, widgetId) {
  var sections = ["left", "center", "right"]
  var sizes = { left: 0, center: 0, right: 0 }
  var section = ""
  var index = -1
  try {
    var config = JSON.parse(String(raw || "{}"))
    var layout = (config && config.bar && config.bar.layout) || {}
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      if (!Array.isArray(list)) list = []
      sizes[sections[s]] = list.length
      for (var i = 0; i < list.length; i++) {
        var entry = list[i]
        var id = entry && typeof entry === "object" ? String(entry.id || "") : String(entry || "")
        if (id === String(widgetId || "")) {
          section = sections[s]
          index = i
        }
      }
    }
  } catch (e) {
    return { section: "", index: -1, sizes: sizes }
  }
  return { section: section, index: index, sizes: sizes }
}

// Easing for the compositor-side slide tween. Kept here so the shape is
// testable without a running compositor.


// Score how well `query` matches `text` for the Manage search. -1 = no match.
// Substring matches rank first, then subsequences with bonuses for word
// starts and streaks.
function fuzzyScore(query, text) {
  var q = String(query || "").toLowerCase()
  var value = String(text || "").toLowerCase()
  if (!q) return 1000
  if (value.indexOf(q) >= 0) return 500 + Math.max(0, 20 - value.length)
  var score = 0
  var qi = 0
  var streak = 0
  for (var i = 0; i < value.length && qi < q.length; i++) {
    if (value.charAt(i) === q.charAt(qi)) {
      qi++
      streak++
      score += 10 + streak
      var prev = i > 0 ? value.charAt(i - 1) : ""
      if (prev === " " || prev === "-" || prev === "." || prev === "(") score += 8
    } else {
      streak = 0
    }
  }
  return qi === q.length ? score : -1
}

// Which generated shortcuts are missing from a parsed `hyprctl binds -j`
// output. Used to re-apply binds after a config reload race.
function missingBinds(binds, entries) {
  var missing = []
  for (var i = 0; i < (entries || []).length; i++) {
    var entry = entries[i]
    if (!entry || !entry.shortcut) continue
    var mask = shortcutModmask(entry.shortcut)
    var key = hyprBindKey(entry.shortcut)
    var found = false
    for (var j = 0; j < (binds || []).length; j++) {
      var bind = binds[j] || {}
      if (Number(bind.modmask || 0) !== mask) continue
      if (String(bind.key || "").toUpperCase() !== key.toUpperCase()) continue
      if (String(bind.description || "").indexOf("Dropdown: ") !== 0) continue
      found = true
      break
    }
    if (!found) missing.push(entry.shortcut)
  }
  return missing
}

if (typeof module !== "undefined") {
  module.exports = {
    SCHEMA_VERSION: SCHEMA_VERSION,
    SYSTEM_KEYS: SYSTEM_KEYS,
    DEFAULT_COMMANDS: DEFAULT_COMMANDS,
    SHORTCUT_MODIFIERS: SHORTCUT_MODIFIERS,
    normalizeShortcut: normalizeShortcut,
    luaShortcutKey: luaShortcutKey,
    hyprBindKey: hyprBindKey,
    suggestShortcut: suggestShortcut,
    isSafeUrl: isSafeUrl,
    NAMED_KEYS: NAMED_KEYS,
    shortcutModmask: shortcutModmask,
    shortcutKey: shortcutKey,
    commandValues: commandValues,
    DEFAULT_CONFIG: DEFAULT_CONFIG,
    GEOMETRY_PRESETS: GEOMETRY_PRESETS,
    ANIMATION_MODES: ANIMATION_MODES,
    TABS_POSITIONS: TABS_POSITIONS,
    EDGES: EDGES,
    PLACEMENTS: PLACEMENTS,
    EASINGS: EASINGS,
    parseExec: parseExec,
    webappUrl: webappUrl,
    isWebappEntry: isWebappEntry,
    isBrowserWebapp: isBrowserWebapp,
    browserWebappUrl: browserWebappUrl,
    urlParts: urlParts,
    webappClass: webappClass,
    webappClassMatches: webappClassMatches,
    hash: hash,
    specialWorkspace: specialWorkspace,
    isManagedSpecial: isManagedSpecial,
    validAddress: validAddress,
    normalizeAddress: normalizeAddress,
    parseClients: parseClients,
    parseMonitors: parseMonitors,
    monitorBox: monitorBox,
    geometryFor: geometryFor,
    slideStart: slideStart,
    monitorForName: monitorForName,
    windowMatches: windowMatches,
    reservedKeys: reservedKeys,
    firstFreeKey: firstFreeKey,
    keyConflicts: keyConflicts,
    validateKey: validateKey,
    enabledSystemMap: enabledSystemMap,
    validateConfig: validateConfig,
    parseBarPlacement: parseBarPlacement,
    setPath: setPath,
    getPath: getPath,
    stateLabel: stateLabel,
    fuzzyScore: fuzzyScore,
    missingBinds: missingBinds,
    applyPreset: applyPreset,
    clone: clone,
    clamp: clamp
  }
}
