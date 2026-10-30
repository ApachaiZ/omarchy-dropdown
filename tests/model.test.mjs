import test from "node:test"
import assert from "node:assert/strict"
import { createRequire } from "node:module"

const require = createRequire(import.meta.url)
const Model = require("../Model.js")

test("parseExec handles quotes, escapes and field codes", () => {
  assert.deepEqual(Model.parseExec('kitty --title "Hello world" %U'), ["kitty", "--title", "Hello world"])
  assert.deepEqual(Model.parseExec('omarchy-launch-webapp "https://example.com/a b"'), ["omarchy-launch-webapp", "https://example.com/a b"])
  assert.deepEqual(Model.parseExec("cmd 100%% %f"), ["cmd", "100%"])
  assert.deepEqual(Model.parseExec(""), [])
})

test("webappUrl only recognises Omarchy web app launchers", () => {
  const discord = {
    command: ["omarchy-launch-webapp", "https://discord.com/channels/@me"],
    execString: "omarchy-launch-webapp https://discord.com/channels/@me"
  }
  assert.equal(Model.webappUrl(discord), "https://discord.com/channels/@me")
  assert.equal(Model.isWebappEntry(discord), true)

  assert.equal(Model.webappUrl({ command: ["firefox"], execString: "firefox %u" }), "")
  assert.equal(Model.webappUrl({ command: ["omarchy-launch-webapp"] }), "")
  assert.equal(Model.webappUrl({ command: ["omarchy-launch-webapp", "javascript:alert(1)"] }), "")
  assert.equal(Model.webappUrl({ command: ["/usr/bin/omarchy-launch-webapp", "https://x.com/"] }), "https://x.com/")
  // A quoted Exec string still parses.
  assert.equal(Model.webappUrl({ execString: 'omarchy-launch-webapp "https://a.example/x"' }), "https://a.example/x")
})

test("browser-installed PWAs are recognised without treating every browser window as one", () => {
  assert.equal(Model.isBrowserWebapp({
    command: ["google-chrome", "--app-id=abc"],
    startupClass: "chrome-abc-Default"
  }), true)
  assert.equal(Model.isBrowserWebapp({
    command: ["google-chrome", "--app=https://example.com/"],
    startupClass: ""
  }), true)
  assert.equal(Model.browserWebappUrl({
    command: ["google-chrome", "--app=https://example.com/x"]
  }), "https://example.com/x")
  assert.equal(Model.isBrowserWebapp({ command: ["google-chrome"] }), false)
  assert.equal(Model.isBrowserWebapp({ command: ["brave-browser"], startupClass: "brave-browser" }), false)
  assert.equal(Model.isBrowserWebapp({ command: ["chrome"], startupClass: "chrome-x.com__-Default" }), true)
  assert.equal(Model.isBrowserWebapp({ command: ["firefox"] }), false)
  assert.equal(Model.isBrowserWebapp({
    command: ["omarchy-launch-webapp", "https://example.com/"]
  }), false)
})

test("webappClass reproduces the Chromium app classes seen on Omarchy", () => {
  assert.equal(Model.webappClass("https://youtube.com/"), "chrome-youtube.com__-Default")
  assert.equal(Model.webappClass("https://discord.com/channels/@me"), "chrome-discord.com__channels_@me-Default")
  assert.equal(Model.webappClass("https://mail.example.com/inbox"), "chrome-mail.example.com__inbox-Default")
  assert.equal(Model.webappClassMatches("chrome-discord.com__channels_@me-Default", "https://discord.com/channels/@me"), true)
  // Path drift is accepted for the same host, the browser's generic class is not.
  assert.equal(Model.webappClassMatches("chrome-discord.com__app-Default", "https://discord.com/channels/@me"), true)
  assert.equal(Model.webappClassMatches("chrome", "https://discord.com/channels/@me"), false)
  assert.equal(Model.webappClassMatches("firefox", "https://discord.com/channels/@me"), false)
})

test("webapp class matching rejects a different host", () => {
  assert.equal(Model.webappClassMatches("chrome-notdiscord.com__-Default", "https://discord.com/"), false)
})

