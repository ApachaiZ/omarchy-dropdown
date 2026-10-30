// Omarchy Dropdown service.
//
// Owns the application catalog, the managed-window registry, persistence and
// all Hyprland dispatches. The overlay and the bar widget are thin views over
// this object, so closing the palette never loses managed state.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

import "Model.js" as Model
import "js/State.js" as State
import "js/Shortcuts.js" as Shortcuts
import "js/ConfigFile.js" as ConfigFile

Item {
  id: service

  // Injected by omarchy-shell.
  property var shell: null

  property var manifest: null
  property var pluginRegistry: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: String(Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config"))
  readonly property string stateHome: String(Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state"))
  readonly property string configPath: configHome + "/omarchy/dropdown.json"
  readonly property string bindsPath: configHome + "/hypr/dropdown-binds.lua"
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string statePath: stateDir + "/dropdown-state.json"
  readonly property string agentPath: configHome + "/omarchy/defaults/agent"
  readonly property string agentWorkDir: home + "/Work"
  readonly property int launchTimeoutMs: 20000
  readonly property int closeConfirmMs: 5000

  // ---- Public, read-only state ---------------------------------------------

  property var config: Model.clone(Model.DEFAULT_CONFIG)
  property var catalog: []              // every detected app, with live state
  property var webapps: []              // webapp subset, sorted
  property var applications: []          // ordinary desktop apps, sorted
  property var missingApps: []          // configured web apps that disappeared
  property var registry: ({})           // appId -> ephemeral window record
  property var clients: []
  property var monitors: []
  property var errors: ({})             // appId -> explanation
  property var launching: ({})          // appId -> { startedAt, snapshot, pid, context }
  property var adoptable: ({})          // appId -> address of an unmanaged match
  property string currentAppId: ""
  property string lastAppId: ""
  property string notice: ""
  property var pendingShortcut: null
  signal shortcutAssigned(string appId, string shortcut)
  signal shortcutRejected(string appId, string message)
  property bool paletteOpen: false
  property string paletteTarget: ""
  property string paletteMonitor: ""
  property string paletteWorkspace: ""
  property string palettePreviousFocus: ""

  // Resolved system defaults.
  property string terminalDesktopId: ""
  property string filesDesktopId: ""
  property string agentName: ""

  property var conflicts: Model.keyConflicts(service.catalog)
  readonly property var enabledApps: {
    var out = []
    for (var i = 0; i < service.catalog.length; i++)
      if (service.catalog[i].enabled) out.push(service.catalog[i])
    return out
  }
  readonly property var currentApp: service.findApp(service.currentAppId)
  readonly property string barTooltip: {
    if (service.currentAppId) return "Dropdown — " + (service.currentApp ? service.currentApp.name : service.currentAppId)
    var last = service.findApp(service.lastAppId)
    if (last) return "Dropdown — " + last.name + " is hidden"
    return "Dropdown"
  }

  // ---- Persistence ---------------------------------------------------------

  property bool configLoaded: false
  property bool stateLoaded: false
  property string lastConfigWrite: ""
  property bool configDirty: false
  property bool configPendingChange: false

  FileView {
    id: configView
    path: service.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var current = String(text() || "")
      if (!service.configLoaded) {
        service.loadConfig(current)
        return
      }
      if (!service.configPendingChange) return
      service.configPendingChange = false
      // Our own atomic write comes back as a file change. Reloading it would
      // clobber edits made while the write was in flight.
      if (ConfigFile.isOwnWrite(current, service.lastConfigWrite)) return
      if (!ConfigFile.looksLikeConfig(current)) {
        // Never replace the user's broken file or silently reset settings; a
        // later valid edit will be adopted normally.
        service.notify("dropdown.json is not valid JSON; keeping the current settings.")
        return
      }
      service.backupConfig()
      service.loadConfig(current)
    }
    onLoadFailed: {
      service.configPendingChange = false
      if (service.configLoaded) {
        service.notify("dropdown.json is no longer readable; keeping the current settings.")
        return
      }
      service.configLoaded = true
      service.configDirty = false
      service.config = Model.clone(Model.DEFAULT_CONFIG)
      service.saveConfigNow()
      service.rebuildCatalog()
    }
    onFileChanged: {
      var current = String(text() || "")
      if (ConfigFile.isOwnWrite(current, service.lastConfigWrite)) return
      if (service.configDirty) {
        // Local edits are newer than the file: keep them and rewrite.
        service.backupConfig()
        service.saveConfigNow()
        return
      }
      service.configPendingChange = true
      configView.reload()
    }
  }

  // The state file is written by this service only. It is read once at
  // startup; watching our own writes would reload a stale snapshot and
  // re-adopt windows that were just released or popped out.
  FileView {
    id: stateView
    path: service.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: service.loadState(text())
    onLoadFailed: {
      service.stateLoaded = true
      service.savedRegistry = {}
      service.recoverFromSaved()
    }
  }

  property var savedRegistry: ({})
  // Addresses just released as ordinary windows. State reloads and orphan
  // recovery must not re-adopt them while the async workspace move lands.
  property var released: ({})
  property string autostartSession: ""
  property bool autostartChecked: false
  readonly property string sessionId: String(Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "")
  property string hyprError: ""
  property string lastHyprErrorAt: ""

  // Disabling the plugin destroys the service. Keep generated binds on a
  // normal shell reload, but remove them when the plugin is actually disabled
  // or removed so no dangling shortcut points at a dead service.
  function pluginStillEnabled() {
    var registry = service.pluginRegistry
      || (service.shell && service.shell.pluginRegistry ? service.shell.pluginRegistry : null)
    if (!registry || typeof registry.isEnabled !== "function") return true
    var id = service.manifest ? String(service.manifest.id || "") : "apach.dropdown"
    return registry.isEnabled(id) === true
  }

  function cleanupBinds() {
    var header = Shortcuts.header()
    service.lastBindsContent = header
    service.bindsLoaded = true
    bindsView.setText(header)
    Quickshell.execDetached(["hyprctl", "reload"])
  }

  function loadConfig(raw) {
    var result = Model.validateConfig(String(raw || ""))
    service.config = result.config
    service.configLoaded = true
    service.configDirty = false
    if (result.warnings.length > 0) service.notify(result.warnings[0])
    service.normalizeConfig()
    service.rebuildCatalog()
    service.migrateConfigByUrl()
    if (service.stateLoaded) service.refreshClients()
    autostartTimer.restart()
  }

  // Copy the file before an external edit is adopted or overwritten. Five
  // timestamped backups stay next to dropdown.json; pruning uses a constant
  // path passed as an argument, never interpolated shell text.
  function backupConfig() {
    var target = ConfigFile.backupName(service.configPath, new Date())
    if (!target) return
    Quickshell.execDetached(["cp", "--", service.configPath, target])
    Quickshell.execDetached(ConfigFile.pruneCommand(service.configPath))
  }

  function normalizeConfig() {
    var next = Model.clone(service.config)
    var changed = false
    var system = Model.enabledSystemMap(next)
    var used = []
    for (var id in next.apps) {
      var entry = next.apps[id]
      if (!entry || entry.enabled !== true) continue
      if (entry.key) used.push(entry.key)
    }
    for (var sid in next.apps) {
      if (sid.indexOf("system.") !== 0) continue
      if (next.apps[sid].enabled === true && !next.apps[sid].key) {
        // A system app keeps its conventional key unless another enabled app
        // already took it; in that case the UI reports the conflict.
        var conventional = sid === "system.terminal" ? Model.SYSTEM_KEYS.terminal
          : sid === "system.agent" ? Model.SYSTEM_KEYS.agent : Model.SYSTEM_KEYS.files
        if (used.indexOf(conventional) < 0) {
          next.apps[sid].key = conventional
          used.push(conventional)
          changed = true
        }
      }
    }
    if (changed) {
      service.config = next
      service.scheduleConfigSave()
    }
  }

  // A web app renamed on disk changes its desktop id. The URL stored in the
  // configuration is the fallback identity, so the user does not lose the key,
  // size or enabled bit.
  function migrateConfigByUrl() {
    if (!service.configLoaded) return
    var next = Model.clone(service.config)
    var changed = false
    for (var i = 0; i < service.webapps.length; i++) {
      var app = service.webapps[i]
      if (!app.url || next.apps[app.id]) continue
      for (var oldId in next.apps) {
        var old = next.apps[oldId]
        if (!old || old.url !== app.url) continue
        if (service.webapps.some(function(w) { return w.id === oldId })) continue
        var moved = Model.clone(old)
        delete next.apps[oldId]
        next.apps[app.id] = moved
        changed = true
        service.notify("Moved settings from " + oldId + " to " + app.id + ".")
        break
      }
    }
    if (changed) {
      service.config = next
      service.saveConfigNow()
      service.rebuildCatalog()
    }
  }

  function scheduleConfigSave() {
    service.configDirty = true
    configSaveTimer.restart()
  }

  function saveConfigNow() {
    configSaveTimer.stop()
    var text = ConfigFile.encode(service.config)
    service.lastConfigWrite = text
    service.configDirty = false
    configView.setText(text)
  }

  Timer {
    id: configSaveTimer
    interval: 250
    onTriggered: service.saveConfigNow()
  }

  function loadState(raw) {
    var parsed = null
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { parsed = null }
    var out = {}
    if (parsed && parsed.apps && typeof parsed.apps === "object") {
      for (var id in parsed.apps) {
        var entry = parsed.apps[id]
        if (!entry || !Model.validAddress(entry.address)) continue
        out[id] = {
          address: String(entry.address),
          class: String(entry.class || ""),
          pid: Number(entry.pid || 0),
          hidden: entry.hidden === true,
          special: String(entry.special || Model.specialWorkspace(id)),
          previousWorkspace: String(entry.previousWorkspace || ""),
          previousMonitor: String(entry.previousMonitor || ""),
          previousFocus: String(entry.previousFocus || ""),
          since: Number(entry.since || 0)
        }
      }
    }
    service.autostartSession = parsed && typeof parsed.autostartSession === "string"
      ? String(parsed.autostartSession) : ""
    service.stateLoaded = true
    service.savedRegistry = out
    service.recoverFromSaved()
    autostartTimer.restart()
    if (service.configLoaded) service.refreshClients()
  }

  function markReleased(address) {
    var key = Model.normalizeAddress(address)
    if (!key) return
    var next = {}
    for (var a in service.released) next[a] = service.released[a]
    next[key] = Date.now()
    service.released = next
    releasedSweep.restart()
  }

  Timer {
    id: releasedSweep
    interval: 4000
    onTriggered: service.released = ({})
  }

  function scheduleStateSave() {
    stateSaveTimer.restart()
  }

  function saveStateNow() {
    stateSaveTimer.stop()
    var apps = {}
    for (var id in service.registry) {
      var entry = service.registry[id]
      if (!entry || !Model.validAddress(entry.address)) continue
      apps[id] = {
        address: entry.address,
        class: entry.class || "",
        pid: entry.pid || 0,
        hidden: entry.hidden === true,
        special: entry.special || Model.specialWorkspace(id),
        previousWorkspace: entry.previousWorkspace || "",
        previousMonitor: entry.previousMonitor || "",
        previousFocus: entry.previousFocus || "",
        since: entry.since || 0
      }
    }
    stateView.setText(JSON.stringify({
      version: 1,
      autostartSession: service.autostartSession,
      apps: apps
    }, null, 2) + "\n")
  }

  Timer {
    id: stateSaveTimer
    interval: 400
    onTriggered: service.saveStateNow()
  }

  // ---- System defaults -----------------------------------------------------

  Process {
    id: terminalIdProc
    command: ["xdg-terminal-exec", "--print-id"]
    stdout: StdioCollector {
      onStreamFinished: {
        var id = String(text || "").trim().split(":")[0]
        id = id.replace(/\.desktop$/, "")
        if (id && id !== service.terminalDesktopId) {
          service.terminalDesktopId = id
          service.rebuildCatalog()
        }
      }
    }
    onExited: service.rebuildCatalog()
  }

  Process {
    id: filesIdProc
    command: ["xdg-mime", "query", "default", "inode/directory"]
    stdout: StdioCollector {
      onStreamFinished: {
        var id = String(text || "").trim().replace(/\.desktop$/, "")
        if (id !== service.filesDesktopId) {
          service.filesDesktopId = id
          service.rebuildCatalog()
        }
      }
    }
    onExited: service.rebuildCatalog()
  }

  FileView {
    id: agentView
    path: service.agentPath
    watchChanges: true
    printErrors: false
    onLoaded: service.loadAgent(text())
    onFileChanged: reload()
  }

  function loadAgent(raw) {
    var next = String(raw || "").trim().split("\n")[0]
    if (next === service.agentName) return
    service.agentName = next
    service.rebuildCatalog()
  }

  function refreshSystemDefaults() {
    if (!terminalIdProc.running) terminalIdProc.running = true
    if (!filesIdProc.running) filesIdProc.running = true
    agentView.reload()
  }

  // ---- Catalog -------------------------------------------------------------

  function entryForDesktop(id) {
    if (!id) return null
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].id || "") === String(id)) return values[i]
    }
    return null
  }

  function findApp(appId) {
    for (var i = 0; i < service.catalog.length; i++)
      if (service.catalog[i].id === appId) return service.catalog[i]
    return null
  }

  function commandKey(name) {
    var commands = service.config.settings.commands || Model.DEFAULT_COMMANDS
    return String(commands[name] || Model.DEFAULT_COMMANDS[name] || "")
  }

  function commandKeys() {
    return Model.commandValues(service.config.settings.commands)
  }

  function commandForKey(key) {
    var value = String(key || "")
    var commands = service.config.settings.commands || Model.DEFAULT_COMMANDS
    for (var name in commands) if (String(commands[name]) === value) return name
    return ""
  }

  function recordUse(appId) {
    if (!appId) return
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    var uses = (Number(next.apps[appId].uses) || 0) + 1
    var lastUsed = Date.now()
    next.apps[appId].uses = uses
    next.apps[appId].lastUsed = lastUsed
    service.config = next
    service.scheduleConfigSave()
    // Keep usage ordering live without rebuilding the whole catalog.
    for (var i = 0; i < service.catalog.length; i++) {
      if (service.catalog[i].id !== appId) continue
      var list = service.catalog.slice()
      list[i] = Object.assign({}, list[i], { uses: uses, lastUsed: lastUsed })
      service.catalog = list
      break
    }
  }

  function topApps(count) {
    var limit = Number(count) || Number(service.config.settings.topApps) || 5
    limit = Math.max(1, Math.min(9, Math.round(limit)))
    var out = []
    for (var i = 0; i < service.enabledApps.length; i++) out.push(service.enabledApps[i])
    out.sort(function(a, b) {
      var ua = Number(a.uses) || 0
      var ub = Number(b.uses) || 0
      if (ua !== ub) return ub - ua
      var la = Number(a.lastUsed) || 0
      var lb = Number(b.lastUsed) || 0
      if (la !== lb) return lb - la
      var na = String(a.name).toLowerCase()
      var nb = String(b.name).toLowerCase()
      return na < nb ? -1 : (na > nb ? 1 : 0)
    })
    return out.slice(0, limit)
  }

  function stateFor(appId) {
    var entry = service.registry[appId]
    var win = entry ? service.clientByAddress(entry.address) : null
    return State.appState(entry, !!win, service.errors[appId], service.launching[appId])
  }

  function clientByAddress(address) {
    var want = Model.normalizeAddress(address)
    if (!want) return null
    for (var i = 0; i < service.clients.length; i++)
      if (Model.normalizeAddress(service.clients[i].address) === want) return service.clients[i]
    return null
  }

  function appStateNote(app) {
    var entry = app ? service.registry[app.id] : null
    var win = entry ? service.clientByAddress(entry.address) : null
    return State.stateNote(app, entry, win, service.errors[app ? app.id : ""])
  }

  function rebuildCatalog() {
    if (!service.configLoaded) return
    var values = DesktopEntries.applications.values || []
    var discovered = []
    var ordinary = []
    var seenUrls = ({})
    var seenIds = ({})
    var defaultIds = ({})
    if (service.terminalDesktopId) defaultIds[service.terminalDesktopId] = true
    if (service.filesDesktopId) defaultIds[service.filesDesktopId] = true
    function sortByName(list) {
      list.sort(function(a, b) {
        var na = a.name.toLowerCase()
        var nb = b.name.toLowerCase()
        return na < nb ? -1 : (na > nb ? 1 : 0)
      })
      return list
    }
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry || !entry.id) continue
      var id = String(entry.id)
      if (seenIds[id] || defaultIds[id]) continue
      seenIds[id] = true
      var url = Model.webappUrl(entry)
      var pwa = !url && Model.isBrowserWebapp(entry)
      if (pwa) url = Model.browserWebappUrl(entry)
      if (url) {
        var urlKey = url.toLowerCase()
        if (seenUrls[urlKey]) continue
        seenUrls[urlKey] = true
      }
      var base = {
        id: id,
        system: "",
        name: String(entry.name || id),
        icon: String(entry.icon || ""),
        desktopId: id,
        startupClass: String(entry.startupClass || ""),
        expectedClass: pwa ? String(entry.startupClass || "") : "",
        url: url || "",
        available: true
      }
      if (url || pwa) {
        base.kind = "webapp"
        base.detail = pwa ? "Browser web app" : "Web app"
        discovered.push(base)
      } else {
        base.kind = "app"
        base.detail = "Desktop app"
        ordinary.push(base)
      }
    }
    sortByName(discovered)
    sortByName(ordinary)
    service.webapps = discovered
    service.applications = ordinary

    var list = []

    // System defaults stay at the top of the manage list.
    var term = service.entryForDesktop(service.terminalDesktopId)
    list.push({
      id: "system.terminal",
      kind: "system",
      system: "terminal",
      name: term ? String(term.name || "Terminal") : "Terminal",
      icon: term ? String(term.icon || "utilities-terminal") : "utilities-terminal",
      desktopId: service.terminalDesktopId,
      startupClass: term ? String(term.startupClass || "") : "",
      expectedClass: "apach.dropdown.terminal",
      detail: service.terminalDesktopId || "no default terminal",
      available: service.terminalDesktopId !== "",
      url: ""
    })
    list.push({
      id: "system.agent",
      kind: "system",
      system: "agent",
      name: "Agent",
      icon: "utilities-terminal",
      desktopId: "",
      startupClass: "",
      expectedClass: "apach.dropdown.agent",
      detail: service.agentName || "no default agent",
      available: service.agentName !== "",
      url: ""
    })
    var files = service.entryForDesktop(service.filesDesktopId)
    list.push({
      id: "system.files",
      kind: "system",
      system: "files",
      name: files ? String(files.name || "Files") : "Files",
      icon: files ? String(files.icon || "system-file-manager") : "system-file-manager",
      desktopId: service.filesDesktopId,
      startupClass: files ? String(files.startupClass || "") : "",
      expectedClass: "",
      detail: service.filesDesktopId || "no default file manager",
      available: service.filesDesktopId !== "",
      url: ""
    })

    list = list.concat(discovered)
    list = list.concat(ordinary)

    for (var j = 0; j < list.length; j++) {
      var app = list[j]
      var cfg = service.config.apps[app.id]
      app.enabled = !!(cfg && cfg.enabled === true) && app.available
      app.key = cfg && typeof cfg.key === "string" ? cfg.key : ""
      app.shortcut = cfg && typeof cfg.shortcut === "string" ? cfg.shortcut : ""
      app.geometry = cfg && cfg.geometry ? cfg.geometry : null
      app.uses = cfg ? (Number(cfg.uses) || 0) : 0
      app.lastUsed = cfg ? (Number(cfg.lastUsed) || 0) : 0
      app.launchAtLogin = !!(cfg && cfg.launchAtLogin === true)
      app.state = service.stateFor(app.id)
      app.note = service.appStateNote(app)
      app.conflict = ""
    }

    // Resolve conflicts against the list being built, not the previous
    // catalog, so enabling or renaming an app updates every row at once.
    var keyMap = {}
    for (var k = 0; k < list.length; k++) {
      if (!list[k].enabled || !list[k].key) continue
      if (!keyMap[list[k].key]) keyMap[list[k].key] = []
      keyMap[list[k].key].push(list[k])
    }
    var reservedCommands = service.commandKeys()
    for (var c = 0; c < list.length; c++) {
      var row = list[c]
      if (!row.key) continue
      if (reservedCommands.indexOf(row.key) >= 0) {
        row.conflict = "Key " + row.key + " is a palette command"
        continue
      }
      var same = keyMap[row.key] || []
      var others = same.filter(function(other) { return other.id !== row.id })
      if (others.length > 0) {
        row.conflict = "Key " + row.key + " is also used by " +
          others.map(function(other) { return other.name }).join(", ")
      }
    }
    service.catalog = list
    service.ensureKeys()

    // Configured web apps that are no longer installed remain visible in the
    // manage list with their key, so a removed entry never invalidates or
    // silently rewrites the rest of the configuration.
    var known = {}
    for (var m = 0; m < list.length; m++) known[list[m].id] = true
    var missing = []
    for (var confId in service.config.apps) {
      if (known[confId] || confId.indexOf("system.") === 0) continue
      var conf = service.config.apps[confId]
      if (!conf || conf.enabled !== true) continue
      missing.push({
        id: confId,
        name: confId,
        key: String(conf.key || ""),
        url: String(conf.url || ""),
        enabled: true,
        state: "error",
        note: "Desktop entry not found",
        missing: true
      })
    }
    missing.sort(function(a, b) { return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1 })
    service.missingApps = missing
    service.syncBinds()
  }

  // Client and registry events change states, not the catalog structure.
  // Rebuild only the changed rows instead of re-reading every desktop entry,
  // re-sorting every list and revalidating every key on each window event.
  function refreshCatalogState() {
    var list = service.catalog
    var next = list
    for (var i = 0; i < list.length; i++) {
      var app = list[i]
      var state = service.stateFor(app.id)
      var note = service.appStateNote(app)
      if (state !== app.state || note !== app.note) {
        if (next === list) next = list.slice()
        next[i] = Object.assign({}, app, { state: state, note: note })
      }
    }
    if (next !== list) service.catalog = next
  }

  // The direct app shortcuts are Hyprland binds generated from the config.
  // dropdown.lua loads this file; writing it and reloading applies changes
  // without asking the user to edit bindings.lua.
  property bool bindsLoaded: false
  property string lastBindsContent: ""

  function bindsContent() {
    var entries = []
    for (var i = 0; i < service.catalog.length; i++) {
      var app = service.catalog[i]
      if (!app.enabled || !app.shortcut) continue
      var chord = Model.normalizeShortcut(app.shortcut)
      if (!chord) continue
      var parts = chord.split(" + ")
      var key = Model.luaShortcutKey(chord)
      var luaChord = parts.slice(0, parts.length - 1).concat([key]).join(" + ")
      entries.push({ id: String(app.id), name: String(app.name || app.id), shortcut: luaChord })
    }
    return Shortcuts.bindsFile(Shortcuts.sortEntries(entries), "omarchy-shell apach.dropdown")
  }

  function syncBinds() {
    if (!service.configLoaded || !service.bindsLoaded) return
    var content = service.bindsContent()
    if (content === service.lastBindsContent) return
    service.lastBindsContent = content
    bindsView.setText(content)
    // Apply the new chords now. This only reloads Hyprland on an actual
    // shortcut/enable/disable change, never on window events.
    Quickshell.execDetached(["hyprctl", "reload"])
  }

  // Hyprland re-runs its Lua config on `reload`. If the reload happened while
  // the generated file was mid-write (or before it existed), the direct binds
  // are missing even though the file is correct. Verify the live bind table
  // and reload again when a generated bind is absent.
  Process {
    id: bindsVerifyProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.handleBindsVerify(String(text || ""))
    }
  }

  function verifyBinds() {
    if (!service.bindsLoaded || !service.configLoaded) return
    var count = 0
    for (var i = 0; i < service.catalog.length; i++) {
      if (service.catalog[i].enabled && service.catalog[i].shortcut) count++
    }
    if (count === 0) return
    // `configreloaded` can fire in bursts; one verification every 3 s is enough.
    if (Date.now() - service.lastBindVerifyAt < 3000) return
    if (bindsVerifyProc.running) return
    service.lastBindVerifyAt = Date.now()
    bindsVerifyProc.running = true
  }

  function handleBindsVerify(raw) {
    var binds = []
    try { binds = JSON.parse(String(raw || "[]")) } catch (e) { binds = [] }
    if (!Array.isArray(binds)) return
    var entries = []
    for (var i = 0; i < service.catalog.length; i++) {
      if (service.catalog[i].enabled && service.catalog[i].shortcut)
        entries.push({ shortcut: service.catalog[i].shortcut })
    }
    if (Model.missingBinds(binds, entries).length > 0) {
      service.notify("Re-applying Dropdown direct shortcuts.")
      Quickshell.execDetached(["hyprctl", "reload"])
    }
  }

  FileView {
    id: bindsView
    path: service.bindsPath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      service.bindsLoaded = true
      service.lastBindsContent = text()
      service.syncBinds()
      service.verifyBinds()
    }
    onLoadFailed: {
      service.bindsLoaded = true
      service.lastBindsContent = ""
      service.syncBinds()
    }
  }

  // Enabled web apps always carry a free key. This is what makes a newly
  // checked app immediately usable without hiding a command.
  function ensureKeys() {
    var apps = service.catalog
    var enabled = {}
    for (var s = 0; s < apps.length; s++) {
      if (apps[s].kind === "system" && apps[s].enabled) enabled[apps[s].system] = true
    }
    var reserved = Model.reservedKeys(enabled, service.config.settings.commands)
    var used = []
    for (var i = 0; i < apps.length; i++)
      if (apps[i].enabled && apps[i].key) used.push(apps[i].key)
    var next = null
    for (var j = 0; j < apps.length; j++) {
      var app = apps[j]
      if (!app.enabled || app.key) continue
      var key = Model.firstFreeKey(app.name, used, reserved)
      if (!key) continue
      if (!next) next = Model.clone(service.config)
      if (!next.apps[app.id]) next.apps[app.id] = {}
      next.apps[app.id].key = key
      if (app.url) next.apps[app.id].url = app.url
      used.push(key)
    }
    if (next) {
      service.config = next
      service.scheduleConfigSave()
      service.rebuildCatalog()
    }
  }

  function refreshCatalog() {
    service.refreshSystemDefaults()
    service.rebuildCatalog()
    service.notify("Catalog refreshed.")
  }

  function maybeAutostart() {
    if (service.autostartChecked) return
    if (!service.configLoaded || !service.stateLoaded || !service.sessionId) return
    if (service.autostartSession === service.sessionId) return
    service.autostartChecked = true
    service.autostartSession = service.sessionId
    service.scheduleStateSave()
    var started = 0
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (!app.launchAtLogin) continue
      if (service.registry[app.id] || service.launching[app.id]) continue
      service.startLaunch(app.id, service.focusedContext(), true)
      started++
    }
    if (started > 0) service.notify("Started " + started + " starred application" + (started > 1 ? "s" : "") + " hidden.")
  }

  Timer {
    id: autostartTimer
    interval: 1500
    onTriggered: service.maybeAutostart()
  }

  // ---- Hyprland bridge -----------------------------------------------------

  property var dispatchQueue: []
  property var clientCallbacks: []
  property string lastClientsRaw: ""
  property bool orphanCheckDone: false
  property int lastBindVerifyAt: 0
  property bool clientRefreshAgain: false

  Process {
    id: clientsProc
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector {
      onStreamFinished: service.handleClients(String(text || ""))
    }
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: service.handleMonitors(String(text || ""))
    }
  }

  Process {
    id: dispatchProc
    property string currentExpression: ""
    stderr: StdioCollector {
      id: dispatchErr
      waitForEnd: true
    }
    onExited: function(exitCode, exitStatus) {
      if (Number(exitCode) !== 0) {
        var detail = String(dispatchErr.text || "").trim()
        service.noteHyprFailure(dispatchProc.currentExpression, detail, Number(exitCode))
      }
      service.pumpDispatch()
    }
  }

  // Surface a Hyprland dispatch failure instead of dropping it. The same
  // message is available through `status` and `doctor`.
  function noteHyprFailure(expression, detail, code) {
    var message = "Hyprland rejected " + String(expression || "a dispatch") +
      (detail ? ": " + detail : " (exit " + code + ")")
    service.hyprError = message
    service.lastHyprErrorAt = new Date().toISOString()
    console.warn("omarchy-dropdown: " + message)
  }

  function refreshClients(callback) {
    if (typeof callback === "function") service.clientCallbacks.push(callback)
    if (clientsProc.running) {
      service.clientRefreshAgain = true
      return
    }
    clientsProc.running = true
  }

  function handleClients(raw) {
    var text = String(raw || "")
    // Repeated polls often return identical payloads; skip the parse and the
    // catalog pass unless a launch is waiting for a new window.
    var hasLaunches = false
    for (var id in service.launching) hasLaunches = true
    if (text === service.lastClientsRaw && !hasLaunches) {
      service.adoptVisibleOrphans()
      service.drainClientCallbacks()
      return
    }
    service.lastClientsRaw = text
    service.clients = Model.parseClients(raw)
    service.reconcileRegistry()
    service.checkLaunches()
    service.refreshCatalogState()
    service.adoptVisibleOrphans()
    service.drainClientCallbacks()
  }

  function drainClientCallbacks() {
    var callbacks = service.clientCallbacks.slice()
    service.clientCallbacks = []
    for (var i = 0; i < callbacks.length; i++) callbacks[i]()
    if (service.clientRefreshAgain) {
      service.clientRefreshAgain = false
      service.refreshClients()
    }
  }

  function refreshMonitors(callback) {
    service.pendingMonitorCallback = callback
    if (monitorsProc.running) return
    monitorsProc.running = true
  }

  property var pendingMonitorCallback: null
  property bool monitorCheckPending: false

  function handleMonitors(raw) {
    service.monitors = Model.parseMonitors(raw)
    var callback = service.pendingMonitorCallback
    service.pendingMonitorCallback = null
    if (callback) callback()
    if (service.monitorCheckPending) {
      service.monitorCheckPending = false
      service.revalidateShownWindow()
    }
    service.adoptFocusedParked()
  }

  // Alt-Tab or a dock can activate the special workspace a window is parked
  // on. Adopt the window that actually owns focus as the visible dropdown
  // without moving it; Escape or focus loss then parks it and dismisses the
  // special. Moving it here would churn the shared special workspace.
  function adoptFocusedParked() {
    var active = Hyprland.activeToplevel
    if (!active) return
    var address = Model.normalizeAddress(active.address)
    if (!address) return
    for (var id in service.registry) {
      var entry = service.registry[id]
      if (Model.normalizeAddress(entry.address) !== address) continue
      var win = service.clientByAddress(address)
      if (!win || !Model.isManagedSpecial(win.workspace)) return
      if (!service.specialShown(win.workspace)) return
      if (entry.hidden !== true) {
        service.currentAppId = id
        service.enterEscapeMode()
        return
      }
      service.registryNext(id, Object.assign({}, entry, { hidden: false, special: win.workspace }))
      service.currentAppId = id
      service.lastAppId = id
      service.enterEscapeMode()
      service.scheduleStateSave()
      service.refreshCatalogState()
      return
    }
  }

  // Re-apply the dropdown geometry after a monitor is added/removed, a
  // resolution/scale changes, or the layout moves an output. Never focuses or
  // steals the window; it only keeps the visible dropdown on screen.
  function revalidateShownWindow() {
    var appId = service.currentAppId
    if (!appId) return
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!app || !entry || entry.hidden) return
    var win = service.clientByAddress(entry.address)
    if (!win) return
    var monitor = null
    for (var i = 0; i < service.monitors.length; i++)
      if (service.monitors[i].name === entry.previousMonitor) monitor = service.monitors[i]
    if (!monitor && service.monitors.length === 0) return
    var workspace = entry.previousWorkspace
    if (!monitor) {
      monitor = Model.monitorForName(service.monitors, "")
      workspace = monitor ? (monitor.specialWorkspace || monitor.activeWorkspace || win.workspace) : win.workspace
      if (monitor) {
        entry = Object.assign({}, entry, { previousMonitor: monitor.name, previousWorkspace: workspace })
        service.registryNext(appId, entry)
        service.moveWindowToWorkspace(win.address, workspace, false)
      }
    }
    var geometry = Model.geometryFor(monitor, service.config.settings.geometry, app.geometry)
    service.resizeWindow(win.address, geometry.width, geometry.height)
    service.placeWindow(win.address, geometry.x, geometry.y)
    service.scheduleStateSave()
  }

  function windowSelector(address) {
    return "address:" + Model.normalizeAddress(address)
  }

  function hypr(expression) {
    service.dispatchQueue.push(String(expression))
    service.pumpDispatch()
  }

  function pumpDispatch() {
    if (dispatchProc.running) return
    if (service.dispatchQueue.length === 0) return
    var next = service.dispatchQueue.shift()
    dispatchProc.currentExpression = next
    dispatchProc.command = ["hyprctl", "dispatch", next]
    dispatchProc.running = true
  }

  // Detached dispatches survive QML destruction (plugin disable, shell
  // restart), so parked windows can always be brought back.
  function hyprDetached(expression) {
    Quickshell.execDetached(["hyprctl", "dispatch", String(expression)])
  }

  // `hyprctl --batch` applies all expressions in one compositor pass. The
  // reveal path uses it so the window is never rendered between "park",
  // "resize", "move to workspace" and "move off screen".
  property var batchCallback: null

  Process {
    id: batchProc
    stderr: StdioCollector {
      id: batchErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (Number(exitCode) !== 0) {
        service.noteHyprFailure("a batched reveal", String(batchErr.text || "").trim(), Number(exitCode))
      }
      var callback = service.batchCallback
      service.batchCallback = null
      if (typeof callback === "function") callback()
    }
  }

  function hyprBatch(expressions, callback) {
    var parts = []
    for (var i = 0; i < (expressions || []).length; i++) {
      var expr = String(expressions[i] || "")
      if (expr) parts.push("dispatch " + expr)
    }
    if (parts.length === 0) return
    var command = ["hyprctl", "--batch", parts.join(";")]
    if (batchProc.running) {
      Quickshell.execDetached(command)
      if (typeof callback === "function") Qt.callLater(callback)
      return
    }
    service.batchCallback = typeof callback === "function" ? callback : null
    batchProc.command = command
    batchProc.running = true
  }

  function focusExpr(address) {
    return "hl.dsp.focus({ window = " + Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function focusWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return false
    if (!service.clientByAddress(addr)) return false
    service.hypr(service.focusExpr(addr))
    return true
  }

  function closeWindow(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return false
    service.hypr("hl.dsp.window.close({ window = " + Shortcuts.luaString(service.windowSelector(addr)) + " })")
    return true
  }

  // Expression builders. The dispatcher wrappers below are convenient for a
  // single command; the reveal path batches them so no intermediate geometry
  // is ever rendered on screen.
  function floatExpr(address) {
    return "hl.dsp.window.float({ action = \"enable\", window = " +
      Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function unfloatExpr(address) {
    return "hl.dsp.window.float({ action = \"disable\", window = " +
      Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function moveWorkspaceExpr(address, workspaceName, follow) {
    return "hl.dsp.window.move({ workspace = " + Shortcuts.luaString(workspaceName) +
      ", follow = " + (follow === true ? "true" : "false") +
      ", window = " + Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function resizeExpr(address, width, height) {
    return "hl.dsp.window.resize({ x = " + Math.round(width) + ", y = " + Math.round(height) +
      ", relative = false, window = " + Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function placeExpr(address, x, y) {
    return "hl.dsp.window.move({ x = " + Math.round(x) + ", y = " + Math.round(y) +
      ", relative = false, window = " + Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function unsetFullscreenExpr(address, win) {
    if (!win || win.fullscreen === 0) return ""
    return "hl.dsp.window.fullscreen({ mode = \"fullscreen\", action = \"unset\", window = " +
      Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function zOrderTopExpr(address) {
    return "hl.dsp.window.alter_zorder({ mode = \"top\", window = " +
      Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function opacityExpr(address, value) {
    return "hl.dsp.window.set_prop({ window = " + Shortcuts.luaString(service.windowSelector(address)) +
      ", prop = \"opacity\", value = \"" + String(value) + "\" })"
  }

  function restoreWindowOpacity(address) {
    if (!Model.validAddress(address)) return
    service.hypr(service.opacityExpr(address, "1"))
  }

  function floatWindow(address) {
    service.hypr(service.floatExpr(address))
  }

  function unfloatWindow(address) {
    service.hypr(service.unfloatExpr(address))
  }

  function moveWindowToWorkspace(address, workspaceName, follow) {
    service.hypr(service.moveWorkspaceExpr(address, workspaceName, follow))
  }

  function resizeWindow(address, width, height) {
    service.hypr(service.resizeExpr(address, width, height))
  }

  function placeWindow(address, x, y) {
    service.hypr(service.placeExpr(address, x, y))
  }

  function unsetFullscreen(address, win) {
    var expr = service.unsetFullscreenExpr(address, win)
    if (expr) service.hypr(expr)
  }

  function zOrderTop(address) {
    service.hypr(service.zOrderTopExpr(address))
  }

  // Parked windows carry a stable tag so other launchers/docks (e.g. Quay)
  // can filter them out of their app lists. Remove it when the window is
  // revealed, released or restored.
  function tagExpr(address, hidden) {
    return "hl.dsp.window.tag({ tag = " +
      Shortcuts.luaString((hidden ? "+" : "-") + "dropdown-hidden") +
      ", window = " + Shortcuts.luaString(service.windowSelector(address)) + " })"
  }

  function tagWindow(address, hidden) {
    if (!Model.validAddress(address)) return
    service.hypr(service.tagExpr(address, hidden))
  }

  // ---- Client-window reveal ------------------------------------------------
  // The app window is placed at its final geometry (invisible). A Quickshell
  // shell with the same geometry slides in from the configured edge, then the
  // app fades in beneath it and the shell fades out. The compositor animates
  // the shell, so the motion is smooth without touching the app window.

  property var fadeQueue: null
  property string fadeAddress: ""
  property string shellPending: ""
  property bool shellArrivedFlag: false

  // Reveal-shell state read by the overlay through plain property bindings.
  // No signal needed: bindings are the one mechanism that always propagates.
  property bool shellActive: false
  property real shellOpacity: 1
  property string shellScreen: ""
  property real shellX: 0
  property real shellY: 0
  property int shellW: 320
  property int shellH: 240
  property string shellName: ""
  property string shellIcon: ""
  property int shellDuration: 180

  Timer {
    id: fadeTimer
    interval: 40
    repeat: true
    onTriggered: {
      if (!service.fadeQueue || service.fadeQueue.length === 0) {
        if (service.fadeAddress) service.hypr(service.opacityExpr(service.fadeAddress, "1"))
        service.fadeAddress = ""
        fadeTimer.stop()
        return
      }
      service.hypr(service.opacityExpr(service.fadeAddress, service.fadeQueue.shift()))
    }
  }

  function startFade(address) {
    if (!address) return
    service.fadeAddress = address
    service.fadeQueue = ["0.25", "0.5", "0.75", "1"]
    fadeTimer.restart()
  }

  function cancelFade() {
    if (service.fadeAddress) service.restoreWindowOpacity(service.fadeAddress)
    service.fadeAddress = ""
    service.fadeQueue = null
    fadeTimer.stop()
  }

  Timer {
    id: shellArriveTimeout
    interval: 500
    onTriggered: {
      // Overlay missing or reloading: reveal the window directly.
      if (service.shellPending && !service.shellArrivedFlag) {
        service.startFade(service.shellPending)
        service.shellOpacity = 0
        shellHideTimer.restart()
      }
    }
  }

  Timer {
    id: shellDismissTimer
    interval: 130
    onTriggered: {
      service.shellOpacity = 0
      shellHideTimer.restart()
    }
  }

  Timer {
    id: shellHideTimer
    interval: 150
    onTriggered: {
      service.shellActive = false
      service.shellOpacity = 1
      service.shellPending = ""
    }
  }

  function requestShellSlide(address, geometry, monitor, edge, duration, app) {
    service.cancelSlide()
    if (!monitor || !geometry) {
      service.startFade(address)
      return
    }
    var start = Model.slideStart(monitor, geometry, edge, 0)
    service.shellPending = address
    service.shellArrivedFlag = false
    service.shellName = app ? String(app.name || "") : ""
    service.shellIcon = app ? String(app.icon || "") : ""
    service.shellScreen = String(monitor.name || "")
    service.shellW = Math.round(geometry.width)
    service.shellH = Math.round(geometry.height)
    service.shellDuration = Math.max(120, Number(duration || 180))
    service.shellOpacity = 1
    // Position at the start while inactive (no animation), activate, wait one
    // compositor frame so the card is painted at the start, then move to the
    // target. Without that frame, a reveal triggered while nothing else was
    // rendering (direct shortcut) painted the card directly at the target.
    service.shellX = Math.round(start.x - monitor.x)
    service.shellY = Math.round(start.y - monitor.y)
    service.shellActive = false
    service.shellActive = true
    shellMoveTimer.target = {
      x: Math.round(geometry.x - monitor.x),
      y: Math.round(geometry.y - monitor.y)
    }
    shellMoveTimer.restart()
    // Arrival is driven by a service timer, and the fallback below guarantees
    // the window fades in even if the shell never rendered.
    shellArriveTimer.interval = service.shellDuration + 100
    shellArriveTimer.restart()
    shellArriveTimeout.restart()
  }

  Timer {
    id: shellMoveTimer
    interval: 30
    property var target: null
    onTriggered: {
      var move = shellMoveTimer.target
      shellMoveTimer.target = null
      if (!service.shellActive || !move) return
      service.shellX = move.x
      service.shellY = move.y
    }
  }

  Timer {
    id: shellArriveTimer
    onTriggered: {
      if (service.shellPending) service.shellArrived(service.shellPending)
    }
  }

  // Called by the overlay once the shell reached the final geometry.
  function shellArrived(address) {
    if (!service.shellPending || service.shellPending !== String(address || "")) return
    service.shellArrivedFlag = true
    shellArriveTimeout.stop()
    service.startFade(address)
    service.focusWindow(address)
    shellDismissTimer.restart()
  }

  function cancelSlide() {
    service.cancelFade()
    service.shellPending = ""
    service.shellArrivedFlag = false
    shellArriveTimeout.stop()
    shellArriveTimer.stop()
    shellDismissTimer.stop()
    shellHideTimer.stop()
    shellMoveTimer.stop()
    shellMoveTimer.target = null
    service.shellActive = false
    service.shellOpacity = 1
  }

  function revealMotionEnabled() {
    return service.config.settings.animations.reducedMotion !== true
  }

  // ---- Window registry -----------------------------------------------------

  function registryNext(appId, entry) {
    var next = {}
    for (var id in service.registry) next[id] = service.registry[id]
    if (entry === null) delete next[appId]
    else next[appId] = entry
    service.registry = next
  }

  function forgetApp(appId) {
    service.cancelSlide()
    service.leaveEscapeMode()
    if (!service.registry[appId]) return
    if (Model.validAddress(service.registry[appId].address))
      service.restoreWindowOpacity(service.registry[appId].address)
    service.registryNext(appId, null)
    if (service.currentAppId === appId) service.currentAppId = ""
    if (service.lastAppId === appId) service.lastAppId = ""
    service.scheduleStateSave()
    service.refreshCatalogState()
  }

  // Once, after config and state are loaded: adopt a visible terminal/agent
  // window that survived a plugin reload but is not in the registry.
  function adoptVisibleOrphans() {
    if (!service.configLoaded || !service.stateLoaded || service.orphanCheckDone) return
    service.orphanCheckDone = true
    var changed = false
    for (var i = 0; i < service.catalog.length; i++) {
      var app = service.catalog[i]
      if (!app.enabled || (app.system !== "terminal" && app.system !== "agent")) continue
      var orphan = service.adoptableOrphan(app)
      if (!orphan) continue
      var special = service.availableSpecial(app.id)
      service.moveWindowToWorkspace(orphan.address, special, false)
      service.tagWindow(orphan.address, true)
      if (service.registry[app.id]) {
        var entry = service.registry[app.id]
        service.registryNext(app.id, Object.assign({}, entry, {
          address: orphan.address,
          class: orphan.class,
          pid: orphan.pid,
          hidden: true
        }))
      } else {
        service.registryNext(app.id, {
          address: orphan.address,
          class: orphan.class,
          pid: orphan.pid,
          hidden: true,
          special: special,
          previousWorkspace: orphan.workspace,
          previousMonitor: service.monitorNameForId(orphan.monitor) || "",
          previousFocus: "",
          since: Date.now()
        })
      }
      service.lastAppId = app.id
      service.notify(app.name + " re-adopted.")
      changed = true
    }
    if (changed) {
      service.refreshCatalogState()
    }
  }

  function reconcileRegistry() {
    var changed = false
    var next = {}
    for (var id in service.registry) {
      var entry = service.registry[id]
      var win = service.clientByAddress(entry.address)
      if (!win) {
        changed = true
        if (service.currentAppId === id) {
          service.currentAppId = ""
          service.leaveEscapeMode()
        }
        if (service.lastAppId === id) service.lastAppId = ""
        continue
      }
      if (entry.class && entry.class.toLowerCase() !== String(win.class || "").toLowerCase()) {
        // Never trust a stale address after a compositor restart.
        changed = true
        if (service.currentAppId === id) {
          service.currentAppId = ""
          service.leaveEscapeMode()
        }
        if (service.lastAppId === id) service.lastAppId = ""
        continue
      }
      // Any managed special workspace is parked, whatever its exact name.
      var onSpecial = Model.isManagedSpecial(win.workspace)
      var hidden = onSpecial
      if (entry.hidden !== hidden || (onSpecial && entry.special !== win.workspace)) {
        entry = Object.assign({}, entry, {
          hidden: hidden,
          special: onSpecial ? win.workspace : entry.special
        })
        changed = true
      }
      next[id] = entry
    }
    if (changed) {
      service.registry = next
      service.scheduleStateSave()
    }
    service.recoverOrphans()
    service.recoverFromSaved()
    service.checkCloseWatches()
  }

  function recoverOrphans() {
    if (!service.configLoaded) return
    var managed = {}
    for (var id in service.registry) {
      var entry = service.registry[id]
      managed[String(entry.address).toLowerCase()] = true
      managed[String(entry.special)] = true
    }
    for (var i = 0; i < service.clients.length; i++) {
      var win = service.clients[i]
      if (service.released[Model.normalizeAddress(win.address)]) continue
      if (!Model.isManagedSpecial(win.workspace)) continue
      if (managed[String(win.address).toLowerCase()]) continue
      var app = null
      for (var j = 0; j < service.catalog.length; j++) {
        if ("special:" + Model.specialWorkspace(service.catalog[j].id) === win.workspace) { app = service.catalog[j]; break }
      }
      // Shared unnamed special: match by window class/title instead.
      if (!app && (win.workspace === "special" || win.workspace === "special:special")) {
        for (var k = 0; k < service.catalog.length; k++) {
          var candidate = service.catalog[k]
          if (!candidate.enabled || service.registry[candidate.id]) continue
          if (Model.windowMatches(candidate, win)) { app = candidate; break }
        }
      }
      if (app && app.enabled && !service.registry[app.id] && !service.launching[app.id]) {
        // A shell crash left a parked window behind: adopt it as hidden so the
        // user can call it back instead of it being unreachable.
        var adopted = {
          address: win.address,
          class: win.class,
          pid: win.pid,
          hidden: true,
          special: win.workspace,
          previousWorkspace: win.workspace,
          previousMonitor: service.monitors.length > 0 ? service.monitors[0].name : "",
          previousFocus: "",
          since: Date.now()
        }
        service.registryNext(app.id, adopted)
        service.tagWindow(win.address, true)
        service.lastAppId = app.id
        service.scheduleStateSave()
        managed[String(win.address).toLowerCase()] = true
        continue
      }
      // Unknown or disabled app: put the window back on a real workspace so no
      // session is ever trapped in a special workspace.
      var target = service.workspaceForWindow(win)
      service.hyprDetached("hl.dsp.window.move({ workspace = " + Shortcuts.luaString(target) +
        ", follow = false, window = " + Shortcuts.luaString(service.windowSelector(win.address)) + " })")
    }
  }

  function recoverFromSaved() {
    if (!service.stateLoaded || !service.configLoaded) return
    var saved = service.savedRegistry || {}
    var changed = false
    for (var id in saved) {
      if (service.registry[id]) continue
      var app = service.findApp(id)
      if (!app || !app.enabled) continue
      var win = service.clientByAddress(saved[id].address)
      if (!win) continue
      if (service.released[Model.normalizeAddress(win.address)]) continue
      if (saved[id].class && saved[id].class.toLowerCase() !== String(win.class).toLowerCase()) continue
      var hidden = Model.isManagedSpecial(win.workspace)
      var parkTarget = hidden ? win.workspace : service.availableSpecial(id)
      if (!hidden) {
        // A window that was visible when the session ended must not pop back
        // up at startup: park it, only an explicit recall shows it again.
        service.moveWindowToWorkspace(win.address, parkTarget, false)
        hidden = true
      }
      service.registryNext(id, Object.assign({}, saved[id], { hidden: hidden, special: parkTarget }))
      service.tagWindow(win.address, true)
      // A crash during a reveal must not leave the window transparent.
      service.restoreWindowOpacity(win.address)
      service.lastAppId = id
      changed = true
    }
    if (changed) {
      service.savedRegistry = {}
      service.refreshCatalogState()
    }
  }

  function workspaceForWindow(win) {
    var monitor = null
    for (var i = 0; i < service.monitors.length; i++)
      if (service.monitors[i].id === win.monitor) monitor = service.monitors[i]
    if (!monitor) for (var j = 0; j < service.monitors.length; j++)
      if (service.monitors[j].focused) monitor = service.monitors[j]
    if (monitor) {
      if (monitor.specialWorkspace) return monitor.specialWorkspace
      if (monitor.activeWorkspace) return monitor.activeWorkspace
    }
    return "1"
  }

  // ---- Launching -----------------------------------------------------------

  function startLaunch(appId, context, hiddenOnStart) {
    var app = service.findApp(appId)
    if (!app) return
    if (!app.available) {
      service.failLaunch(appId, app.note || "This application is not configured.")
      return
    }
    var cmd = service.launchCommand(app)
    if (!cmd || cmd.argv.length === 0) {
      service.failLaunch(appId, "No launch command could be built for " + app.name + ".")
      return
    }
    var snapshot = service.clients.map(function(win) { return String(win.address).toLowerCase() })
    var state = {
      startedAt: Date.now(),
      snapshot: snapshot,
      pid: 0,
      context: context || null,
      hiddenOnStart: hiddenOnStart === true
    }
    var next = {}
    for (var id in service.launching) next[id] = service.launching[id]
    next[appId] = state
    service.launching = next
    service.setError(appId, "")
    // Launch detached: the terminal that carries the agent (or the default
    // terminal) must outlive a plugin reload, and a Process child would be
    // terminated with the service. The unique app-id class is how the new
    // window is recognised.
    // execDetached is void: the window appearing is the success signal.
    service.launchViaHypr(cmd, appId)
    launchWatchTimer.restart()
    service.notify("Launching " + app.name + "…")
    service.refreshCatalogState()
  }

  Timer {
    id: launchWatchTimer
    interval: 300
    repeat: true
    running: false
    onTriggered: service.refreshClients()
  }

  function launchCommand(app) {
    if (app.kind === "webapp" || app.kind === "app") {
      return { argv: ["uwsm-app", "--", "gtk-launch", Model.desktopId(app.desktopId || app.id)], cwd: "" }
    }
    if (app.system === "terminal") {
      return { argv: ["setsid", "xdg-terminal-exec", "--app-id=apach.dropdown.terminal"], cwd: "" }
    }
    if (app.system === "agent") {
      return {
        argv: ["setsid", "xdg-terminal-exec", "--app-id=apach.dropdown.agent", "--dir=" + service.agentWorkDir,
          "-e", "omarchy-agent", "--inline"],
        cwd: service.agentWorkDir
      }
    }
    if (app.system === "files") {
      return { argv: ["uwsm-app", "--", "gtk-launch", Model.desktopId(app.desktopId)], cwd: "" }
    }
    return null
  }

  function shellQuote(value) {
    return "'" + String(value || "").replace(/'/g, "'\\''") + "'"
  }

  // Launch through Hyprland with window rules: the new window maps directly
  // on its parked special workspace, floating and transparent. It therefore
  // never appears at its default tiled position before Dropdown adopts it.
  // A named special workspace can only be created by this Hyprland build at
  // window-map time. If the preferred one does not exist yet (e.g. an app that
  // was not launched through Dropdown), park on the unnamed special instead:
  // it is created on demand and always accepts a window move.
  function availableSpecial(appId) {
    var name = Model.specialWorkspace(appId)
    var full = "special:" + name
    var list = Hyprland.workspaces && Hyprland.workspaces.values ? Hyprland.workspaces.values : []
    for (var i = 0; i < list.length; i++) {
      if (String(list[i].name || "") === full) return name
    }
    return "special"
  }

  // Is a parking special workspace currently shown on some monitor? A parked
  // window can be revealed by Alt-Tab or a dock, which activates its special.
  function specialShown(name) {
    var value = String(name || "")
    if (!value) return false
    var full = value.indexOf("special:") === 0 ? value : "special:" + value
    for (var i = 0; i < service.monitors.length; i++) {
      var shown = String(service.monitors[i].specialWorkspace || "")
      if (shown && (shown === full || shown === value)) return true
    }
    return false
  }

  function launchViaHypr(cmd, appId) {
    if (!cmd || !cmd.argv || cmd.argv.length === 0) return false
    var command = cmd.argv.map(function(part) { return service.shellQuote(part) }).join(" ")
    if (cmd.cwd) command = "cd " + service.shellQuote(cmd.cwd) + " && " + command
    var special = service.availableSpecial(appId)
    service.hyprDetached("hl.dsp.exec_cmd(" + Shortcuts.luaString(command) + ", { workspace = " +
      Shortcuts.luaString("special:" + special + " silent") +
      ", float = true, opacity = \"0\" })")
    return true
  }

  function checkLaunches() {
    var hasLaunches = false
    for (var id in service.launching) hasLaunches = true
    if (!hasLaunches) {
      launchWatchTimer.stop()
      return
    }
    var next = {}
    var timeout = []
    for (var appId in service.launching) {
      var state = service.launching[appId]
      var app = service.findApp(appId)
      if (!app) { timeout.push({ id: appId, state: state }); continue }
      var found = service.findNewWindow(app, state)
      if (!found) found = service.findParkedWindow(app)
      if (found) {
        service.finishLaunch(appId, found, state)
      } else if (Date.now() - state.startedAt > service.launchTimeoutMs) {
        // One short grace period: a slow app can map its window exactly at the
        // timeout, and losing that race used to report a false failure.
        if (!state.grace) {
          state.grace = true
          state.graceUntil = Date.now() + 900
          next[appId] = state
        } else if (Date.now() < state.graceUntil) {
          next[appId] = state
        } else {
          timeout.push({ id: appId, state: state })
        }
      } else {
        next[appId] = state
      }
    }
    service.launching = next
    for (var i = 0; i < timeout.length; i++) service.handleLaunchTimeout(timeout[i].id)
    if (Object.keys(next).length > 0) launchWatchTimer.start()
    else launchWatchTimer.stop()
  }

  function findNewWindow(app, state) {
    var before = {}
    for (var i = 0; i < state.snapshot.length; i++) before[state.snapshot[i]] = true
    var best = null
    for (var j = 0; j < service.clients.length; j++) {
      var win = service.clients[j]
      if (before[String(win.address).toLowerCase()]) continue
      if (service.addressManaged(win.address)) continue
      if (!Model.windowMatches(app, win)) continue
      if (app.pid && Number(win.pid) === Number(app.pid)) return win
      best = best || win
    }
    return best
  }

  function addressManaged(address) {
    var want = Model.normalizeAddress(address)
    if (!want) return false
    for (var id in service.registry)
      if (Model.normalizeAddress(service.registry[id].address) === want) return true
    return false
  }

  function finishLaunch(appId, win, state) {
    var app = service.findApp(appId)
    if (!app) return
    if (!app.enabled || app.state === "error") {
      // Disabled while it was starting: leave the new window as an ordinary
      // window on the target workspace.
      var target = state.context && state.context.workspace ? state.context.workspace : service.workspaceForWindow(win)
      service.hyprDetached("hl.dsp.window.move({ workspace = " + Shortcuts.luaString(target) +
        ", follow = false, window = " + Shortcuts.luaString(service.windowSelector(win.address)) + " })")
      return
    }
    var entry = {
      address: win.address,
      class: win.class,
      pid: win.pid,
      hidden: false,
      special: service.availableSpecial(appId),
      previousWorkspace: state.context ? state.context.workspace : "",
      previousMonitor: state.context ? state.context.monitor : "",
      previousFocus: "",
      since: Date.now()
    }
    service.registryNext(appId, entry)
    service.setError(appId, "")
    if (state.hiddenOnStart) {
      service.parkApp(appId, false)
      return
    }
    service.revealApp(appId, state.context, win, true)
  }

  function handleLaunchTimeout(appId) {
    var app = service.findApp(appId)
    if (!app) return
    var existing = service.findUnmanagedWindow(app)
    if (existing) {
      service.setAdoptable(appId, existing.address)
      service.failLaunch(appId, app.name + " is already open outside Dropdown. Open Manage and press o to adopt it.")
    } else {
      var expected = app.expectedClass || app.desktopId || app.id
      service.failLaunch(appId, "No window appeared for " + app.name +
        " within " + Math.round(service.launchTimeoutMs / 1000) + " s (expected class " +
        expected + "). Run `omarchy-shell apach.dropdown doctor` for details.")
    }
  }

  // A matching window already parked on a managed special workspace. Used
  // when a single-instance app (Electron/Flatpak) reopens its existing window
  // instead of mapping a new one: the address was already in the pre-launch
  // snapshot, so findNewWindow ignores it but it is exactly what we want.
  function managedAppForAddress(address) {
    var want = Model.normalizeAddress(address)
    if (!want) return ""
    for (var id in service.registry) {
      if (Model.normalizeAddress(service.registry[id].address) === want) return id
    }
    return ""
  }

  function findParkedWindow(app) {
    for (var i = 0; i < service.clients.length; i++) {
      var win = service.clients[i]
      // A window already registered to a *different* app must never be
      // adopted. The same app's entry may be stale (address reuse after a
      // relaunch), which is exactly the case we need to recover.
      var owner = service.managedAppForAddress(win.address)
      if (owner && owner !== app.id) continue
      if (!Model.isManagedSpecial(win.workspace)) continue
      if (!Model.windowMatches(app, win)) continue
      return win
    }
    return null
  }

  function findUnmanagedWindow(app) {
    for (var i = 0; i < service.clients.length; i++) {
      var win = service.clients[i]
      if (service.addressManaged(win.address)) continue
      if (Model.windowMatches(app, win)) return win
    }
    return null
  }

  // A terminal/agent window with a plugin class that is visible but not in the
  // registry (e.g. left over from a plugin reload). These classes are unique
  // to Dropdown, so adopting them is safe and avoids duplicate kitty windows.
  function adoptableOrphan(app) {
    if (!app) return null
    if (app.system !== "terminal" && app.system !== "agent") return null
    var win = service.findUnmanagedWindow(app)
    if (!win) return null
    if (Model.isManagedSpecial(win.workspace)) return null
    if (service.released[Model.normalizeAddress(win.address)]) return null
    return win
  }

  function failLaunch(appId, message) {
    var next = {}
    for (var id in service.launching) if (id !== appId) next[id] = service.launching[id]
    service.launching = next
    service.setError(appId, message)
    service.notify(message)
    service.refreshCatalogState()
  }

  function setError(appId, message) {
    var next = {}
    for (var id in service.errors) next[id] = service.errors[id]
    if (message) next[appId] = String(message)
    else delete next[appId]
    service.errors = next
  }

  function setAdoptable(appId, address) {
    var next = {}
    for (var id in service.adoptable) next[id] = service.adoptable[id]
    if (address) next[appId] = String(address)
    else delete next[appId]
    service.adoptable = next
  }

  // ---- Showing, hiding, closing -------------------------------------------

  function configuredScreen() {
    var chosen = String(service.config.settings.screen || "auto")
    if (!chosen || chosen === "auto") return ""
    for (var i = 0; i < service.monitors.length; i++)
      if (service.monitors[i].name === chosen) return chosen
    return ""
  }

  // Live Hyprland monitor by name. The cached `monitors` array is only for
  // geometry; its active workspace can lag behind workspace switches.
  function liveMonitor(name) {
    var wanted = String(name || "")
    var list = Hyprland.monitors && Hyprland.monitors.values ? Hyprland.monitors.values : []
    if (!wanted) return Hyprland.focusedMonitor
    for (var i = 0; i < list.length; i++)
      if (String(list[i].name || "") === wanted) return list[i]
    return null
  }

  function focusedContext(preferredMonitor) {
    var monitorName = String(preferredMonitor || "")
    if (!monitorName && Hyprland.focusedMonitor) monitorName = String(Hyprland.focusedMonitor.name || "")
    var monitor = service.liveMonitor(monitorName)
    var special = monitor ? monitor.specialWorkspace : null
    var ws = special && special.name ? special : (monitor ? monitor.activeWorkspace : null)
    var workspace = ws ? String(ws.name || "") : ""
    if (!workspace && Hyprland.focusedWorkspace) workspace = String(Hyprland.focusedWorkspace.name || "")
    return { monitor: monitorName || (monitor ? String(monitor.name || "") : ""), workspace: workspace }
  }

  function toggleApp(appId, context, ignoreConflict) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    if (!app.enabled) return { ok: false, message: app.name + " is not managed by Dropdown." }
    // A conflicting key blocks key dispatch, never an explicit open by id
    // (Enter, a click, or a preview card).
    if (app.conflict && ignoreConflict !== true) return { ok: false, message: app.conflict + "." }
    var entry = service.registry[appId]
    var win = entry ? service.clientByAddress(entry.address) : null
    if (entry && win) {
      var target = service.resolveContext(context || service.focusedContext())
      var sameWorkspace = String(win.workspace || "") === String(target.workspace || "")
      var sameMonitor = service.monitorNameForId(win.monitor) === String(target.monitor || "")
      // A window that is visible on another workspace/monitor is brought to
      // the requested screen's current workspace; only a window already
      // there toggles to hidden.
      if (entry.hidden) {
        var orphan = service.adoptableOrphan(app)
        if (orphan) {
          service.registryNext(appId, Object.assign({}, entry, {
            address: orphan.address,
            class: orphan.class,
            pid: orphan.pid,
            hidden: false
          }))
          service.setError(appId, "")
          service.setAdoptable(appId, "")
        }
      }
      if (entry.hidden || !sameWorkspace || !sameMonitor) {
        service.revealApp(appId, target)
      } else {
        service.parkApp(appId, true)
      }
      return { ok: true, appId: appId }
    }
    if (entry && !win) service.forgetApp(appId)
    if (service.launching[appId]) return { ok: false, message: app.name + " is still launching." }
    var ctx = service.resolveContext(context || service.focusedContext())
    // Single-instance apps (Electron/Flatpak) may already have a window even
    // when the registry lost it. Adopt and reveal it instead of launching a
    // second instance that never maps.
    service.refreshClients(function() {
      var existing = service.findUnmanagedWindow(app)
      if (existing && !service.released[Model.normalizeAddress(existing.address)]) {
        service.registryNext(appId, {
          address: existing.address,
          class: existing.class,
          pid: existing.pid,
          hidden: false,
          special: service.availableSpecial(appId),
          previousWorkspace: ctx.workspace,
          previousMonitor: ctx.monitor,
          previousFocus: "",
          since: Date.now()
        })
        service.revealApp(appId, ctx)
        return
      }
      service.refreshMonitors(function() {
        service.startLaunch(appId, ctx)
      })
    })
    return { ok: true, appId: appId }
  }

  // Turn a monitor name + workspace name into the concrete workspace the new
  // dropdown should land on. If the monitor shows a special workspace, that is
  // the workspace the user is looking at.
  function resolveContext(context) {
    var ctx = context || {}
    var fixed = service.configuredScreen()
    var targetName = fixed || String(ctx.monitor || "")
    var workspace = String(ctx.workspace || "")
    var monitor = service.liveMonitor(targetName)
    if (monitor) {
      // A pinned screen always uses that screen's current workspace, never a
      // stale workspace captured before a workspace switch.
      if (fixed || !workspace) {
        var special = monitor.specialWorkspace
        var ws = special && special.name ? special : monitor.activeWorkspace
        if (ws && ws.name) workspace = String(ws.name)
      }
      ctx.monitor = String(monitor.name || targetName)
    } else {
      var cached = Model.monitorForName(service.monitors, targetName)
      if (cached) {
        if (fixed || !workspace)
          workspace = String(cached.specialWorkspace || cached.activeWorkspace || workspace)
        ctx.monitor = String(cached.name || targetName)
      }
    }
    if (!workspace) workspace = "1"
    return { monitor: ctx.monitor || "", workspace: workspace }
  }

  function revealApp(appId, context, knownWindow, fresh) {
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!app || !entry) return
    var win = knownWindow || service.clientByAddress(entry.address)
    if (!win) { service.forgetApp(appId); return }
    var ctx = service.resolveContext(context || {
      monitor: entry.previousMonitor || "",
      workspace: entry.previousWorkspace || ""
    })
    // Only one managed dropdown is visible at a time, globally.
    if (service.currentAppId && service.currentAppId !== appId) {
      service.parkApp(service.currentAppId, false)
    }
    // Reconcile any other managed window that is visible but was not recorded
    // as current (manual workspace move, shell restart, race).
    for (var id in service.registry) {
      if (id === appId) continue
      var other = service.registry[id]
      var otherWin = service.clientByAddress(other.address)
      if (!otherWin || other.hidden) continue
      if (otherWin.workspace === other.special) continue
      service.parkApp(id, false)
    }
    var active = Hyprland.activeToplevel
    var activeAddress = active ? Model.normalizeAddress(active.address) : ""
    var previousFocus = Model.normalizeAddress(entry.previousFocus)
    if (activeAddress && activeAddress !== Model.normalizeAddress(win.address)
        && !service.addressManaged(activeAddress)) previousFocus = activeAddress

    var geometry = Model.geometryFor(
      Model.monitorForName(service.monitors, ctx.monitor),
      service.config.settings.geometry,
      app.geometry)

    var updated = Object.assign({}, entry, {
      address: win.address,
      class: win.class,
      pid: win.pid,
      hidden: false,
      previousWorkspace: ctx.workspace,
      previousMonitor: ctx.monitor,
      previousFocus: previousFocus,
      lastShownAt: Date.now()
    })
    service.registryNext(appId, updated)
    service.currentAppId = appId
    service.lastAppId = appId
    service.recordUse(appId)
    autoHideTimer.stop()
    service.setError(appId, "")
    service.setAdoptable(appId, "")

    // Bring back dialogs that were parked with the main window.
    var siblings = entry.siblings || []
    for (var i = 0; i < service.clients.length; i++) {
      var sibling = service.clients[i]
      if (String(sibling.address).toLowerCase() === String(win.address).toLowerCase()) continue
      if (!service.isSibling(win, sibling)) continue
      if (sibling.workspace !== entry.special) continue
      siblings.push(sibling.address)
    }
    // A single batch: leave fullscreen, float, resize, move to the target
    // workspace and place at the final geometry. The window then fades in.
    var freshWindow = fresh === true
    var fade = service.revealMotionEnabled()
    var batch = []
    var fs = service.unsetFullscreenExpr(win.address, win)
    if (fs) batch.push(fs)
    batch.push(service.floatExpr(win.address))
    // Invisible during placement; a fresh window also stays invisible while
    // it paints, so no grey/white block is shown.
    if (fade) batch.push(service.opacityExpr(win.address, "0"))
    batch.push(service.resizeExpr(win.address, geometry.width, geometry.height))
    batch.push(service.moveWorkspaceExpr(win.address, ctx.workspace, false))
    batch.push(service.placeExpr(win.address, geometry.x, geometry.y))
    batch.push(service.zOrderTopExpr(win.address))
    batch.push(service.focusExpr(win.address))
    for (var j = 0; j < siblings.length; j++) {
      var sib = service.clientByAddress(siblings[j])
      if (sib && sib.workspace === entry.special) batch.push(service.moveWorkspaceExpr(sib.address, ctx.workspace, false))
    }
    service.hyprBatch(batch, fade ? function() {
      if (!service.clientByAddress(win.address)) return
      service.requestShellSlide(
        win.address, geometry,
        Model.monitorForName(service.monitors, ctx.monitor),
        geometry.edge,
        service.config.settings.animations.durationMs,
        app)
    } : null)
    service.tagWindow(win.address, false)
    for (var t = 0; t < siblings.length; t++) service.tagWindow(siblings[t], false)
    // While the palette is open it owns Escape and re-arms the submap when it
    // closes. Switching tabs from the palette must not steal that focus.
    if (!service.paletteOpen) service.enterEscapeMode()
    service.notify(app.name + " shown.")
    service.scheduleStateSave()
    service.refreshCatalogState()
  }

  function isSibling(mainWindow, other) {
    if (!mainWindow || !other) return false
    if (Number(mainWindow.pid) !== Number(other.pid)) return false
    var cls = String(mainWindow.class || "").toLowerCase()
    return cls !== "" && String(other.class || "").toLowerCase() === cls
  }

  function parkApp(appId, restoreFocus) {
    autoHideTimer.stop()
    service.leaveEscapeMode()
    service.cancelSlide()
    var entry = service.registry[appId]
    if (!entry) return
    var win = service.clientByAddress(entry.address)
    if (!win) { service.forgetApp(appId); return }
    // Never leave a window transparent after an interrupted reveal.
    service.restoreWindowOpacity(win.address)
    var app = service.findApp(appId)
    var special = service.availableSpecial(appId)
    var siblings = []
    // Dialog windows of a dedicated instance share its class and pid. Never
    // sweep every window of a file manager, whose class is shared with
    // ordinary windows.
    if (app && (app.kind === "webapp" || app.system === "terminal" || app.system === "agent")) {
      for (var i = 0; i < service.clients.length; i++) {
        var other = service.clients[i]
        if (other.address === win.address) continue
        if (!service.isSibling(win, other)) continue
        if (other.workspace !== win.workspace) continue
        siblings.push(other.address)
      }
    }
    var specialWasShown = service.specialShown(special)
    service.moveWindowToWorkspace(win.address, special, false)
    for (var j = 0; j < siblings.length; j++)
      service.moveWindowToWorkspace(siblings[j], special, false)
    // If the window was revealed through its special workspace (Alt-Tab or a
    // dock), moving it back there is not enough: close the special as well.
    if (specialWasShown) {
      if (special === "special" || special === "special:special")
        service.hypr("hl.dsp.workspace.toggle_special()")
      else
        service.hypr("hl.dsp.workspace.toggle_special(" + Shortcuts.luaString(special) + ")")
    }
    service.tagWindow(win.address, true)
    for (var k = 0; k < siblings.length; k++) service.tagWindow(siblings[k], true)
    var updated = Object.assign({}, entry, {
      hidden: true,
      special: special,
      siblings: siblings,
      previousWorkspace: win.workspace,
      previousMonitor: service.monitorNameForId(win.monitor)
    })
    service.registryNext(appId, updated)
    if (service.currentAppId === appId) service.currentAppId = ""
    service.lastAppId = appId
    if (restoreFocus !== false) service.restoreFocusLater(entry.previousFocus)
    service.notify((app ? app.name : appId) + " hidden.")
    service.scheduleStateSave()
    service.refreshCatalogState()
  }

  function monitorNameForId(id) {
    for (var i = 0; i < service.monitors.length; i++)
      if (service.monitors[i].id === Number(id)) return service.monitors[i].name
    return ""
  }

  function restoreFocusLater(address) {
    var addr = Model.normalizeAddress(address)
    if (!addr) return
    focusRestoreAddress = addr
    focusRestoreTimer.restart()
  }

  property string focusRestoreAddress: ""

  Timer {
    id: focusRestoreTimer
    interval: 300
    onTriggered: {
      if (service.focusRestoreAddress) service.focusWindow(service.focusRestoreAddress)
      service.focusRestoreAddress = ""
    }
  }

  function closeApp(appId, context) {
    service.cancelSlide()
    service.leaveEscapeMode()
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    if (service.launching[appId]) return { ok: false, message: app.name + " is still launching." }
    var entry = service.registry[appId]
    var win = entry ? service.clientByAddress(entry.address) : null
    if (!entry || !win) {
      service.forgetApp(appId)
      return { ok: false, message: app.name + " is not running." }
    }
    if (entry.hidden) {
      // Bring it back on screen first, so a quit confirmation dialog is not
      // stranded on the parked workspace.
      service.revealApp(appId, context || service.focusedContext())
    }
    service.closeWindow(win.address)
    service.closeWatches[appId] = Date.now()
    service.notify("Closing " + app.name + "…")
    service.scheduleStateSave()
    service.refreshCatalogState()
    return { ok: true, appId: appId }
  }

  property var closeWatches: ({})

  function checkCloseWatches() {
    var now = Date.now()
    var next = {}
    var changed = false
    for (var id in service.closeWatches) {
      if (!service.registry[id]) { changed = true; continue }
      var at = service.closeWatches[id]
      if (now - at < service.closeConfirmMs) { next[id] = at; continue }
      changed = true
      var app = service.findApp(id)
      service.notify((app ? app.name : id) + " is waiting for confirmation.")
    }
    if (changed) service.closeWatches = next
  }

  function hideVisibleCurrent() {
    var appId = service.currentAppId
    if (!appId) return { ok: false, message: "No dropdown is open." }
    var entry = service.registry[appId]
    if (!entry || entry.hidden) return { ok: false, message: "No dropdown is open." }
    service.parkApp(appId, true)
    return { ok: true, appId: appId }
  }

  function hideTarget() {
    var appId = service.paletteTarget
    if (!appId) return { ok: false, message: "No dropdown is open." }
    var entry = service.registry[appId]
    if (!entry) return { ok: false, message: "No dropdown is open." }
    if (entry.hidden) return { ok: false, message: "This dropdown is already hidden." }
    if (service.launching[appId]) return { ok: false, message: "Still launching." }
    // Return to the window that had focus when the palette was summoned, not
    // to an older window from the app's own history.
    var previous = Model.normalizeAddress(service.palettePreviousFocus)
    var address = Model.normalizeAddress(entry.address)
    service.parkApp(appId, false)
    if (previous && previous !== address) service.restoreFocusLater(previous)
    return { ok: true, appId: appId }
  }

  function captureContext() {
    return {
      monitor: service.paletteMonitor || service.focusedContext().monitor,
      workspace: service.paletteWorkspace || service.focusedContext().workspace
    }
  }

  // ---- Adoption and release -----------------------------------------------

  function adoptApp(appId) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    var win = null
    if (service.adoptable[appId]) win = service.clientByAddress(service.adoptable[appId])
    if (!win) win = service.findUnmanagedWindow(app)
    if (!win) return { ok: false, message: "No window of " + app.name + " found to adopt." }
    if (service.addressManaged(win.address)) return { ok: false, message: "That window is already managed." }
    var entry = {
      address: win.address,
      class: win.class,
      pid: win.pid,
      hidden: Model.isManagedSpecial(win.workspace),
      special: service.availableSpecial(appId),
      previousWorkspace: win.workspace,
      previousMonitor: service.monitorNameForId(win.monitor),
      previousFocus: "",
      since: Date.now()
    }
    service.registryNext(appId, entry)
    service.tagWindow(win.address, entry.hidden)
    service.setAdoptable(appId, "")
    service.setError(appId, "")
    service.lastAppId = appId
    if (entry.hidden) service.notify(app.name + " adopted while hidden.")
    else service.revealApp(appId, { monitor: entry.previousMonitor, workspace: entry.previousWorkspace }, win)
    service.scheduleStateSave()
    service.refreshCatalogState()
    return { ok: true, appId: appId }
  }

  // Detach a managed window and turn it back into an ordinary tiled window.
  // The app stays enabled: pressing its key later opens a fresh dropdown.
  function popOutApp(appId) {
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!entry) return { ok: false, message: (app ? app.name : appId) + " is not managed." }
    var win = service.clientByAddress(entry.address)
    var address = win ? win.address : ""
    var result = service.releaseApp(appId)
    if (!result.ok) return result
    if (address) {
      service.unfloatWindow(address)
      service.focusWindow(address)
    }
    service.notify((app ? app.name : appId) + " popped out as a normal window.")
    return { ok: true, appId: appId }
  }

  function releaseApp(appId) {
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!entry) return { ok: false, message: (app ? app.name : appId) + " is not managed." }
    var releasedWin = service.clientByAddress(entry.address)
    if (releasedWin) {
      service.markReleased(releasedWin.address)
      service.restoreWindowOpacity(releasedWin.address)
      service.tagWindow(releasedWin.address, false)
      var relSiblings = entry.siblings || []
      for (var r = 0; r < relSiblings.length; r++) service.tagWindow(relSiblings[r], false)
    }
    if (entry.hidden) {
      var win = releasedWin
      if (win) {
        var target = service.resolveContext({
          monitor: entry.previousMonitor || "",
          workspace: entry.previousWorkspace || ""
        })
        service.moveWindowToWorkspace(win.address, target.workspace, false)
        var siblings = entry.siblings || []
        for (var i = 0; i < siblings.length; i++) {
          if (service.clientByAddress(siblings[i])) service.moveWindowToWorkspace(siblings[i], target.workspace, false)
        }
      }
    }
    service.forgetApp(appId)
    service.notify((app ? app.name : appId) + " released as an ordinary window.")
    return { ok: true, appId: appId }
  }

  // ---- Configuration actions ----------------------------------------------

  function setEnabled(appId, enabled) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    if (enabled && !app.available) return { ok: false, message: app.name + " is not available: " + app.note }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    var cfg = next.apps[appId]
    if (app.url) cfg.url = app.url
    if (cfg.url && !Model.isSafeUrl(cfg.url)) delete cfg.url
    if (enabled) {
      var system = Model.enabledSystemMap(next)
      if (app.kind === "system") system[app.system] = true
      var key = cfg.key || (app.kind === "system" ? Model.SYSTEM_KEYS[app.system] : Model.firstFreeKey(app.name, service.usedKeys(), Model.reservedKeys(system)))
      if (!key) return { ok: false, message: "No free key available for " + app.name + "." }
      var check = Model.validateKey(key, appId, service.catalog, system, service.config.settings.commands)
      if (!check.ok) return { ok: false, message: check.error }
      cfg.key = key
      if (cfg.shortcut) {
        for (var i = 0; i < service.enabledApps.length; i++) {
          var other = service.enabledApps[i]
          if (other.id !== appId && other.shortcut === cfg.shortcut) { delete cfg.shortcut; break }
        }
      }
      cfg.enabled = true
    } else {
      if (cfg.key === undefined) cfg.key = app.key || ""
      cfg.enabled = false
    }
    service.config = next
    service.saveConfigNow()
    if (!enabled) {
      // Disabling must never trap a window. Visible ones stay where they are;
      // parked ones come back as ordinary windows.
      var entry = service.registry[appId]
      if (entry) {
        if (entry.hidden) service.releaseApp(appId)
        else service.forgetApp(appId)
      }
      if (service.lastAppId === appId) service.lastAppId = ""
    }
    service.setError(appId, "")
    service.setAdoptable(appId, "")
    service.rebuildCatalog()
    return { ok: true, appId: appId }
  }

  function usedKeys() {
    var out = []
    for (var i = 0; i < service.catalog.length; i++)
      if (service.catalog[i].enabled && service.catalog[i].key) out.push(service.catalog[i].key)
    return out
  }

  function removeMissing(appId) {
    var next = Model.clone(service.config)
    if (!next.apps[appId]) return { ok: false, message: "Nothing to remove." }
    delete next.apps[appId]
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.notify("Removed missing entry " + appId + ".")
    return { ok: true, appId: appId }
  }

  function applyAppShortcut(appId, chord) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    if (chord) next.apps[appId].shortcut = Model.normalizeShortcut(chord)
    else delete next.apps[appId].shortcut
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    return { ok: true, shortcut: chord }
  }

  function cancelShortcutRequest() {
    service.pendingShortcut = null
  }

  function validateShortcut(appId, value) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    if (!app.enabled) return { ok: false, message: "Enable " + app.name + " before adding a direct shortcut." }
    var raw = String(value || "").trim()
    var chord = Model.normalizeShortcut(raw)
    if (raw !== "" && chord === "")
      return { ok: false, message: "Use Super/Alt/Ctrl plus a letter, digit, function key, arrow or Tab." }
    var check = Shortcuts.validateShortcut(service.enabledApps, appId, chord)
    if (!check.ok) return { ok: false, message: check.message }
    return { ok: true, app: app, chord: chord }
  }

  // Validate, then ask Hyprland for its merged bind list before applying. This
  // catches Omarchy defaults and user overrides, not just Dropdown apps.
  function requestAppShortcut(appId, value) {
    var check = service.validateShortcut(appId, value)
    if (!check.ok) return check
    var app = check.app
    var chord = check.chord
    if (chord === "") {
      var cleared = service.applyAppShortcut(appId, "")
      if (cleared.ok) service.notify(app.name + " direct shortcut cleared.")
      return cleared
    }
    if (app.shortcut === chord) return { ok: true, shortcut: chord }
    if (bindsCheckProc.running || service.pendingShortcut)
      return { ok: false, message: "A shortcut check is already running." }
    service.pendingShortcut = { appId: appId, chord: chord }
    bindsCheckProc.running = true
    return { ok: true, pending: true, shortcut: chord }
  }

  function finishShortcutCheck(raw) {
    var pending = service.pendingShortcut
    service.pendingShortcut = null
    if (!pending) return
    var app = service.findApp(pending.appId)
    if (!app) return
    var binds = []
    try { binds = JSON.parse(String(raw || "[]")) } catch (e) { binds = [] }
    if (!Array.isArray(binds)) binds = []
    var mask = Model.shortcutModmask(pending.chord)
    var key = Model.hyprBindKey(pending.chord)
    var conflict = Shortcuts.bindConflict(binds, mask, key, app.name, app.shortcut, pending.chord)
    if (conflict) {
      service.notify(conflict)
      service.shortcutRejected(pending.appId, conflict)
      return
    }
    var result = service.applyAppShortcut(pending.appId, pending.chord)
    if (!result.ok) {
      service.notify(result.message)
      service.shortcutRejected(pending.appId, result.message)
      return
    }
    service.notify(app.name + " direct shortcut: " + pending.chord)
    service.shortcutAssigned(pending.appId, pending.chord)
  }

  Process {
    id: bindsCheckProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.finishShortcutCheck(String(text || ""))
    }
  }

  function assignKey(appId, key) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    var check = Model.validateKey(key, appId, service.catalog, Model.enabledSystemMap(service.config), service.config.settings.commands)
    if (!check.ok) return check
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    next.apps[appId].key = String(key)
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    return { ok: true, appId: appId }
  }

  function setSetting(path, value) {
    var next = Model.clone(service.config)
    Model.setPath(next, path, value)
    if (path === "settings.geometry.widthPercent" || path === "settings.geometry.heightPercent"
        || path === "settings.geometry.topOffset" || path === "settings.geometry.sideMargin") {
      next.settings.geometry.preset = "custom"
    }
    service.config = next
    service.scheduleConfigSave()
    if (path.indexOf("settings.geometry.") === 0) service.revalidateShownWindow()
  }

  function applyPreset(preset) {
    var next = Model.clone(service.config)
    next.settings.geometry = Model.applyPreset(next.settings.geometry, preset)
    service.config = next
    service.saveConfigNow()
  }

  function resetSettings() {
    var next = Model.clone(service.config)
    next.settings = Model.clone(Model.DEFAULT_CONFIG.settings)
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.revalidateShownWindow()
    service.notify("Size and animation settings reset.")
  }

  function appGeometry(appId) {
    var app = service.findApp(appId)
    return app && app.geometry ? app.geometry : null
  }

  function setAppGeometry(appId, widthPercent, heightPercent) {
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    var own = {}
    if (widthPercent !== null && widthPercent !== undefined) own.widthPercent = Model.clamp(widthPercent, 20, 100)
    if (heightPercent !== null && heightPercent !== undefined) own.heightPercent = Model.clamp(heightPercent, 20, 100)
    if (own.widthPercent === undefined && own.heightPercent === undefined) delete next.apps[appId].geometry
    else next.apps[appId].geometry = own
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.revalidateShownWindow()
  }

  function resetAppGeometry(appId) {
    var next = Model.clone(service.config)
    if (next.apps[appId]) delete next.apps[appId].geometry
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.revalidateShownWindow()
    service.notify("Size override cleared.")
  }

  // ---- Palette -------------------------------------------------------------

  // Called by the overlay before the layer surface takes keyboard focus.
  function capturePaletteContext(preferredMonitor, forceMonitor) {
    if (service.paletteOpen) return service.paletteTarget
    service.leaveEscapeMode()
    var fixed = forceMonitor === true ? "" : service.configuredScreen()
    var focused = service.focusedContext(fixed || preferredMonitor)
    service.paletteOpen = true
    service.paletteTarget = service.currentAppId || service.lastAppId || ""
    service.paletteMonitor = focused.monitor
    service.paletteWorkspace = focused.workspace
    var active = Hyprland.activeToplevel
    service.palettePreviousFocus = active ? Model.normalizeAddress(active.address) : ""
    service.refreshClients()
    return service.paletteTarget
  }

  function paletteClosed() {
    service.paletteOpen = false
    if (service.currentAppId) service.enterEscapeMode()
    service.paletteTarget = ""
    service.paletteMonitor = ""
    service.paletteWorkspace = ""
    // The palette may have been the only focused surface. Re-evaluate focus
    // loss now that it is gone.
    service.maybeAutoHide()
  }

  property var pendingPaletteOpen: null

  Timer {
    id: paletteReopenTimer
    interval: 240
    onTriggered: {
      var next = service.pendingPaletteOpen
      service.pendingPaletteOpen = null
      if (next) service.openPalette(next.view, next.monitor)
    }
  }

  function openPalette(view, monitorName, forceMonitor) {
    var requested = String(monitorName || "")
    // Moving the palette between outputs: close the old surface first, then
    // open a fresh one on the requested screen. A layer surface is bound to
    // one output for its lifetime, so re-binding is not reliable.
    if (service.paletteOpen && requested && service.paletteMonitor
        && requested !== service.paletteMonitor) {
      service.pendingPaletteOpen = { view: view || "palette", monitor: requested }
      if (service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
      paletteReopenTimer.restart()
      return true
    }
    var payload = JSON.stringify({ view: view || "palette", monitor: requested, force: forceMonitor === true })
    if (service.shell && typeof service.shell.summon === "function") {
      service.shell.summon("apach.dropdown", payload)
      return true
    }
    return false
  }

  function toggleFromBar(view, monitorName) {
    if (service.paletteOpen) {
      if (monitorName && service.paletteMonitor && String(monitorName) !== service.paletteMonitor) {
        service.openPalette(view, monitorName)
        return
      }
      if (service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
      return
    }
    service.openPalette(view, monitorName)
  }

  // Running managed windows, in catalog order, for the tab bar and the
  // optional global next/previous bind.
  function runningWindows() {
    var out = []
    for (var i = 0; i < service.catalog.length; i++) {
      var app = service.catalog[i]
      if (!app.enabled) continue
      if (app.state !== "visible" && app.state !== "hidden") continue
      if (!service.registry[app.id]) continue
      out.push(app)
    }
    return out
  }

  function cycleWindow(delta, context) {
    var list = service.runningWindows()
    if (list.length === 0) return { ok: false, message: "No open window." }
    if (list.length === 1) return { ok: false, message: "Only one window is open." }
    var index = -1
    for (var i = 0; i < list.length; i++) if (list[i].id === service.currentAppId) index = i
    if (index < 0) index = delta > 0 ? -1 : 0
    var next = list[(index + delta + list.length) % list.length]
    service.revealApp(next.id, context)
    return { ok: true, appId: next.id, name: next.name }
  }

  function paletteMatchesKey(key) {
    var value = String(key || "")
    if (!value) return []
    var out = []
    for (var i = 0; i < service.catalog.length; i++) {
      var app = service.catalog[i]
      if (app.enabled && app.key === value) out.push(app)
    }
    return out
  }

  // ---- Notices -------------------------------------------------------------

  function notify(message) {
    service.notice = String(message || "")
    noticeClearTimer.restart()
    if (service.notice) console.log("omarchy-dropdown: " + service.notice)
  }

  Timer {
    id: noticeClearTimer
    interval: 6000
    onTriggered: service.notice = ""
  }

  // ---- Restore -------------------------------------------------------------

  function restoreAll(reason) {
    service.hyprDetached("hl.dsp.submap(\"reset\")")
    for (var id in service.registry) {
      var entry = service.registry[id]
      if (Model.validAddress(entry.address)) {
        service.restoreWindowOpacity(entry.address)
        service.hyprDetached(service.tagExpr(entry.address, false))
      }
      var restoreSiblings = entry.siblings || []
      for (var s = 0; s < restoreSiblings.length; s++)
        if (Model.validAddress(restoreSiblings[s])) service.hyprDetached(service.tagExpr(restoreSiblings[s], false))
      if (!entry.hidden) continue
      var target = entry.previousWorkspace || "1"
      service.hyprDetached("hl.dsp.window.move({ workspace = " + Shortcuts.luaString(target) +
        ", follow = false, window = " + Shortcuts.luaString(service.windowSelector(entry.address)) + " })")
      var siblings = entry.siblings || []
      for (var i = 0; i < siblings.length; i++) {
        if (!Model.validAddress(siblings[i])) continue
        service.hyprDetached("hl.dsp.window.move({ workspace = " + Shortcuts.luaString(target) +
          ", follow = false, window = " + Shortcuts.luaString(service.windowSelector(siblings[i])) + " })")
      }
    }
    service.registry = {}
    service.currentAppId = ""
    service.lastAppId = ""
    console.log("omarchy-dropdown: restored managed windows (" + String(reason || "shutdown") + ")")
  }

  // ---- Lifecycle -----------------------------------------------------------

  Component.onCompleted: {
    Quickshell.execDetached(["mkdir", "-p", service.stateDir])
    // A hot reload recreates the overlay but keeps this service object. Reset
    // the palette flag so the next open is not ignored as "already open".
    service.paletteOpen = false
    service.paletteTarget = ""
    service.paletteMonitor = ""
    service.paletteWorkspace = ""
    service.palettePreviousFocus = ""
    service.refreshSystemDefaults()
    service.refreshMonitors()
    service.refreshClients()
    console.log("omarchy-dropdown: service started")
  }

  Component.onDestruction: {
    // A shell restart or a code reload keeps the plugin enabled: leave parked
    // windows untouched so the next service instance can recover them exactly
    // as they were. Only an actual disable/removal releases them and clears
    // the generated direct binds.
    if (!service.pluginStillEnabled()) {
      service.cleanupBinds()
      service.restoreAll("plugin disabled")
    } else {
      console.log("omarchy-dropdown: service unloaded; parked windows preserved")
    }
  }

  Connections {
    target: DesktopEntries
    function onApplicationsChanged() { service.rebuildCatalog() }
  }

  Connections {
    target: Hyprland
    function onActiveToplevelChanged() {
      service.adoptFocusedParked()
      service.maybeAutoHide()
    }
    function onFocusedWorkspaceChanged() {
      service.maybeAutoHide()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (name === "monitoradded" || name === "monitorremoved" || name === "monitoraddedv2"
          || name === "configreloaded" || name === "monitorlayout" || name === "monitorlayoutchanged"
          || name === "activespecial" || name === "workspace") {
        service.monitorCheckPending = true
      }
      if (name === "configreloaded") {
        service.verifyBinds()
        // Hyprland resets submaps on reload.
        if (service.currentAppId && !service.paletteOpen) service.enterEscapeMode()
      }
      if (name === "openwindow" || name === "closewindow" || name === "movewindow"
          || name === "movewindowv2" || name === "workspace" || name === "activespecial"
          || name === "focusedmon" || name === "monitoradded" || name === "monitorremoved"
          || name === "monitoraddedv2" || name === "configreloaded" || name === "fullscreen") {
        // Adopt a newly launched window as soon as it maps. The default 120 ms
        // debounce leaves a visible flash of the window at its default size
        // before it is parked and slid in.
        var launching = false
        for (var id in service.launching) launching = true
        eventDebounce.interval = (name === "openwindow" && launching) ? 35 : 120
        eventDebounce.restart()
      }
    }
  }

  Timer {
    id: eventDebounce
    interval: 120
    onTriggered: {
      service.refreshClients()
      // A workspace switch can leave no active toplevel; re-evaluate auto-hide.
      service.maybeAutoHide()
      // Monitor queries are only needed after an output/layout event.
      if (service.monitorCheckPending) service.refreshMonitors()
    }
  }

  // "" when the visible window still owns focus; otherwise the reason it
  // should be hidden ("workspace" or "focus"). Shared by the scheduling path
  // and the timer callback so the condition can never drift apart.
  function autoHideReason() {
    if (!service.config.settings.autoHideOnFocusLoss) return ""
    if (!service.currentAppId) return ""
    var entry = service.registry[service.currentAppId]
    if (!entry || entry.hidden) return ""
    // The pure decision lives in State.autoHideReason and is unit-tested.
    var focused = Hyprland.focusedWorkspace
    var currentWin = service.clientByAddress(entry.address)
    var active = Hyprland.activeToplevel
    var activeAddress = active ? Model.normalizeAddress(active.address) : ""
    var activeWin = activeAddress ? service.clientByAddress(activeAddress) : null
    return State.autoHideReason({
      enabled: true,
      entry: entry,
      paletteOpen: service.paletteOpen,
      focusedName: focused ? String(focused.name || "") : "",
      windowWs: currentWin ? String(currentWin.workspace || "") : "",
      activeAddress: activeAddress,
      entryAddress: Model.normalizeAddress(entry.address),
      activeIsSibling: !!(activeWin && currentWin && service.isSibling(currentWin, activeWin))
    })
  }

  function maybeAutoHide() {
    if (service.autoHideReason()) autoHideTimer.restart()
    else autoHideTimer.stop()
  }

  Timer {
    id: autoHideTimer
    // The visible window is only parked after this delay, and only if focus
    // has not returned to it (or to one of its dialogs) in the meantime.
    interval: Math.max(0, Number(service.config.settings.autoHideDelayMs))
    onTriggered: {
      if (service.autoHideReason()) service.parkApp(service.currentAppId, false)
    }
  }

  function setLaunchAtLogin(appId, value) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: "Unknown application." }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    if (!next.apps[appId].key) next.apps[appId].key = app.key || ""
    next.apps[appId].launchAtLogin = value === true
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.notify(app.name + (value ? " will start hidden at login." : " will no longer start at login."))
    return { ok: true, appId: appId }
  }

  function setCommandKey(name, key) {
    var value = String(key || "")
    var commands = service.config.settings.commands || Model.DEFAULT_COMMANDS
    if (!commands[name]) return { ok: false, message: "Unknown command." }
    if (value.length !== 1) return { ok: false, message: "Use a single character." }
    if (value === "\u001b") return { ok: false, message: "Escape is reserved for Reduce." }
    for (var other in commands) {
      if (other !== name && String(commands[other]) === value)
        return { ok: false, message: "\"" + value + "\" is already used by " + other + "." }
    }
    for (var i = 0; i < service.enabledApps.length; i++) {
      if (String(service.enabledApps[i].key) === value)
        return { ok: false, message: "\"" + value + "\" is assigned to " + service.enabledApps[i].name + "." }
    }
    var next = Model.clone(service.config)
    if (!next.settings.commands) next.settings.commands = Model.clone(Model.DEFAULT_COMMANDS)
    next.settings.commands[name] = value
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    return { ok: true, command: name, key: value }
  }

  function resetCommands() {
    var next = Model.clone(service.config)
    next.settings.commands = Model.clone(Model.DEFAULT_COMMANDS)
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.notify("Shortcuts reset.")
  }

  function reduceCurrent() {
    if (service.paletteOpen) {
      var target = service.paletteTarget
      if (target) service.hideTarget()
      if (service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
      return { ok: true, message: "" }
    }
    if (service.currentAppId) {
      var app = service.findApp(service.currentAppId)
      service.parkApp(service.currentAppId, true)
      return { ok: true, message: (app ? app.name : "Dropdown") + " hidden." }
    }
    return { ok: false, message: "No dropdown is open." }
  }

  function enterEscapeMode() {
    service.hypr("hl.dsp.submap(\"apach-dropdown\")")
  }

  function leaveEscapeMode() {
    service.hypr("hl.dsp.submap(\"reset\")")
  }

  // ---- IPC -----------------------------------------------------------------

  // Builds the doctor payload; `redact` strips app names/ids/notes.
  function doctorData(redact) {
      var apps = []
      for (var i = 0; i < service.catalog.length; i++) {
        var app = service.catalog[i]
        if (!app.enabled) continue
        apps.push({
          id: redact ? "app" : app.id, name: redact ? "app" : app.name,
          key: app.key, shortcut: app.shortcut,
          state: app.state, note: redact ? "" : app.note, kind: app.kind,
          expectedClass: app.expectedClass || app.startupClass || "",
          available: app.available
        })
      }
      var registered = []
      for (var id in service.registry) registered.push(id)
      return JSON.stringify({
        version: service.manifest ? String(service.manifest.version || "") : "",
        configPath: service.configPath,
        bindsPath: service.bindsPath,
        statePath: service.statePath,
        configLoaded: service.configLoaded,
        stateLoaded: service.stateLoaded,
        bindsLoaded: service.bindsLoaded,
        configDirty: service.configDirty,
        hyprError: service.hyprError,
        lastHyprErrorAt: service.lastHyprErrorAt,
        current: service.currentAppId,
        last: service.lastAppId,
        palette: service.paletteOpen,
        registry: registered,
        monitors: service.monitors.map(function(m) { return m.name }),
        clients: service.clients.length,
        launching: Object.keys(service.launching),
        pendingShortcut: service.pendingShortcut,
        errors: service.errors,
        conflicts: service.conflicts,
        apps: apps
      }, null, 2)
    }

  IpcHandler {
    target: "apach.dropdown"

    function open(): void { service.openPalette("palette") }
    function openOn(monitor: string): void { service.openPalette("palette", String(monitor), true) }
    function manage(): void { service.openPalette("manage") }
    function manageOn(monitor: string): void { service.openPalette("manage", String(monitor), true) }
    function toggle(): void { service.toggleFromBar("palette") }
    function showApp(appId: string): string { var r = service.toggleApp(String(appId)); return JSON.stringify(r) }
    function hide(): string { var r = service.hideVisibleCurrent(); return JSON.stringify(r) }
    function reduce(): string { var r = service.reduceCurrent(); return JSON.stringify(r) }
    function closeApp(appId: string): string { var r = service.closeApp(String(appId)); return JSON.stringify(r) }
    function popOut(appId: string): string { var r = service.popOutApp(String(appId)); return JSON.stringify(r) }
    function setShortcut(appId: string, shortcut: string): string { var r = service.requestAppShortcut(String(appId), String(shortcut)); return JSON.stringify(r) }
    function next(): string { var r = service.cycleWindow(1); return JSON.stringify(r) }
    function previous(): string { var r = service.cycleWindow(-1); return JSON.stringify(r) }
    function restoreAll(): void { service.restoreAll("ipc") }
    function refresh(): void { service.refreshCatalog() }
    function cleanup(): string {
      service.cleanupBinds()
      return JSON.stringify({ ok: true, binds: service.bindsPath })
    }
    // One-shot support bundle: paths, live counts, last error and generated
    // binds, without exposing personal configuration in the public repo.
    function doctor(): string { return service.doctorData(false) }
    function doctorRedacted(): string { return service.doctorData(true) }
    function status(): string {
      var apps = []
      for (var i = 0; i < service.catalog.length; i++) {
        var app = service.catalog[i]
        if (!app.enabled) continue
        apps.push({ id: app.id, name: app.name, key: app.key, state: app.state, note: app.note })
      }
      return JSON.stringify({
        version: service.manifest ? String(service.manifest.version || "") : "",
        current: service.currentAppId,
        last: service.lastAppId,
        palette: service.paletteOpen,
        target: service.paletteTarget,
        apps: apps,
        conflicts: service.conflicts,
        errors: service.errors,
        hyprError: service.hyprError,
        screen: service.config.settings.screen,
        topApps: service.config.settings.topApps,
        animations: service.config.settings.animations,
        commands: service.config.settings.commands,
        autostartSession: service.autostartSession,
        paletteMonitor: service.paletteMonitor,
        catalog: service.catalog.length,
        webapps: service.webapps.length,
        applications: service.applications.length,
        enabled: service.enabledApps.length,
        monitors: service.monitors.length,
        clients: service.clients.length,
        configDirty: service.configDirty
      })
    }
  }

  // ---- Reveal shell (rendered here so no cross-object wiring is involved) ----

  function shellScreenObject() {
    var name = service.shellScreen
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name || "") === name) return screens[i]
    return screens.length > 0 ? screens[0] : null
  }

  PanelWindow {
    id: shellPanel
    visible: service.shellActive
    screen: service.shellScreenObject()
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "apach-dropdown-shell"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    Rectangle {
      id: shellCard
      x: service.shellX
      y: service.shellY
      width: service.shellW
      height: service.shellH
      radius: Style.cornerRadius
      color: Commons.Color.popups.background
      border.width: 1
      border.color: Commons.Color.popups.border
      opacity: service.shellOpacity

      Column {
        anchors.centerIn: parent
        spacing: Style.space(2)
        Image {
          anchors.horizontalCenter: parent.horizontalCenter
          width: 40
          height: 40
          source: service.shellIcon !== "" ? Quickshell.iconPath(service.shellIcon, true) : ""
          fillMode: Image.PreserveAspectFit
          opacity: 0.9
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          text: service.shellName
          color: Commons.Color.popups.text
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }
      }

      Behavior on x { enabled: service.shellActive; NumberAnimation { duration: service.shellDuration; easing.type: Easing.OutCubic } }
      Behavior on y { enabled: service.shellActive; NumberAnimation { duration: service.shellDuration; easing.type: Easing.OutCubic } }
      Behavior on opacity { enabled: service.shellActive; NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }
  }
}