test("special workspaces are stable, unique and shell-safe", () => {
  const a = Model.specialWorkspace("Discord")
  const b = Model.specialWorkspace("discord")
  assert.match(a, /^special:dropdown-[a-z0-9_-]+$/)
  assert.notEqual(a, b)
  assert.equal(Model.specialWorkspace("Discord"), a)
  assert.equal(Model.isManagedSpecial(a), true)
  assert.equal(Model.isManagedSpecial("special"), true)
  assert.equal(Model.isManagedSpecial("special:special"), true)
  assert.equal(Model.isManagedSpecial("special:scratch"), false)
})

test("monitorBox swaps extents for 90 degree transforms", () => {
  const portrait = { x: 288, y: 0, width: 2560, height: 1440, transform: 1, reserved: [0, 26, 0, 0] }
  portrait.scale = 1.25
  assert.deepEqual(Model.monitorBox(portrait), { x: 288, y: 0, width: 1152, height: 2048, reserved: [0, 26, 0, 0] })
  const landscape = { x: 1440, y: 0, width: 3440, height: 1440, transform: 0, scale: 1.25, reserved: [0, 26, 0, 0] }
  assert.deepEqual(Model.monitorBox(landscape), { x: 1440, y: 0, width: 2752, height: 1152, reserved: [0, 26, 0, 0] })
})

test("geometryFor centres horizontally at the top by default", () => {
  const monitor = { x: 1440, y: 0, width: 3440, height: 1440, transform: 0, scale: 1.25, reserved: [0, 26, 0, 0] }
  const geometry = Model.geometryFor(monitor, {
    widthPercent: 60, heightPercent: 80, topOffset: 12, sideMargin: 0
  })
  assert.equal(geometry.width, 1651)
  assert.equal(geometry.height, 882)
  assert.equal(geometry.x, 1440 + Math.round((2752 - 1651) / 2))
  assert.equal(geometry.y, 38)
  assert.equal(geometry.placement, "top")
})

test("geometryFor honours the placement independently from the slide edge", () => {
  const monitor = { x: 100, y: 0, width: 1000, height: 800, transform: 0, reserved: [0, 26, 0, 0] }
  const geo = { widthPercent: 50, heightPercent: 50, topOffset: 10, sideMargin: 10 }
  const center = Model.geometryFor(monitor, { ...geo, placement: "center", edge: "top" })
  const top = Model.geometryFor(monitor, { ...geo, placement: "top", edge: "top" })
  const bottom = Model.geometryFor(monitor, { ...geo, placement: "bottom", edge: "bottom" })
  const left = Model.geometryFor(monitor, { ...geo, placement: "left", edge: "left" })
  const right = Model.geometryFor(monitor, { ...geo, placement: "right", edge: "right" })
  assert.equal(top.x, bottom.x)
  assert.ok(top.y < center.y && center.y < bottom.y)
  assert.equal(left.x, 110)
  assert.equal(right.x, monitor.x + monitor.width - 10 - right.width)
  assert.equal(left.edge, "left")
  assert.equal(center.placement, "center")
  assert.equal(bottom.y + bottom.height, monitor.height - 10)
})

test("slideStart begins just outside the requested screen edge", () => {
  const monitor = { x: 0, y: 0, width: 1000, height: 800, transform: 0, reserved: [0, 0, 0, 0] }
  const final = { x: 200, y: 200, width: 500, height: 400 }
  assert.deepEqual(Model.slideStart(monitor, final, "top", 20), { x: 200, y: -420 })
  assert.deepEqual(Model.slideStart(monitor, final, "bottom", 20), { x: 200, y: 820 })
  assert.deepEqual(Model.slideStart(monitor, final, "left", 20), { x: -520, y: 200 })
  assert.deepEqual(Model.slideStart(monitor, final, "right", 20), { x: 1020, y: 200 })
})

test("geometryFor clamps tiny percentages to the usable box", () => {
  const monitor = { x: 0, y: 0, width: 1000, height: 800, transform: 0, reserved: [0, 26, 0, 0] }
  const geometry = Model.geometryFor(monitor, { widthPercent: 20, heightPercent: 20, topOffset: 30, sideMargin: 0 })
  assert.equal(geometry.width, 320)
  assert.equal(geometry.height, 240)
  assert.ok(geometry.x >= 0)
  assert.ok(geometry.y + geometry.height <= 800)
})

test("firstFreeKey skips reserved and used keys", () => {
  assert.equal(Model.firstFreeKey("Discord", [], ["d"]), "i")
  assert.equal(Model.firstFreeKey("Discord", ["i"], ["d"]), "s")
  assert.equal(Model.firstFreeKey("2FA", [], []), "f")
  assert.equal(Model.firstFreeKey("l", [], ["l"]), "a")
})

test("validateKey refuses palette commands and duplicates, never silently", () => {
  const apps = [
    { id: "Discord", name: "Discord", enabled: true, key: "d" },
    { id: "YouTube", name: "YouTube", enabled: true, key: "y" }
  ]
  assert.equal(Model.validateKey("d", "YouTube", apps, {}).ok, false)
  assert.match(Model.validateKey("d", "YouTube", apps, {}).error, /Discord/)
  assert.equal(Model.validateKey("m", "Discord", apps, {}).ok, false)
  assert.equal(Model.validateKey("k", "Discord", apps, {}).ok, false)
  assert.equal(Model.validateKey("t", "Discord", apps, { terminal: true }).ok, false)
  assert.equal(Model.validateKey("t", "Discord", apps, { terminal: false }).ok, true)
  assert.equal(Model.validateKey("x", "Discord", apps, {}).ok, true)
  assert.equal(Model.validateKey("q", "Discord", apps, {}).ok, false)
})

test("commands are configurable and duplicate keys are resolved deterministically", () => {
  const { config } = Model.validateConfig({
    settings: { commands: { help: "z", manage: "z", preview: "p" } },
    apps: {}
  })
  assert.equal(config.settings.commands.help, "z")
  assert.equal(config.settings.commands.manage, "m")
  assert.equal(Model.commandValues(config.settings.commands).includes("z"), true)
  assert.ok(Model.reservedKeys({}, config.settings.commands).includes("z"))
})

test("usage and launchAtLogin survive validation", () => {
  const { config } = Model.validateConfig({
    apps: { Discord: { enabled: true, key: "d", uses: 12, lastUsed: 99, launchAtLogin: true } }
  })
  assert.equal(config.apps.Discord.uses, 12)
  assert.equal(config.apps.Discord.lastUsed, 99)
  assert.equal(config.apps.Discord.launchAtLogin, true)
})

test("keyConflicts reports every duplicated enabled key", () => {
  const conflicts = Model.keyConflicts([
    { id: "a", enabled: true, key: "d" },
    { id: "b", enabled: true, key: "d" },
    { id: "c", enabled: false, key: "d" },
    { id: "x", enabled: true, key: "e" }
  ])
  assert.deepEqual(Object.keys(conflicts), ["d"])
  assert.deepEqual(conflicts.d, ["a", "b"])
})

test("validateConfig merges defaults and clamps bad values", () => {
  const { config, warnings } = Model.validateConfig({
    schemaVersion: 1,
    settings: {
      geometry: { preset: "large", widthPercent: 500, heightPercent: 10, topOffset: -4, sideMargin: 800 },
      animations: { mode: "warp", durationMs: 9999, easing: "nope", reducedMotion: true },
      autoHideOnFocusLoss: "yes"
    },
    apps: {
      Discord: { enabled: true, key: "d", url: "https://discord.com/channels/@me", geometry: { widthPercent: 200, heightPercent: 50 } },
      "bad/id": "nope"
    }
  })
  assert.equal(config.settings.screen, "auto")
  assert.equal(config.settings.geometry.widthPercent, 100)
  assert.equal(config.settings.geometry.heightPercent, 20)
  assert.equal(config.settings.geometry.topOffset, 0)
  assert.equal(config.settings.geometry.sideMargin, 400)
  assert.equal(config.settings.geometry.edge, "top")
  assert.equal(config.settings.geometry.placement, "top")
  assert.equal(config.settings.screen, "auto")
  assert.equal(config.settings.animations.mode, "slide+fade")
  assert.equal(config.settings.animations.durationMs, 800)
  assert.equal(config.settings.animations.easing, "outCubic")
  assert.equal(config.settings.animations.reducedMotion, true)
  assert.equal(config.settings.autoHideOnFocusLoss, true)
  assert.equal(config.apps.Discord.enabled, true)
  assert.equal(config.apps.Discord.geometry.widthPercent, 100)
  assert.equal(config.apps["system.terminal"].enabled, false)
  assert.deepEqual(warnings, [])
  assert.equal(Model.validateConfig("not json").warnings.length, 1)
})

test("addresses are normalised across hyprctl and event formats", () => {
  assert.equal(Model.normalizeAddress("5593afe40a60"), "0x5593afe40a60")
  assert.equal(Model.normalizeAddress("0x5593AFE40A60"), "0x5593afe40a60")
  assert.equal(Model.normalizeAddress("not an address"), "")
  assert.equal(Model.validAddress("5593afe40a60"), true)
  assert.equal(Model.validAddress("0x5593afe40a60"), true)
  assert.equal(Model.validAddress(""), false)
})

test("parseClients tolerates malformed output and maps fields", () => {
  assert.deepEqual(Model.parseClients("nope"), [])
  const parsed = Model.parseClients(JSON.stringify([{
    address: "0xabc", class: "chrome-discord.com__-Default", title: "Discord",
    pid: 42, workspace: { id: -99, name: "special:dropdown-discord-1" }, monitor: 1,
    floating: true, fullscreen: 0, at: [10, 20], size: [800, 600], mapped: true
  }]))
  assert.equal(parsed.length, 1)
  assert.equal(parsed[0].address, "0xabc")
  assert.equal(parsed[0].workspace, "special:dropdown-discord-1")
  assert.equal(parsed[0].floating, true)
  assert.equal(Model.validAddress(parsed[0].address), true)
})

test("parseMonitors keeps only active monitors and understands specials", () => {
  const monitors = Model.parseMonitors(JSON.stringify([
    { id: 1, name: "A", x: 0, y: 0, width: 100, height: 50, scale: 1, transform: 1, reserved: [0, 26, 0, 0], focused: true, activeWorkspace: { name: "1" }, specialWorkspace: { name: "" } },
    { id: 2, name: "B", disabled: true }
  ]))
  assert.equal(monitors.length, 1)
  assert.equal(monitors[0].reserved[1], 26)
  assert.equal(Model.monitorForName(monitors, "missing").name, "A")
})

test("windowMatches separates webapps, terminals and file managers", () => {
  const discord = { kind: "webapp", name: "Discord", url: "https://discord.com/channels/@me" }
  assert.equal(Model.windowMatches(discord, { class: "chrome-discord.com__channels_@me-Default", title: "" }), true)
  assert.equal(Model.windowMatches(discord, { class: "firefox", title: "Discord" }), true)
  assert.equal(Model.windowMatches(discord, { class: "firefox", title: "Mail" }), false)

  const terminal = { kind: "system", system: "terminal", name: "kitty", expectedClass: "apach.dropdown.terminal", pid: 7 }
  assert.equal(Model.windowMatches(terminal, { class: "apach.dropdown.terminal" }), true)
  assert.equal(Model.windowMatches(terminal, { class: "kitty", pid: 7 }), true)
  assert.equal(Model.windowMatches(terminal, { class: "kitty", pid: 8 }), false)

  const files = { kind: "system", system: "files", name: "Files", desktopId: "org.gnome.Nautilus" }
  assert.equal(Model.windowMatches(files, { class: "org.gnome.Nautilus" }), true)
  assert.equal(Model.windowMatches(files, { class: "org.gnome.Nautilus", title: "Home" }), true)
})


test("stateLabel has a label for every documented state", () => {
  assert.equal(Model.stateLabel("stopped"), "Stopped")
  assert.equal(Model.stateLabel("launching"), "Launching")
  assert.equal(Model.stateLabel("visible"), "Visible")
  assert.equal(Model.stateLabel("hidden"), "Hidden")
  assert.equal(Model.stateLabel("closing"), "Closing")
  assert.equal(Model.stateLabel("error"), "Error")
  assert.equal(Model.stateLabel("nope"), "Stopped")
})

test("applyPreset keeps the offsets and updates the percentages", () => {
  const next = Model.applyPreset({ topOffset: 20, sideMargin: 8 }, "compact")
  assert.deepEqual(next, { preset: "compact", placement: "top", edge: "top", widthPercent: 45, heightPercent: 65, topOffset: 20, sideMargin: 8 })
  assert.equal(Model.applyPreset({}, "nope").preset, undefined)
})

test("setPath and getPath round-trip nested settings", () => {
  const config = Model.clone(Model.DEFAULT_CONFIG)
  Model.setPath(config, "settings.geometry.widthPercent", 72)
  assert.equal(Model.getPath(config, "settings.geometry.widthPercent"), 72)
  assert.equal(Model.getPath(config, "settings.nope", "x"), "x")
})

test("parseBarPlacement finds the widget and every section size", () => {
  const raw = JSON.stringify({
    bar: { layout: {
      left: [{ id: "omarchy.menu" }, { id: "apach.dropdown" }],
      center: [],
      right: [{ id: "omarchy.clock" }]
    } }
  })
  const placement = Model.parseBarPlacement(raw, "apach.dropdown")
  assert.equal(placement.section, "left")
  assert.equal(placement.index, 1)
  assert.deepEqual(placement.sizes, { left: 2, center: 0, right: 1 })
  assert.equal(Model.parseBarPlacement("{}", "apach.dropdown").index, -1)
  assert.equal(Model.parseBarPlacement("not json", "apach.dropdown").section, "")
})

test("new tab and pop-out commands are configurable and reserved", () => {
  assert.equal(Model.DEFAULT_COMMANDS.nextWindow, "w")
  assert.equal(Model.DEFAULT_COMMANDS.popout, "'")
  const apps = [{ id: "Discord", name: "Discord", enabled: true, key: "d" }]
  assert.equal(Model.validateKey("w", "Discord", apps, {}).ok, false)
  assert.equal(Model.validateKey("'", "Discord", apps, {}).ok, false)
  const { config } = Model.validateConfig({
    settings: { commands: { nextWindow: "v", popout: "z" } },
    apps: {}
  })
  assert.equal(config.settings.commands.nextWindow, "v")
  assert.equal(config.settings.commands.popout, "z")
  assert.ok(Model.reservedKeys({}, config.settings.commands).includes("v"))
})

test("tab position defaults to top and only accepts top or bottom", () => {
  assert.equal(Model.DEFAULT_CONFIG.settings.tabs.position, "top")
  assert.equal(Model.validateConfig({}).config.settings.tabs.position, "top")
  assert.equal(Model.validateConfig({ settings: { tabs: { position: "bottom" } } }).config.settings.tabs.position, "bottom")
  assert.equal(Model.validateConfig({ settings: { tabs: { position: "left" } } }).config.settings.tabs.position, "top")
  assert.deepEqual(Model.TABS_POSITIONS, ["top", "bottom"])
})

test("direct app shortcuts are normalized and validated", () => {
  assert.equal(Model.normalizeShortcut("super + shift + d"), "SUPER + SHIFT + D")
  assert.equal(Model.normalizeShortcut("CONTROL+ALT+1"), "CTRL + ALT + 1")
  assert.equal(Model.normalizeShortcut("META + F12"), "SUPER + F12")
  assert.equal(Model.normalizeShortcut("SHIFT + D"), "")
  assert.equal(Model.normalizeShortcut("D"), "")
  assert.equal(Model.normalizeShortcut("SUPER + SHIFT + SPACE"), "SUPER + SHIFT + SPACE")
  assert.equal(Model.normalizeShortcut("SUPER + SHIFT + D + E"), "")
})

test("validateConfig keeps one direct shortcut per enabled app", () => {
  const { config } = Model.validateConfig({
    apps: {
      Discord: { enabled: true, key: "d", shortcut: "super+shift+d" },
      Agent: { enabled: true, key: "i", shortcut: "SUPER + SHIFT + D" },
      Other: { enabled: true, key: "o", shortcut: "SUPER + ALT + O" }
    }
  })
  assert.equal(config.apps.Discord.shortcut, "SUPER + SHIFT + D")
  assert.equal(config.apps.Agent.shortcut, undefined)
  assert.equal(config.apps.Other.shortcut, "SUPER + ALT + O")
})

test("shortcut modmask and key match hyprctl bind fields", () => {
  assert.equal(Model.shortcutModmask("SUPER + SHIFT + D"), 65)
  assert.equal(Model.shortcutModmask("CTRL + ALT + J"), 12)
  assert.equal(Model.shortcutKey("super + shift + d"), "D")
  assert.equal(Model.shortcutModmask("SHIFT + D"), 0)
  assert.equal(Model.shortcutKey("SHIFT + D"), "")
})

test("shortcut normalization covers named keys and lua spelling", () => {
  assert.equal(Model.normalizeShortcut("super+alt+left"), "SUPER + ALT + LEFT")
  assert.equal(Model.normalizeShortcut("SUPER + TAB"), "SUPER + TAB")
  assert.equal(Model.normalizeShortcut("CTRL + SHIFT + PAGEUP"), "CTRL + SHIFT + PAGEUP")
  assert.equal(Model.normalizeShortcut("SUPER + F24"), "SUPER + F24")
  assert.equal(Model.normalizeShortcut("SUPER + F25"), "")
  assert.equal(Model.normalizeShortcut("SUPER + ESCAPE"), "")
  assert.equal(Model.normalizeShortcut("SUPER + NOPE"), "")
  assert.equal(Model.luaShortcutKey("SUPER + ALT + LEFT"), "LEFT")
  assert.equal(Model.luaShortcutKey("SUPER + SHIFT + D"), "D")
  assert.equal(Model.luaShortcutKey("SUPER + F12"), "F12")
  assert.equal(Model.luaShortcutKey("SUPER + PAGEUP"), "Prior")
  assert.equal(Model.luaShortcutKey("SUPER + PAGEDOWN"), "Next")
  assert.equal(Model.hyprBindKey("SUPER + PAGEUP"), "Prior")
  assert.equal(Model.hyprBindKey("SUPER + ALT + PERIOD"), "PERIOD")
  assert.equal(Model.shortcutModmask("SUPER + ALT + LEFT"), 72)
  assert.equal(Model.shortcutKey("super + alt + left"), "LEFT")
})

test("suggestShortcut avoids taken chords and follows the app initial", () => {
  assert.equal(Model.suggestShortcut("Terminal", []), "SUPER + SHIFT + T")
  assert.equal(Model.suggestShortcut("Terminal", ["SUPER + SHIFT + T"]), "SUPER + SHIFT + E")
  assert.equal(
    Model.suggestShortcut("Terminal", ["SUPER + SHIFT + T", "SUPER + SHIFT + E", "SUPER + SHIFT + R"]),
    "SUPER + SHIFT + M"
  )
})

test("unsafe URLs are rejected while normal web app URLs pass", () => {
  assert.equal(Model.isSafeUrl("https://discord.com/channels/@me"), true)
  assert.equal(Model.isSafeUrl("http://localhost:8080/app"), true)
  assert.equal(Model.isSafeUrl("javascript:alert(1)"), false)
  assert.equal(Model.isSafeUrl("https://example.com/a b"), false)
  assert.equal(Model.isSafeUrl("https://example.com/\"x\""), false)
  assert.equal(Model.isSafeUrl("https://example.com/\nx"), false)
  assert.equal(Model.isSafeUrl("file:///etc/passwd"), false)
  const { config, warnings } = Model.validateConfig({
    apps: { Bad: { enabled: true, key: "b", url: "javascript:alert(1)" } }
  })
  assert.equal(config.apps.Bad.url, undefined)
  assert.ok(warnings.some((w) => w.includes("unsafe URL")))
})

test("topApps is clamped to a usable card count", () => {
  assert.equal(Model.validateConfig({ settings: { topApps: 12 } }).config.settings.topApps, 7)
  assert.equal(Model.validateConfig({ settings: { topApps: 1 } }).config.settings.topApps, 3)
  assert.equal(Model.validateConfig({ settings: { topApps: 6 } }).config.settings.topApps, 6)
  assert.equal(Model.DEFAULT_CONFIG.settings.topApps, 5)
})

test("fuzzyScore ranks substring and subsequence matches", () => {
  assert.ok(Model.fuzzyScore("disc", "Discord") > 0)
  assert.ok(Model.fuzzyScore("dcrd", "Discord") > 0)
  assert.equal(Model.fuzzyScore("xyz", "Discord"), -1)
  assert.equal(Model.fuzzyScore("", "Discord"), 1000)
  assert.ok(Model.fuzzyScore("dis", "Discord") > Model.fuzzyScore("dis", "Discord Canary"))
  assert.ok(Model.fuzzyScore("gmail", "Google Mail") > Model.fuzzyScore("gml", "Google Mail"))
})

test("missingBinds finds generated shortcuts absent from the live table", () => {
  const binds = [
    { modmask: 64, key: "A", description: "Dropdown: Agent" },
    { modmask: 65, key: "D", description: "Toggle menu" },
    { modmask: 65, key: "E", description: "Dropdown: MailFlow" }
  ]
  const entries = [
    { shortcut: "SUPER + A" },
    { shortcut: "SUPER + SHIFT + D" },
    { shortcut: "SUPER + SHIFT + E" }
  ]
  assert.deepEqual(Model.missingBinds(binds, entries), ["SUPER + SHIFT + D"])
  assert.deepEqual(Model.missingBinds([], entries).length, 3)
  assert.deepEqual(Model.missingBinds(binds, []), [])
})
