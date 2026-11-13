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
import "js/Keymap.js" as Keymap
import "js/Bounds.js" as Bounds
import "components"

Item {
  id: service

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // Translate a catalog key and fill its %1, %2, ... holes with data. Calling
  // strings.t() from here keeps property bindings live when the language
  // changes, because QML tracks the function's catalog reads.
  function tr(key, args, fallback) {
    var value = strings.t(key, fallback)
    for (var i = 0; i < (args || []).length; i++) value = value.arg(String(args[i]))
    return value
  }

  function tn(key, count, args) {
    var value = strings.tn(key, count).arg(Commons.I18n.formatNumber(count))
    for (var i = 0; i < (args || []).length; i++) value = value.arg(String(args[i]))
    return value
  }

  function number(value) {
    return Commons.I18n.formatNumber(value)
  }

  function keyErrorMessage(check) {
    if (check && check.errorKey) return service.tr(check.errorKey, check.errorArgs)
    return String((check && check.error) || "")
  }

  function shortcutMessage(check) {
    if (check && check.messageKey) return service.tr(check.messageKey, check.messageArgs)
    return String((check && check.message) || "")
  }

  function appConflictText(app) {
    if (!app || !app.conflict) return ""
    return service.tr(app.conflictKey, app.conflictArgs, app.conflict)
  }

  function appStateNoteInfo(app) {
    var entry = app ? service.registry[app.id] : null
    var win = entry ? service.clientByAddress(entry.address) : null
    return State.stateNoteKey(app, entry, win, service.errors[app ? app.id : ""])
  }

  function appNoteText(app) {
    var info = service.appStateNoteInfo(app)
    if (!info) return ""
    return service.tr(info.key, info.args, service.appStateNote(app))
  }

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
  property int shortcutCheckGeneration: 0
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
    if (service.currentAppId) return service.tr("tooltip.current",
      [service.currentApp ? service.currentApp.name : service.currentAppId])
    var last = service.findApp(service.lastAppId)
    if (last) return service.tr("tooltip.hidden", [last.name])
    return strings.t("tooltip.idle")
  }

  // ---- Persistence ---------------------------------------------------------

  property bool configLoaded: false
  property bool stateLoaded: false
  property string lastConfigWrite: ""
  property bool configDirty: false
  property bool configPendingChange: false

  // FileView is used for atomic writes and change notification only. Its
  // content API is unbounded, so every read goes through a bounded helper:
  // `head -c cap+1` under `timeout`, executed directly (no shell). A file
  // larger than the cap is refused, never parsed partially.
  FileView {
    id: configView
    path: service.configPath
    watchChanges: true
    atomicWrites: true
    preload: false
    printErrors: false
    onFileChanged: service.configFileChanged()
  }

  BoundedProcess {
    id: configReadProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.configBytes
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.ok) {
        if (Bounds.isCurrentGeneration(result.tag, service.configReadGeneration))
          service.acceptConfigRead(result.out)
        // A change arrived while this read was running: read again with a
        // fresh generation instead of leaving the request pending.
        if (service.configReadAgain && !configReadProc.running) {
          service.configReadAgain = false
          service.readConfig()
        }
      } else {
        service.inspectConfigFailure(result)
      }
    }
  }

  // Any configuration backup runs here: a bounded, awaited `cp`. The caller's
  // follow-up (adopt the new file, rewrite local edits, or replace a refused
  // file) runs from `onFinished` and only when the copy exited 0.
  BoundedProcess {
    id: configBackupProc
    producerTimeoutSeconds: 4
    timeoutMs: 5000
    maxOutBytes: 1024
    maxErrBytes: 4096
    onFinished: function(result) { service.finishConfigBackup(result) }
  }

  property bool configBackupInFlight: false
  // Follow-up of the copy currently running; it receives `ok`.
  property var configBackupFollowUp: null
  // "refused-write" | "adoption" | "dirty": what the running follow-up does.
  property string configBackupKind: ""
  // At most one deferred intent: the latest request made while a copy was
  // running. It starts when the current copy settles, so two copies never
  // race and a repeated request cannot loop.
  property var configBackupNext: null
  // An explicitly requested save that asked for a backup while another copy
  // was running. It is coalesced with repeated requests and runs after the
  // current copy, so that save is never lost.
  property bool configRefusedSavePending: false

  // Keeps the documented five most recent backups after every successful
  // config backup. Runs bounded and asynchronously: it never blocks or fails
  // the caller's follow-up.
  BoundedProcess {
    id: configPruneProc
    producerTimeoutSeconds: 4
    timeoutMs: 5000
    maxOutBytes: 1024
    maxErrBytes: 2048
    onFinished: function(result) {
      if (!result.ok)
        console.warn("omarchy-dropdown: backup prune failed (" +
          service.helperDetail(result) + ")")
    }
  }

  function pruneConfigBackups() {
    if (configPruneProc.running) return
    if (!configPruneProc.start(ConfigFile.pruneCommand(service.configPath)))
      console.warn("omarchy-dropdown: backup prune could not be started")
  }

  // A failed read is never interpreted as "the file is absent". A bounded
  // `test -e`/`test -r` probe decides whether creating defaults is safe.
  BoundedProcess {
    id: configStatProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 1024
    maxErrBytes: 1024
    onFinished: function(result) { service.handleConfigStat(result) }
  }

  property bool configReadAgain: false
  property int configReadGeneration: 0
  property bool configStatBusy: false
  property var configStatFailure: null
  property var configStatPendingFailure: null
  // A refused configuration is never written automatically. An explicit save
  // backs the existing file up first and tells the user.
  property bool configRefused: false
  property bool configRefusalNotified: false

  function readConfig() {
    service.configReadGeneration++
    if (configReadProc.running) {
      service.configReadAgain = true
      return
    }
    configReadProc.start(Bounds.fileReadCommand(service.configPath, Bounds.LIMITS.configBytes),
      service.configReadGeneration)
  }

  function configFileChanged() {
    service.configPendingChange = true
    service.readConfig()
  }

  function inspectConfigFailure(failure) {
    if (configStatBusy) {
      service.configStatPendingFailure = failure
      return
    }
    configStatBusy = true
    configStatFailure = failure
    configStatProc.start(Bounds.fileStateCommand(service.configPath))
  }

  function handleConfigStat(statResult) {
    configStatBusy = false
    var failure = service.configStatFailure
    service.configStatFailure = null
    // A newer read started while the probe was running: its own outcome (and
    // its own probe) decides. An old failure must not refuse a file that is
    // now readable.
    var superseded = failure && failure.tag !== undefined &&
      failure.tag !== service.configReadGeneration
    if (!superseded) {
      var policy = Bounds.readFailurePolicy(Bounds.fileStateFromExit(statResult), failure)
      if (policy === "absent") service.configAbsent()
      else service.configRefuseRead(failure)
    }
    if (service.configStatPendingFailure) {
      var next = service.configStatPendingFailure
      service.configStatPendingFailure = null
      service.inspectConfigFailure(next)
      return
    }
    if (service.configReadAgain && !configReadProc.running) {
      service.configReadAgain = false
      service.readConfig()
    }
  }

  // The file is provably absent: creating defaults cannot destroy anything.
  function configAbsent() {
    service.configReadAgain = false
    if (!service.configLoaded) {
      service.configLoaded = true
      service.configDirty = false
      service.config = Model.clone(Model.DEFAULT_CONFIG)
      service.saveConfigNow()
      service.rebuildCatalog()
      autostartTimer.restart()
      return
    }
    // A loaded configuration whose file disappeared stays in memory; a later
    // explicit save may recreate the file safely.
    service.configRefused = false
    service.configRefusalNotified = false
  }

  // Timeout, overflow, permission error, missing tool or an unknown probe:
  // keep the file exactly as it is and refuse automatic writes.
  function configRefuseRead(failure) {
    service.configReadAgain = false
    console.warn("omarchy-dropdown: dropdown.json could not be read (" +
      service.helperDetail(failure) + "); keeping it untouched")
    service.configRefused = true
    service.configDirty = false
    service.configPendingChange = false
    configSaveTimer.stop()
    if (!service.configLoaded) {
      service.configLoaded = true
      service.config = Model.clone(Model.DEFAULT_CONFIG)
      service.rebuildCatalog()
      autostartTimer.restart()
    }
    if (!service.configRefusalNotified) {
      service.configRefusalNotified = true
      service.notify(service.tr("service.configReadRefused"))
    }
  }

  function acceptConfigRead(current) {
    service.configRefused = false
    service.configRefusalNotified = false
    if (!service.configLoaded) {
      service.loadConfig(current)
      return
    }
    if (!service.configPendingChange) return
    service.configPendingChange = false
    // Our own atomic write comes back as a file change. Reloading it would
    // clobber edits made while the write was in flight.
    if (ConfigFile.isOwnWrite(current, service.lastConfigWrite)) return
    if (service.configDirty) {
      // Local edits are newer than the file: keep them and rewrite, but only
      // after the bounded backup of the file we are about to replace.
      service.backupConfig(function(ok) {
        if (ok) service.saveConfigNow()
        else {
          service.blockConfigWritesAfterBackupFailure()
          service.notify(service.tr("service.configBackupFailed"))
        }
      }, "dirty")
      return
    }
    if (!ConfigFile.looksLikeConfig(current)) {
      // Never replace the user's broken file or silently reset settings; a
      // later valid edit will be adopted normally.
      service.notify(service.tr("service.invalidConfig"))
      return
    }
    service.backupConfig(function(ok) {
      if (ok) service.loadConfig(current)
      else {
        service.blockConfigWritesAfterBackupFailure()
        service.notify(service.tr("service.configBackupFailed"))
      }
    }, "adoption")
  }

  // A failed adoption backup leaves an external file we could not copy. Keep
  // the refusal barrier so no automatic save (recordUse, ensureKeys,
  // normalizeConfig) can overwrite it; an explicit save retries the backup.
  function blockConfigWritesAfterBackupFailure() {
    service.configRefused = true
    configSaveTimer.stop()
  }

  // The state file is written by this service only. It is read once at
  // startup; watching our own writes would reload a stale snapshot and
  // re-adopt windows that were just released or popped out. The write path
  // uses FileView; the read path is bounded and capped below.
  FileView {
    id: stateView
    path: service.statePath
    atomicWrites: true
    preload: false
    printErrors: false
  }

  BoundedProcess {
    id: stateReadProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.stateBytes
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.ok) {
        if (Bounds.isCurrentGeneration(result.tag, service.stateReadGeneration))
          service.acceptStateRead(result.out)
      } else {
        service.inspectStateFailure(result)
      }
    }
  }

  BoundedProcess {
    id: stateStatProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 1024
    maxErrBytes: 1024
    onFinished: function(result) { service.handleStateStat(result) }
  }

  // The state file is only replaced after a successful read (or when it is
  // provably absent). A refused state is never overwritten automatically.
  property bool stateWritable: false
  property bool stateRefused: false
  property bool stateRefusalNotified: false
  property bool stateRefusalWarned: false
  property int stateReadAttempts: 0
  property int stateReadGeneration: 0
  property bool stateStatBusy: false
  property var stateStatFailure: null
  property var stateStatPendingFailure: null

  function readState() {
    if (stateReadProc.running) return
    service.stateReadGeneration++
    stateReadProc.start(Bounds.fileReadCommand(service.statePath, Bounds.LIMITS.stateBytes),
      service.stateReadGeneration)
  }

  function acceptStateRead(raw) {
    service.stateWritable = true
    service.stateRefused = false
    service.stateRefusalNotified = false
    service.stateRefusalWarned = false
    service.stateReadAttempts = 0
    service.loadState(raw)
    var known = false
    for (var id in service.registry) known = true
    if (known) service.scheduleStateSave()
  }

  function inspectStateFailure(failure) {
    if (stateStatBusy) {
      service.stateStatPendingFailure = failure
      return
    }
    stateStatBusy = true
    stateStatFailure = failure
    stateStatProc.start(Bounds.fileStateCommand(service.statePath))
  }

  function handleStateStat(statResult) {
    stateStatBusy = false
    var failure = service.stateStatFailure
    service.stateStatFailure = null
    var superseded = failure && failure.tag !== undefined &&
      failure.tag !== service.stateReadGeneration
    if (!superseded) {
      var policy = Bounds.readFailurePolicy(Bounds.fileStateFromExit(statResult), failure)
      if (policy === "absent") {
        // Nothing to lose: a missing state file may be created by the service.
        service.stateWritable = true
        service.stateRefused = false
        service.stateRefusalNotified = false
        service.stateRefusalWarned = false
        service.stateReadAttempts = 0
        service.loadState("")
      } else {
        service.stateRefuseRead(failure)
      }
    }
    if (service.stateStatPendingFailure) {
      var next = service.stateStatPendingFailure
      service.stateStatPendingFailure = null
      service.inspectStateFailure(next)
    }
  }

  function stateRefuseRead(failure) {
    console.warn("omarchy-dropdown: dropdown-state.json could not be read (" +
      service.helperDetail(failure) + "); it will not be overwritten automatically")
    service.stateWritable = false
    service.stateRefused = true
    service.stateLoaded = true
    service.savedRegistry = {}
    service.recoverFromSaved()
    autostartTimer.restart()
    if (!service.stateRefusalNotified) {
      service.stateRefusalNotified = true
      service.notify(service.tr("service.stateReadRefused"))
    }
    // One bounded retry: a transient timeout can recover without ever
    // replacing the file with an empty registry.
    if (service.stateReadAttempts === 0) {
      service.stateReadAttempts = 1
      stateRetryTimer.restart()
    }
  }

  Timer {
    id: stateRetryTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (!service.stateWritable) service.readState()
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

  // Copy the file before an external edit is adopted or overwritten. The copy
  // is a bounded, awaited BoundedProcess: `followUp(ok)` runs from its
  // completion handler, and callers must not write or adopt before `ok`.
  // `kind` tells the completion handler whether the follow-up writes the
  // current configuration ("refused-write") or only adopts/loads it
  // ("adoption", "dirty"); it decides whether a deferred save is replayed.
  // Five timestamped backups stay next to dropdown.json; pruning uses a
  // constant path passed as an argument, never interpolated shell text.
  function backupConfig(followUp, kind) {
    var callback = typeof followUp === "function" ? followUp : null
    var label = String(kind || "")
    if (service.configBackupInFlight) {
      // One copy at a time. Keep only the latest deferred intent; it starts
      // once the current copy settles, so no two copies race and no request
      // is silently forgotten.
      service.configBackupNext = { followUp: callback, kind: label }
      return true
    }
    return service._startConfigBackup(callback, label)
  }

  function _startConfigBackup(callback, kind) {
    var target = ConfigFile.backupName(service.configPath, new Date())
    if (!target) {
      if (callback) callback(false)
      else service.notify(service.tr("service.configBackupFailed"))
      return false
    }
    service.configBackupInFlight = true
    service.configBackupFollowUp = callback
    service.configBackupKind = String(kind || "")
    var started = configBackupProc.start(["cp", "--", service.configPath, target])
    if (!started) {
      service.configBackupInFlight = false
      service.configBackupFollowUp = null
      service.configBackupKind = ""
      if (callback) callback(false)
      else service.notify(service.tr("service.configBackupFailed"))
    }
    return started
  }

  function finishConfigBackup(result) {
    service.configBackupInFlight = false
    var callback = service.configBackupFollowUp
    var kind = service.configBackupKind
    service.configBackupFollowUp = null
    service.configBackupKind = ""
    if (result.ok) {
      // The copy exists; keep the documented five most recent ones. The
      // bounded prune is fire-and-forget and cannot block the follow-up.
      service.pruneConfigBackups()
    } else {
      console.warn("omarchy-dropdown: configuration backup failed (" +
        service.helperDetail(result) + ")")
    }
    if (typeof callback === "function") callback(result.ok === true)
    else if (!result.ok) service.notify(service.tr("service.configBackupFailed"))
    // A refused-write follow-up has just written the current in-memory
    // configuration, which already includes every save requested during its
    // copy. Replaying the pending flag would take a second backup (same
    // target second) over the original and write twice.
    if (!Bounds.backupReplayPending(kind)) service.configRefusedSavePending = false
    // A request made while this copy was running starts now, unless the
    // follow-up itself already started another copy.
    var next = service.configBackupNext
    service.configBackupNext = null
    if (next) {
      if (service.configBackupInFlight) service.configBackupNext = next
      else service._startConfigBackup(next.followUp, next.kind)
    }
    // An explicit save that was deferred by the in-flight guard must also
    // run; startRefusedBackup keeps it pending if a copy is still active.
    if (service.configRefusedSavePending) service.startRefusedBackup()
  }

  function normalizeConfig() {
    var next = Model.clone(service.config)
    var changed = false
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
        if (!old || String(old.url || "").toLowerCase() !== String(app.url || "").toLowerCase()) continue
        if (service.webapps.some(function(w) { return w.id === oldId })) continue
        var moved = Model.clone(old)
        delete next.apps[oldId]
        next.apps[app.id] = moved
        changed = true
        service.notify(service.tr("service.movedSettings", [oldId, app.id]))
        break
      }
    }
    if (changed) {
      service.config = next
      service.saveConfigNow()
      service.rebuildCatalog()
    }
  }

  // `explicit` is set by user-facing settings changes. When the file was
  // refused, automatic saves are blocked; an explicit change still saves, but
  // only after backing up the file we could not read and telling the user.
  function scheduleConfigSave(explicit) {
    service.configDirty = true
    // blockConfigWritesAfterBackupFailure keeps configRefused true after a
    // failed adoption backup, so an automatic save cannot overwrite the file.
    if (Bounds.configSaveAction(service.configRefused, explicit) === "blocked") return
    configSaveTimer.restart()
  }

  function saveConfigNow() {
    configSaveTimer.stop()
    if (service.configRefused) {
      service.startRefusedBackup()
      return
    }
    service.writeConfigNow()
  }

  // The raw write, only reached when the file is readable or was proven
  // absent, or after a refused version was successfully backed up.
  function writeConfigNow() {
    var text = ConfigFile.encode(service.config)
    service.lastConfigWrite = text
    service.configDirty = false
    configView.setText(text)
  }

  // A refused file may only be replaced after its copy succeeded. The write
  // is deferred to the backup's follow-up; a failure notifies and leaves the
  // file untouched. A request made while another copy is running is retained
  // as a pending save (coalesced) and retried after that copy, so an explicit
  // save is never dropped.
  function startRefusedBackup() {
    if (service.configBackupInFlight) {
      service.configRefusedSavePending = true
      return
    }
    service.configRefusedSavePending = false
    service.backupConfig(function(ok) {
      if (!ok) {
        // The copy failed. Keep the barrier even if a read cleared the
        // refusal while it ran: a readable file still must not be overwritten
        // without a successful backup. The next explicit save retries.
        service.blockConfigWritesAfterBackupFailure()
        console.warn("omarchy-dropdown: configuration backup failed; " +
          "refusing to overwrite dropdown.json")
        service.notify(service.tr("service.configBackupFailed"))
        return
      }
      var wasRefused = service.configRefused
      service.configRefused = false
      service.configRefusalNotified = false
      if (wasRefused)
        service.notify(service.tr("service.configOverwriteAfterRefusal"))
      service.writeConfigNow()
    }, "refused-write")
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
      var bounded = Bounds.boundedKeys(parsed.apps, Bounds.LIMITS.stateEntries)
      if (bounded.dropped > 0)
        console.warn("omarchy-dropdown: dropdown-state.json has more than " +
          Bounds.LIMITS.stateEntries + " entries; ignoring " + bounded.dropped)
      for (var k = 0; k < bounded.keys.length; k++) {
        var id = bounded.keys[k]
        if (id === "__proto__" || id === "constructor" || id === "prototype") continue
        var entry = parsed.apps[id]
        if (!entry || !Model.validAddress(entry.address)) continue
        // Older builds recorded a parking workspace here; it is not a real
        // destination and must be dropped when the state is recovered.
        var previousWorkspace = String(entry.previousWorkspace || "")
        if (Model.isManagedSpecial(previousWorkspace)) previousWorkspace = ""
        out[id] = {
          address: String(entry.address),
          class: String(entry.class || ""),
          pid: Number(entry.pid || 0),
          hidden: entry.hidden === true,
          special: String(entry.special || Model.specialWorkspace(id)),
          previousWorkspace: previousWorkspace,
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
    if (!service.stateWritable) return
    stateSaveTimer.restart()
  }

  function saveStateNow() {
    stateSaveTimer.stop()
    // Never replace a state file that could not be read (timeout, overflow,
    // permission error). `stateWritable` is set only after a successful read
    // or a proven absence, and a one-shot retry may lift the refusal.
    if (!service.stateWritable) {
      if (!service.stateRefusalWarned) {
        service.stateRefusalWarned = true
        console.warn("omarchy-dropdown: state save skipped until dropdown-state.json can be read")
      }
      return
    }
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
        previousWorkspace: Model.isManagedSpecial(entry.previousWorkspace) ? "" : (entry.previousWorkspace || ""),
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

  BoundedProcess {
    id: terminalIdProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 4096
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.ok) {
        var id = String(result.out || "").trim().split(":")[0]
        id = id.replace(/\.desktop$/, "")
        if (id && id !== service.terminalDesktopId) {
          service.terminalDesktopId = id
        }
      }
      service.rebuildCatalog()
    }
  }

  BoundedProcess {
    id: filesIdProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 4096
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.ok) {
        var id = String(result.out || "").trim().replace(/\.desktop$/, "")
        if (id !== service.filesDesktopId) {
          service.filesDesktopId = id
        }
      }
      service.rebuildCatalog()
    }
  }

  // The default agent name is one line in a user-writable file. FileView is
  // only a change notification; the content is read through a bounded helper.
  FileView {
    id: agentView
    path: service.agentPath
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: service.readAgent()
  }

  BoundedProcess {
    id: agentReadProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.agentBytes
    maxErrBytes: 4096
    onFinished: function(result) {
      var again = service.agentReadAgain
      service.agentReadAgain = false
      if (result.overflow) {
        console.warn("omarchy-dropdown: the agent file exceeds " +
          Bounds.LIMITS.agentBytes + " bytes; ignoring it")
      } else if (result.ok) {
        service.loadAgent(result.out)
      }
      if (again && !agentReadProc.running) service.readAgent()
    }
  }

  property bool agentReadAgain: false

  function readAgent() {
    if (agentReadProc.running) {
      service.agentReadAgain = true
      return
    }
    agentReadProc.start(Bounds.fileReadCommand(service.agentPath, Bounds.LIMITS.agentBytes))
  }

  function loadAgent(raw) {
    var next = String(raw || "").trim().split("\n")[0]
    if (next === service.agentName) return
    service.agentName = next
    service.rebuildCatalog()
  }

  function refreshSystemDefaults() {
    if (!terminalIdProc.running)
      terminalIdProc.start(["xdg-terminal-exec", "--print-id"])
    if (!filesIdProc.running)
      filesIdProc.start(["xdg-mime", "query", "default", "inode/directory"])
    service.readAgent()
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
    // An explicitly cleared command ("") must not fall back to its default
    // key in the help band while commandForKey rejects that key.
    if (Object.prototype.hasOwnProperty.call(commands, name)) return String(commands[name] || "")
    return String(Model.DEFAULT_COMMANDS[name] || "")
  }

  function commandKeys() {
    return Model.commandValues(service.config.settings.commands)
  }

  function commandForKey(key) {
    return Keymap.commandForKey(
      service.config.settings.commands || Model.DEFAULT_COMMANDS, String(key || ""))
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
    return State.appState(entry, !!win, service.errors[appId], service.launching[appId],
      service.closeWatches[appId])
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
      if (!Bounds.catalogRoom(discovered.length, ordinary.length, Bounds.LIMITS.catalogApps)) {
        console.warn("omarchy-dropdown: more than " + Bounds.LIMITS.catalogApps +
          " desktop entries; ignoring the rest")
        break
      }
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
        base.detailKey = pwa ? "detail.browserWebapp" : "detail.webapp"
        discovered.push(base)
      } else {
        base.kind = "app"
        base.detail = "Desktop app"
        base.detailKey = "detail.desktopApp"
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
      detailKey: service.terminalDesktopId ? "" : "detail.noTerminal",
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
      detailKey: service.agentName ? "" : "detail.noAgent",
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
      detailKey: service.filesDesktopId ? "" : "detail.noFiles",
      available: service.filesDesktopId !== "",
      url: ""
    })

    list = list.concat(discovered)
    list = list.concat(ordinary)

    for (var j = 0; j < list.length; j++) {
      var app = list[j]
      var cfg = service.config.apps[app.id]
      app.enabled = !!(cfg && cfg.enabled === true) && app.available
      // A configured URL is an identity too: some launchers wrap a browser
      // PWA without exposing a StartupWMClass (MailFlow-style handlers).
      if (!app.url && cfg && typeof cfg.url === "string" && Model.isSafeUrl(cfg.url)) {
        app.url = String(cfg.url)
      }
      app.key = cfg && typeof cfg.key === "string" ? cfg.key : ""
      app.shortcut = cfg && typeof cfg.shortcut === "string" ? cfg.shortcut : ""
      app.geometry = cfg && cfg.geometry ? cfg.geometry : null
      app.uses = cfg ? (Number(cfg.uses) || 0) : 0
      app.lastUsed = cfg ? (Number(cfg.lastUsed) || 0) : 0
      app.launchAtLogin = !!(cfg && cfg.launchAtLogin === true)
      app.state = service.stateFor(app.id)
      var noteInfo = service.appStateNoteInfo(app)
      app.note = service.appStateNote(app)
      app.noteKey = noteInfo ? noteInfo.key : ""
      app.noteArgs = noteInfo ? noteInfo.args : []
      app.conflict = ""
      app.conflictKey = ""
      app.conflictArgs = []
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
        row.conflictKey = "conflict.paletteCommand"
        row.conflictArgs = [row.key]
        continue
      }
      var same = keyMap[row.key] || []
      var others = same.filter(function(other) { return other.id !== row.id })
      if (others.length > 0) {
        var names = others.map(function(other) { return other.name }).join(", ")
        row.conflict = "Key " + row.key + " is also used by " + names
        row.conflictKey = "conflict.alsoUsed"
        row.conflictArgs = [row.key, names]
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
        noteKey: "note.desktopMissing",
        noteArgs: [],
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
      var noteInfo = service.appStateNoteInfo(app)
      var noteKey = noteInfo ? noteInfo.key : ""
      var noteArgs = noteInfo ? noteInfo.args : []
      if (state !== app.state || note !== app.note || noteKey !== app.noteKey) {
        if (next === list) next = list.slice()
        next[i] = Object.assign({}, app, { state: state, note: note, noteKey: noteKey, noteArgs: noteArgs })
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
  BoundedProcess {
    id: bindsVerifyProc
    producerTimeoutSeconds: 3
    timeoutMs: 3500
    maxOutBytes: Bounds.LIMITS.hyprOutputBytes
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      if (result.ok) {
        service.handleBindsVerify(result.out)
        return
      }
      // A truncated or failed bind table must never be parsed as complete.
      console.warn("omarchy-dropdown: hyprctl binds verification failed (" +
        service.helperDetail(result) + ")")
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
    bindsVerifyProc.start(["hyprctl", "binds", "-j"])
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
      service.notify(service.tr("service.reapplyingShortcuts"))
      Quickshell.execDetached(["hyprctl", "reload"])
    }
  }

  // The generated binds file is written by setText; its content is read
  // through a bounded helper so a huge file can never be loaded whole.
  FileView {
    id: bindsView
    path: service.bindsPath
    atomicWrites: true
    preload: false
    printErrors: false
  }

  BoundedProcess {
    id: bindsReadProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.bindsBytes
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.overflow)
        console.warn("omarchy-dropdown: the generated binds file exceeds " +
          Bounds.LIMITS.bindsBytes + " bytes; regenerating it")
      service.finishBindsLoad(result.ok && !result.overflow ? result.out : "")
    }
  }

  function readBinds() {
    if (bindsReadProc.running) return
    bindsReadProc.start(Bounds.fileReadCommand(service.bindsPath, Bounds.LIMITS.bindsBytes))
  }

  function finishBindsLoad(raw) {
    service.bindsLoaded = true
    service.lastBindsContent = String(raw || "")
    service.syncBinds()
    service.verifyBinds()
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
      if (app.url && Model.isSafeUrl(app.url)) next.apps[app.id].url = app.url
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
    service.notify(service.tr("service.catalogRefreshed"))
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
    if (started > 0) service.notify(service.tn("service.startedHidden", started))
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
  readonly property int queueLimit: Bounds.LIMITS.queueItems
  readonly property int callbackMaxAgeMs: Bounds.LIMITS.callbackMaxAgeMs

  BoundedProcess {
    id: clientsProc
    producerTimeoutSeconds: 4
    timeoutMs: 4500
    maxOutBytes: Bounds.LIMITS.hyprOutputBytes
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      if (result.ok) {
        service.handleClients(result.out)
        return
      }
      service.handleClientsFailure(result)
    }
  }

  BoundedProcess {
    id: monitorsProc
    producerTimeoutSeconds: 4
    timeoutMs: 4500
    maxOutBytes: Bounds.LIMITS.hyprOutputBytes
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      if (result.ok) {
        service.handleMonitors(result.out)
        return
      }
      service.handleMonitorsFailure(result)
    }
  }

  BoundedProcess {
    id: dispatchProc
    producerTimeoutSeconds: 3
    timeoutMs: 4000
    maxOutBytes: 4096
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    property string currentExpression: ""
    onFinished: function(result) {
      if (!result.ok && !result.canceled) {
        service.noteHyprFailure(dispatchProc.currentExpression,
          service.helperDetail(result), result.code)
      }
      dispatchProc.currentExpression = ""
      service.pumpDispatch()
    }
  }

  // Human-readable detail for a failed helper result (console and `doctor`).
  function helperDetail(result) {
    if (!result) return "unknown failure"
    if (result.overflow) return "output limit exceeded"
    if (result.timedOut) return "timed out"
    if (result.startFailed) return "could not start"
    if (result.canceled) return "canceled"
    var detail = String(result.err || "").trim()
    if (detail) return detail
    return "exit " + result.code
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
    if (typeof callback === "function") {
      var pushed = Bounds.pushCallback(service.clientCallbacks, callback, service.queueLimit, Date.now())
      service.clientCallbacks = pushed.queue
      if (pushed.dropped > 0)
        console.warn("omarchy-dropdown: client callback queue full; dropped " +
          pushed.dropped + " oldest callback(s)")
    }
    if (clientsProc.running) {
      service.clientRefreshAgain = true
      return
    }
    clientsProc.start(["hyprctl", "clients", "-j"])
  }

  // A failed, truncated or timed-out query must not look like "every window
  // disappeared": keep the last good client list, drain the waiters and keep
  // the launch watchdog alive so a launch still times out correctly.
  function handleClientsFailure(result) {
    console.warn("omarchy-dropdown: hyprctl clients failed (" + service.helperDetail(result) +
      "); keeping the registry")
    service.checkLaunches()
    service.drainClientCallbacks()
  }

  function handleClients(raw) {
    var text = String(raw || "")
    if (!text.trim()) {
      console.warn("omarchy-dropdown: hyprctl clients returned no data; keeping the registry")
      service.drainClientCallbacks()
      return
    }
    // Repeated polls often return identical payloads; skip the JSON parse and
    // the catalog pass unless a launch is waiting for a new window.
    var hasLaunches = false
    for (var id in service.launching) hasLaunches = true
    if (text === service.lastClientsRaw && !hasLaunches) {
      service.adoptVisibleOrphans()
      // Config/state can finish loading after the first identical poll. The
      // parking migration must still run once both are available.
      service.migrateLegacyParking()
      service.checkCloseWatches()
      service.drainClientCallbacks()
      return
    }
    // A failed query must never look like "every window disappeared": that
    // would clear the registry and overwrite the state file. Keep the last
    // good client list and let the next poll retry.
    var parsed = Model.parseClientsChecked(raw)
    if (parsed === null) {
      console.warn("omarchy-dropdown: hyprctl clients returned no usable data; keeping the registry")
      service.drainClientCallbacks()
      return
    }
    service.lastClientsRaw = text
    service.clients = parsed
    service.reconcileRegistry()
    service.checkLaunches()
    service.refreshCatalogState()
    service.adoptVisibleOrphans()
    service.migrateLegacyParking()
    service.drainClientCallbacks()
  }

  function drainClientCallbacks() {
    var taken = Bounds.takeFreshCallbacks(service.clientCallbacks, Date.now(), service.callbackMaxAgeMs)
    service.clientCallbacks = []
    if (taken.stale > 0)
      console.warn("omarchy-dropdown: ignored " + taken.stale + " stale client callback(s)")
    var callbacks = taken.callbacks
    // One failing callback must not starve the others (for example the
    // pending launch callback that starts an application).
    for (var i = 0; i < callbacks.length; i++) {
      try {
        callbacks[i]()
      } catch (e) {
        console.warn("omarchy-dropdown: client callback failed: " + String(e))
      }
    }
    if (service.clientRefreshAgain) {
      service.clientRefreshAgain = false
      service.refreshClients()
    }
  }

  function refreshMonitors(callback) {
    if (typeof callback === "function") {
      var pushed = Bounds.pushCallback(service.monitorCallbacks, callback, service.queueLimit, Date.now())
      service.monitorCallbacks = pushed.queue
      if (pushed.dropped > 0)
        console.warn("omarchy-dropdown: monitor callback queue full; dropped " +
          pushed.dropped + " oldest callback(s)")
    }
    if (monitorsProc.running) return
    monitorsProc.start(["hyprctl", "monitors", "-j"])
  }

  property var monitorCallbacks: []
  property bool monitorCheckPending: false

  function takeMonitorCallbacks() {
    var taken = Bounds.takeFreshCallbacks(service.monitorCallbacks, Date.now(), service.callbackMaxAgeMs)
    service.monitorCallbacks = []
    if (taken.stale > 0)
      console.warn("omarchy-dropdown: ignored " + taken.stale + " stale monitor callback(s)")
    return taken.callbacks
  }

  function handleMonitorsFailure(result) {
    console.warn("omarchy-dropdown: hyprctl monitors failed (" + service.helperDetail(result) +
      "); keeping the previous layout")
    var pending = service.takeMonitorCallbacks()
    for (var p = 0; p < pending.length; p++) {
      try { pending[p]() } catch (e) { console.warn("omarchy-dropdown: monitor callback failed: " + String(e)) }
    }
  }

  function handleMonitors(raw) {
    var parsed = Model.parseMonitorsChecked(raw)
    if (parsed === null) {
      console.warn("omarchy-dropdown: hyprctl monitors returned no usable data; keeping the previous layout")
      var pending = service.takeMonitorCallbacks()
      for (var p = 0; p < pending.length; p++) {
        try { pending[p]() } catch (e) { console.warn("omarchy-dropdown: monitor callback failed: " + String(e)) }
      }
      return
    }
    service.monitors = parsed
    var callbacks = service.takeMonitorCallbacks()
    for (var i = 0; i < callbacks.length; i++) {
      try { callbacks[i]() } catch (e) { console.warn("omarchy-dropdown: monitor callback failed: " + String(e)) }
    }
    if (service.monitorCheckPending) {
      service.monitorCheckPending = false
      service.revalidateShownWindow()
    }
    service.adoptFocusedParked()
  }

  function monitorShowingSpecial(workspace) {
    var name = String(workspace || "")
    for (var i = 0; i < service.monitors.length; i++)
      if (String(service.monitors[i].specialWorkspace || "") === name) return service.monitors[i]
    return null
  }

  // Alt-Tab or a dock can activate the special workspace a window is parked
  // on. Adopt the window that actually owns focus as the visible dropdown
  // and put it back at the configured geometry. The window keeps its parking
  // workspace (so Escape still dismisses the special), but its position is
  // re-derived from the monitor that currently shows the special: Hyprland
  // translates parked floating windows when the special moves between
  // outputs, which used to leave them partly or fully off-screen.
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
      // A just-parked window can still own focus for a frame while the
      // special is being dismissed. Never re-adopt it in that window, or
      // Escape appears to do nothing.
      if (entry.hidden === true && entry.parkedAt && Date.now() - entry.parkedAt < 600) return
      if (entry.hidden !== true) {
        service.currentAppId = id
        if (!service.paletteOpen) service.enterEscapeMode()
        return
      }
      var app = service.findApp(id)
      var monitor = service.monitorShowingSpecial(win.workspace)
        || Model.monitorForName(service.monitors, service.monitorNameForId(win.monitor))
      var geometry = monitor && app
        ? Model.geometryFor(monitor, service.config.settings.geometry, app.geometry)
        : null
      var previousWorkspace = monitor && monitor.activeWorkspace
        ? String(monitor.activeWorkspace) : entry.previousWorkspace
      if (Model.isManagedSpecial(previousWorkspace)) previousWorkspace = ""
      service.registryNext(id, Object.assign({}, entry, {
        hidden: false,
        special: win.workspace,
        previousWorkspace: previousWorkspace,
        previousMonitor: monitor ? String(monitor.name || "") : entry.previousMonitor
      }))
      service.currentAppId = id
      service.lastAppId = id
      if (!service.paletteOpen) service.enterEscapeMode()
      service.scheduleStateSave()
      service.refreshCatalogState()
      if (geometry) {
        service.hyprBatch([
          service.floatExpr(win.address),
          service.opacityExpr(win.address, "1"),
          service.resizeExpr(win.address, geometry.width, geometry.height),
          service.placeExpr(win.address, geometry.x, geometry.y)
        ])
      }
      return
    }
  }

  // A managed window can stay visible while `currentAppId` was cleared (a
  // stale client address, a failed registry reconciliation, a shell reload).
  // In that state Escape had no current target and the window could only be
  // closed. Re-adopt the focused managed window whenever it belongs to a
  // normal workspace.
  function adoptFocusedVisible() {
    var active = Hyprland.activeToplevel
    if (!active) return
    var address = Model.normalizeAddress(active.address)
    if (!address) return
    for (var id in service.registry) {
      var entry = service.registry[id]
      if (Model.normalizeAddress(entry.address) !== address) continue
      if (entry.hidden === true) return
      var win = service.clientByAddress(address)
      if (!win || Model.isManagedSpecial(win.workspace)) return
      if (service.currentAppId !== id) {
        service.currentAppId = id
        service.lastAppId = id
        if (!service.paletteOpen) service.enterEscapeMode()
        service.refreshCatalogState()
      }
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
    if (Model.isManagedSpecial(workspace)) workspace = ""
    if (!monitor) {
      monitor = Model.monitorForName(service.monitors, "")
      var shownSpecial = monitor ? String(monitor.specialWorkspace || "") : ""
      workspace = monitor
        ? (shownSpecial !== "" && !Model.isManagedSpecial(shownSpecial)
            ? shownSpecial : String(monitor.activeWorkspace || ""))
        : ""
      if (!workspace) workspace = win.workspace
      if (Model.isManagedSpecial(workspace)) workspace = ""
      if (monitor) {
        entry = Object.assign({}, entry, { previousMonitor: monitor.name, previousWorkspace: workspace })
        service.registryNext(appId, entry)
        if (workspace) service.moveWindowToWorkspace(win.address, workspace, false)
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
    var pushed = Bounds.pushBounded(service.dispatchQueue, String(expression), service.queueLimit)
    service.dispatchQueue = pushed.queue
    if (pushed.dropped > 0)
      console.warn("omarchy-dropdown: dispatch queue full; dropped " +
        pushed.dropped + " oldest expression(s)")
    service.pumpDispatch()
  }

  function pumpDispatch() {
    if (dispatchProc.running) return
    if (service.dispatchQueue.length === 0) return
    var next = service.dispatchQueue.shift()
    dispatchProc.currentExpression = next
    dispatchProc.start(["hyprctl", "dispatch", next])
  }

  // Detached dispatches survive QML destruction (plugin disable, shell
  // restart), so parked windows can always be brought back.
  function hyprDetached(expression) {
    Quickshell.execDetached(["hyprctl", "dispatch", String(expression)])
  }

  // `hyprctl --batch` applies all expressions in one compositor pass. The
  // reveal path uses it so the window is never rendered between "park",
  // "resize", "move to workspace" and "move off screen".
  //
  // A batch that arrives while another is running is queued, never detached:
  // `execDetached` would bypass the deadline and the output caps. The queue is
  // bounded; a rejected batch still runs its callback immediately (with a
  // warning) so a reveal can never block. Every accepted batch runs its
  // callback exactly once, whatever the outcome.
  property var batchQueue: []
  property var currentBatchCallback: null

  BoundedProcess {
    id: batchProc
    producerTimeoutSeconds: 3
    timeoutMs: 4000
    maxOutBytes: 4096
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      if (!result.ok && !result.canceled)
        service.noteHyprFailure("a batched reveal", service.helperDetail(result), result.code)
      var callback = service.currentBatchCallback
      service.currentBatchCallback = null
      if (typeof callback === "function") callback()
      service.pumpBatch()
    }
  }

  function hyprBatch(expressions, callback) {
    var parts = []
    for (var i = 0; i < (expressions || []).length; i++) {
      var expr = String(expressions[i] || "")
      if (expr) parts.push("dispatch " + expr)
    }
    if (parts.length === 0) return
    var item = {
      command: ["hyprctl", "--batch", parts.join(";")],
      callback: typeof callback === "function" ? callback : null
    }
    if (batchProc.running) {
      var queued = Bounds.enqueueBatch(service.batchQueue, item, Bounds.LIMITS.batchQueueItems)
      service.batchQueue = queued.queue
      if (!queued.accepted) {
        console.warn("omarchy-dropdown: batch queue full; dropping a reveal batch")
        if (item.callback) Qt.callLater(item.callback)
      }
      return
    }
    service.startBatch(item)
  }

  function startBatch(item) {
    service.currentBatchCallback = item.callback
    if (batchProc.start(item.command)) return
    // The wrapper refused the request: settle the reveal immediately.
    service.currentBatchCallback = null
    if (typeof item.callback === "function") Qt.callLater(item.callback)
  }

  function pumpBatch() {
    if (batchProc.running) return
    if (service.batchQueue.length === 0) return
    var queue = service.batchQueue
    var next = queue.shift()
    service.batchQueue = queue
    service.startBatch(next)
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
    var opacity = Number(value)
    if (!isFinite(opacity)) opacity = 1
    opacity = Math.max(0, Math.min(1, opacity))
    return "hl.dsp.window.set_prop({ window = " + Shortcuts.luaString(service.windowSelector(address)) +
      ", prop = \"opacity\", value = " + Shortcuts.luaString(String(opacity)) + " })"
  }

  function restoreWindowOpacity(address) {
    if (!Model.validAddress(address)) return
    service.hypr(service.opacityExpr(address, "1"))
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

  // Turn a window parked by the launch preemption (floating, opacity 0,
  // tagged hidden) back into an ordinary window on a real workspace. Used
  // when the app was disabled or disappeared while it was starting, and for
  // unknown orphan windows, so a ghost can never stay invisible.
  function releaseWindowToWorkspace(address, workspace) {
    if (!Model.validAddress(address)) return
    var target = String(workspace || "")
    if (!target || Model.isManagedSpecial(target)) target = "1"
    service.hyprBatch([
      service.unfloatExpr(address),
      service.opacityExpr(address, "1"),
      service.tagExpr(address, false),
      service.moveWorkspaceExpr(address, target, false)
    ])
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
    // If a previous reveal was interrupted, restore its window to opacity 1
    // instead of abandoning it mid-fade.
    if (service.fadeAddress && Model.normalizeAddress(service.fadeAddress) !== Model.normalizeAddress(address))
      service.restoreWindowOpacity(service.fadeAddress)
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
    // A configured 0 ms duration means "no slide", not "use the default".
    var durationMs = Number(duration)
    if (!isFinite(durationMs) || durationMs < 0) durationMs = 180
    service.shellDuration = durationMs
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
    // Arrival is driven by a service timer; the card is rendered by this
    // service object, so no overlay round-trip or fallback timer is needed.
    shellArriveTimer.interval = service.shellDuration + 100
    shellArriveTimer.restart()
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

  // Called by shellArriveTimer once the card has had its full slide time.
  function shellArrived(address) {
    if (!service.shellPending || service.shellPending !== String(address || "")) return
    service.shellArrivedFlag = true
    service.startFade(address)
    service.focusWindow(address)
    shellDismissTimer.restart()
  }

  function cancelSlide() {
    service.cancelFade()
    service.shellPending = ""
    service.shellArrivedFlag = false
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
    var wasCurrent = service.currentAppId === appId
    // Forgetting an unrelated app must not cancel a reveal in progress or
    // disarm the Escape submap of the window that is actually visible.
    if (wasCurrent) {
      service.cancelSlide()
      service.leaveEscapeMode()
    }
    if (!service.registry[appId]) return
    if (Model.validAddress(service.registry[appId].address))
      service.restoreWindowOpacity(service.registry[appId].address)
    service.registryNext(appId, null)
    if (wasCurrent) service.currentAppId = ""
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
      var special = Model.specialWorkspace(app.id)
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
      service.notify(service.tr("service.reAdopted", [app.name]))
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

  // Older builds parked every app on the shared unnamed special workspace.
  // Move parked windows to their own workspace once the registry and the
  // client list agree, so Alt-Tab never shows a pile of hidden apps and no
  // window keeps a position from another monitor's scratchpad. Idempotent:
  // entries already on their own workspace are skipped.
  function migrateLegacyParking() {
    if (!service.configLoaded || !service.stateLoaded) return
    var changed = false
    for (var id in service.registry) {
      var entry = service.registry[id]
      if (!entry || entry.hidden !== true) continue
      if (service.currentAppId === id || service.launching[id]) continue
      var target = Model.specialWorkspace(id)
      if (String(entry.special || "") === target) continue
      var win = service.clientByAddress(entry.address)
      if (!win) continue
      // Only move a window that is still parked where it was recorded.
      if (String(win.workspace || "") !== String(entry.special || "")) continue
      service.moveWindowToWorkspace(win.address, target, false)
      service.registryNext(id, Object.assign({}, entry, { special: target }))
      changed = true
    }
    if (changed) {
      service.scheduleStateSave()
    }
  }

  function recoverOrphans() {
    if (!service.configLoaded) return
    // Every address already owned by a registry entry, including the dialogs
    // parked with it, must be left alone.
    var managed = {}
    for (var id in service.registry) {
      var entry = service.registry[id]
      var address = Model.normalizeAddress(entry.address)
      if (address) managed[address] = true
      var siblings = entry.siblings || []
      for (var s = 0; s < siblings.length; s++) {
        var siblingAddress = Model.normalizeAddress(siblings[s])
        if (siblingAddress) managed[siblingAddress] = true
      }
    }
    for (var i = 0; i < service.clients.length; i++) {
      var win = service.clients[i]
      var winAddress = Model.normalizeAddress(win.address)
      if (!winAddress || service.released[winAddress]) continue
      if (!Model.isManagedSpecial(win.workspace)) continue
      if (managed[winAddress]) continue
      var app = null
      for (var j = 0; j < service.catalog.length; j++) {
        if (Model.specialWorkspace(service.catalog[j].id) === win.workspace) { app = service.catalog[j]; break }
      }
      // Shared unnamed special: match by window class/title instead.
      if (!app && (win.workspace === "special" || win.workspace === "special:special")) {
        for (var k = 0; k < service.catalog.length; k++) {
          var candidate = service.catalog[k]
          if (!candidate.enabled || service.registry[candidate.id]) continue
          if (Model.windowMatches(candidate, win)) { app = candidate; break }
        }
      }
      if (app && app.enabled) {
        if (service.registry[app.id] || service.launching[app.id]) {
          // A dialog of a managed app, or a window parked by an in-flight
          // launch. Keep it on the parking workspace; never relocate it.
          service.tagWindow(win.address, true)
          managed[winAddress] = true
          continue
        }
        // A shell crash left a parked window behind: adopt it as hidden so the
        // user can call it back instead of it being unreachable.
        var adopted = {
          address: win.address,
          class: win.class,
          pid: win.pid,
          hidden: true,
          special: win.workspace,
          previousWorkspace: "",
          previousMonitor: service.monitorNameForId(win.monitor)
            || (service.monitors.length > 0 ? service.monitors[0].name : ""),
          previousFocus: "",
          since: Date.now()
        }
        service.registryNext(app.id, adopted)
        service.tagWindow(win.address, true)
        service.lastAppId = app.id
        service.scheduleStateSave()
        managed[winAddress] = true
        continue
      }
      // A window matching an app that is still launching belongs to that
      // launch; leave it parked and let finishLaunch adopt it.
      var launchingOwner = false
      for (var lid in service.launching) {
        var launchingApp = service.findApp(lid)
        if (launchingApp && Model.windowMatches(launchingApp, win)) { launchingOwner = true; break }
      }
      if (launchingOwner) continue
      // Unknown or disabled app: put the window back on a real workspace and
      // undo any preemption effect, so no session is ever trapped invisible
      // in a special workspace.
      service.releaseWindowToWorkspace(win.address, service.workspaceForWindow(win))
    }
  }

  function recoverFromSaved() {
    if (!service.stateLoaded || !service.configLoaded) return
    var saved = service.savedRegistry || {}
    var changed = false
    for (var id in saved) {
      if (service.registry[id] || service.launching[id]) continue
      var app = service.findApp(id)
      if (!app || !app.enabled) continue
      var win = service.clientByAddress(saved[id].address)
      if (!win) continue
      if (service.released[Model.normalizeAddress(win.address)]) continue
      // A forged state entry must not be able to adopt an arbitrary window.
      // Every entry written by this service carries the window class.
      if (!saved[id].class) continue
      if (saved[id].class.toLowerCase() !== String(win.class).toLowerCase()) continue
      var hidden = Model.isManagedSpecial(win.workspace)
      var parkTarget = hidden ? win.workspace : Model.specialWorkspace(id)
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

  // A real workspace for a window that must leave a parking workspace. Never
  // return another special: moving an unknown window onto it would hide it
  // somewhere the user cannot reach.
  function workspaceForWindow(win) {
    var monitor = null
    for (var i = 0; i < service.monitors.length; i++)
      if (service.monitors[i].id === win.monitor) monitor = service.monitors[i]
    if (!monitor) for (var j = 0; j < service.monitors.length; j++)
      if (service.monitors[j].focused) monitor = service.monitors[j]
    if (monitor) {
      var active = String(monitor.activeWorkspace || "")
      if (active && !Model.isManagedSpecial(active)) return active
    }
    return "1"
  }

  // ---- Launching -----------------------------------------------------------

  function startLaunch(appId, context, hiddenOnStart) {
    // A duplicate request while the app is already launching would spawn a
    // second process and leave two windows for one tab.
    if (service.launching[appId]) return
    var app = service.findApp(appId)
    if (!app) return
    if (!app.available) {
      service.failLaunch(appId, service.appNoteText(app) || service.tr("service.notConfigured"))
      return
    }
    var cmd = service.launchCommand(app)
    if (!cmd || cmd.argv.length === 0) {
      service.failLaunch(appId, service.tr("service.noLaunchCommand", [app.name]))
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
    // Arm the compositor first: hypr/dropdown.lua registers a window.open
    // handler that floats the window, moves it to its parking workspace and
    // makes it transparent in the same compositor pass that maps it. This is
    // the only mechanism that also catches windows created by an
    // already-running browser/Electron process, whose class the window-rule
    // engine cannot see in time.
    service.armLaunch(appId, app, function() {
      service.launchViaHypr(cmd)
    })
    launchWatchTimer.restart()
    launchGuardTimer.restart()
    service.notify(service.tr("service.launching", [app.name]))
    service.refreshCatalogState()
  }

  // ---- Launch preemption ---------------------------------------------------
  // The compositor holds one pending entry per app while its launch is in
  // flight. It expires after 30 s, so a shell crash can never leave a stale
  // entry that keeps parking new windows.

  property var launchArmQueue: []
  property var launchArmCurrent: null

  function armLaunchLua(appId, entry) {
    return "_dropdownPending = _dropdownPending or {}; _dropdownPending[" +
      Shortcuts.luaString(appId) + "] = { class = " + Shortcuts.luaString(entry.class || "") +
      ", title = " + Shortcuts.luaString(entry.title || "") +
      ", workspace = " + Shortcuts.luaString(entry.workspace) +
      ", expires = os.time() + 30 }"
  }

  BoundedProcess {
    id: launchArmProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 4096
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      if (!result.ok && !result.canceled) {
        var detail = service.helperDetail(result).split("\n")[0]
        console.warn("omarchy-dropdown: launch preemption unavailable" +
          (detail ? ": " + detail : " (exit " + result.code + ")"))
      }
      var current = service.launchArmCurrent
      service.launchArmCurrent = null
      if (current && typeof current.callback === "function") current.callback()
      // Autostart can request several entries before the first eval returns.
      Qt.callLater(function() { service.pumpLaunchArm() })
    }
  }

  function armLaunch(appId, app, callback) {
    var cls = Model.launchClassMatch(app)
    var entry = {
      class: cls,
      // A title is only a fallback for apps with no usable class. Matching a
      // page-controlled title when the class is known would let a browser
      // tab that happens to carry the app name be parked by mistake.
      title: cls === "" ? Model.launchTitleMatch(app) : "",
      workspace: Model.specialWorkspace(appId)
    }
    // Nothing predictable to match: launch directly, the openwindow fallback
    // and the 20 s adoption watcher still apply.
    if (entry.class === "" && entry.title === "") {
      if (typeof callback === "function") Qt.callLater(callback)
      return
    }
    // Saturation must not lose the launch: start it without preemption. The
    // callback runs exactly once, through the event loop.
    if (service.launchArmQueue.length >= Bounds.LIMITS.launchArmItems) {
      console.warn("omarchy-dropdown: launch preemption queue full; launching " +
        appId + " without preemption")
      if (typeof callback === "function") Qt.callLater(callback)
      return
    }
    service.launchArmQueue.push({
      appId: String(appId),
      entry: entry,
      callback: typeof callback === "function" ? callback : null
    })
    service.pumpLaunchArm()
  }

  function pumpLaunchArm() {
    if (launchArmProc.running) return
    if (service.launchArmQueue.length === 0) return
    var item = service.launchArmQueue.shift()
    service.launchArmCurrent = item
    launchArmProc.start(["hyprctl", "eval", service.armLaunchLua(item.appId, item.entry)])
  }

  // Fire and forget: the reveal must not wait for the compositor to forget
  // the entry, and the 30 s expiry is the safety net.
  function disarmLaunch(appId) {
    Quickshell.execDetached(["hyprctl", "eval",
      "if _dropdownPending then _dropdownPending[" + Shortcuts.luaString(appId) + "] = nil end"])
  }

  Timer {
    id: launchWatchTimer
    interval: 300
    repeat: true
    running: false
    onTriggered: service.refreshClients()
  }

  // Watchdog: the launch deadline must expire even when `hyprctl clients`
  // fails, times out or its output is truncated, so `handleClients` is never
  // the only path to a timeout.
  Timer {
    id: launchGuardTimer
    interval: 1000
    repeat: true
    running: false
    onTriggered: service.checkLaunches()
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

  // Every app gets its own named special workspace. Hyprland creates it the
  // first time the app is parked (a window move creates the workspace on
  // demand), so unrelated hidden apps never share one scratch workspace and
  // the unnamed special is left to the user.

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

  function launchViaHypr(cmd) {
    if (!cmd || !cmd.argv || cmd.argv.length === 0) return false
    var command = cmd.argv.map(function(part) { return Shortcuts.shellQuote(part) }).join(" ")
    if (cmd.cwd) command = "cd " + Shortcuts.shellQuote(cmd.cwd) + " && " + command
    // Fallback only: the compositor window.open hook is what actually parks
    // the window. Exec rules follow the spawned PID and cannot apply to a
    // window created by an already-running browser process. This rule targets
    // the unnamed special because Hyprland drops a `special:name silent`
    // target it cannot create in the same pass; the openwindow preempt then
    // moves the window to its own named special.
    service.hyprDetached("hl.dsp.exec_cmd(" + Shortcuts.luaString(command) + ", { workspace = " +
      Shortcuts.luaString("special:special silent") +
      ", float = true, opacity = \"0\" })")
    return true
  }

  function checkLaunches() {
    var hasLaunches = false
    for (var id in service.launching) hasLaunches = true
    if (!hasLaunches) {
      launchWatchTimer.stop()
      launchGuardTimer.stop()
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
    if (Object.keys(next).length > 0) {
      launchWatchTimer.start()
      launchGuardTimer.start()
    } else {
      launchWatchTimer.stop()
      launchGuardTimer.stop()
    }
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
    service.disarmLaunch(appId)
    var app = service.findApp(appId)
    var orphanTarget = state.context && state.context.workspace
      ? state.context.workspace : service.workspaceForWindow(win)
    // The compositor already floated and made the window transparent. If the
    // app vanished or was disabled while it was starting, undo that instead
    // of leaving an untracked invisible window behind.
    if (!app) {
      service.releaseWindowToWorkspace(win.address, orphanTarget)
      return
    }
    if (!app.enabled || app.state === "error") {
      service.releaseWindowToWorkspace(win.address, orphanTarget)
      return
    }
    var entry = {
      address: win.address,
      class: win.class,
      pid: win.pid,
      hidden: false,
      special: Model.specialWorkspace(appId),
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
    service.revealApp(appId, state.context, win)
  }

  function handleLaunchTimeout(appId) {
    var app = service.findApp(appId)
    if (!app) return
    var existing = service.findUnmanagedWindow(app)
    if (existing) {
      service.setAdoptable(appId, existing.address)
      service.failLaunch(appId, service.tr("service.alreadyOpenOutside", [app.name]))
    } else {
      var expected = app.expectedClass || app.desktopId || app.id
      service.failLaunch(appId, service.tr("service.noWindowAppeared", [
        app.name, service.number(Math.round(service.launchTimeoutMs / 1000)), expected
      ]))
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
      if (Model.windowMatchesClass(app, win)) return win
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
    service.disarmLaunch(appId)
    var next = {}
    for (var id in service.launching) if (id !== appId) next[id] = service.launching[id]
    service.launching = next
    if (Object.keys(next).length === 0) {
      launchWatchTimer.stop()
      launchGuardTimer.stop()
    }
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
    // A dropdown shown from a focus on a parked window must not treat its
    // parking workspace as the destination.
    if (special && special.name && Model.isManagedSpecial(special.name)) special = null
    var ws = special && special.name ? special : (monitor ? monitor.activeWorkspace : null)
    var workspace = ws ? String(ws.name || "") : ""
    if (Model.isManagedSpecial(workspace)) workspace = ""
    if (!workspace && Hyprland.focusedWorkspace) workspace = String(Hyprland.focusedWorkspace.name || "")
    return { monitor: monitorName || (monitor ? String(monitor.name || "") : ""), workspace: workspace }
  }

  function toggleApp(appId, context, ignoreConflict) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    if (!app.enabled) return { ok: false, message: service.tr("service.notManagedBy", [app.name]) }
    // A conflicting key blocks key dispatch, never an explicit open by id
    // (Enter, a click, or a preview card).
    if (app.conflict && ignoreConflict !== true) return { ok: false, message: service.appConflictText(app) + "." }
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
    if (service.launching[appId]) return { ok: false, message: service.tr("service.stillLaunchingApp", [app.name]) }
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
          special: Model.specialWorkspace(appId),
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
    // A managed parking workspace is never a real destination. Old state
    // files recorded it as `previousWorkspace`, which used to send restored
    // and popped-out windows back onto a hidden special.
    if (Model.isManagedSpecial(workspace)) workspace = ""
    var monitor = service.liveMonitor(targetName)
    if (monitor) {
      // A pinned screen always uses that screen's current workspace, never a
      // stale workspace captured before a workspace switch.
      if (fixed || !workspace) {
        var special = monitor.specialWorkspace
        var ws = special && special.name && !Model.isManagedSpecial(special.name)
          ? special : monitor.activeWorkspace
        if (ws && ws.name) workspace = String(ws.name)
      }
      ctx.monitor = String(monitor.name || targetName)
    } else {
      var cached = Model.monitorForName(service.monitors, targetName)
      if (cached) {
        if (fixed || !workspace) {
          var cachedSpecial = String(cached.specialWorkspace || "")
          workspace = !Model.isManagedSpecial(cachedSpecial) && cachedSpecial !== ""
            ? cachedSpecial : String(cached.activeWorkspace || workspace)
        }
        ctx.monitor = String(cached.name || targetName)
      }
    }
    if (!workspace) workspace = "1"
    return { monitor: ctx.monitor || "", workspace: workspace }
  }

  function revealApp(appId, context, knownWindow, monitorsRetried) {
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!app || !entry) return
    // No monitor data means no safe absolute placement: geometryFor(null)
    // would return (0, 0), which is off-screen on a layout whose first output
    // does not start at the origin. Refresh once and retry, then give up and
    // leave the window parked rather than placing it where the user cannot
    // reach it.
    if (!service.monitors || service.monitors.length === 0) {
      if (monitorsRetried === true) return
      service.refreshMonitors(function() {
        service.revealApp(appId, context, knownWindow, true)
      })
      return
    }
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
      parkedAt: 0,
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
    var fade = service.revealMotionEnabled()
    var batch = []
    var fs = service.unsetFullscreenExpr(win.address, win)
    if (fs) batch.push(fs)
    batch.push(service.floatExpr(win.address))
    // Invisible during placement; a fresh window also stays invisible while
    // it paints, so no grey/white block is shown. The compositor hook already
    // mapped it at opacity 0, so a reduced-motion reveal must restore it
    // explicitly instead of relying on the fade.
    if (fade) batch.push(service.opacityExpr(win.address, "0"))
    else batch.push(service.opacityExpr(win.address, "1"))
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
    service.notify(service.tr("service.shown", [app.name]))
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
    // Each app has its own special workspace; the move creates it on demand.
    var special = Model.specialWorkspace(appId)
    var short = special.indexOf("special:") === 0 ? special.slice(8) : special
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
      service.hypr("hl.dsp.workspace.toggle_special(" + Shortcuts.luaString(short) + ")")
    }
    service.tagWindow(win.address, true)
    for (var k = 0; k < siblings.length; k++) service.tagWindow(siblings[k], true)
    // Hiding a window that is already on a special workspace (it was adopted
    // from Alt-Tab) must not overwrite the real workspace it came from, or a
    // later pop-out/restore sends it back to a hidden special.
    var onSpecial = Model.isManagedSpecial(win.workspace)
    var previousWorkspace = onSpecial ? entry.previousWorkspace : win.workspace
    if (Model.isManagedSpecial(previousWorkspace)) previousWorkspace = ""
    var updated = Object.assign({}, entry, {
      hidden: true,
      special: special,
      siblings: siblings,
      parkedAt: Date.now(),
      previousWorkspace: previousWorkspace,
      previousMonitor: onSpecial ? entry.previousMonitor : service.monitorNameForId(win.monitor)
    })
    service.registryNext(appId, updated)
    if (service.currentAppId === appId) service.currentAppId = ""
    service.lastAppId = appId
    if (restoreFocus !== false) service.restoreFocusLater(entry.previousFocus)
    service.notify(service.tr("service.hidden", [app ? app.name : appId]))
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
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    if (service.launching[appId]) return { ok: false, message: service.tr("service.stillLaunchingApp", [app.name]) }
    var entry = service.registry[appId]
    var win = entry ? service.clientByAddress(entry.address) : null
    if (!entry || !win) {
      service.forgetApp(appId)
      return { ok: false, message: service.tr("service.notRunning", [app.name]) }
    }
    if (entry.hidden) {
      // Bring it back on screen first, so a quit confirmation dialog is not
      // stranded on the parked workspace.
      service.revealApp(appId, context || service.focusedContext())
    }
    service.closeWindow(win.address)
    var watches = {}
    for (var watchId in service.closeWatches) watches[watchId] = service.closeWatches[watchId]
    watches[appId] = Date.now()
    service.closeWatches = watches
    closeWatchTimer.restart()
    service.notify(service.tr("service.closing", [app.name]))
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
      service.notify(service.tr("service.waitingConfirmation", [app ? app.name : id]))
    }
    if (changed) {
      service.closeWatches = next
      service.refreshCatalogState()
    }
    if (Object.keys(service.closeWatches).length > 0) closeWatchTimer.restart()
    else closeWatchTimer.stop()
  }

  // A close request is not always answered by a client event; expire the
  // "waiting for confirmation" notice even when the client list is stable.
  Timer {
    id: closeWatchTimer
    interval: Math.max(1000, service.closeConfirmMs + 100)
    onTriggered: service.checkCloseWatches()
  }

  function hideVisibleCurrent() {
    var appId = service.currentAppId
    if (!appId) return { ok: false, message: service.tr("service.noDropdownOpen") }
    var entry = service.registry[appId]
    if (!entry || entry.hidden) return { ok: false, message: service.tr("service.noDropdownOpen") }
    service.parkApp(appId, true)
    return { ok: true, appId: appId }
  }

  function hideTarget() {
    var appId = service.paletteTarget
    if (!appId) return { ok: false, message: service.tr("service.noDropdownOpen") }
    var entry = service.registry[appId]
    if (!entry) return { ok: false, message: service.tr("service.noDropdownOpen") }
    if (entry.hidden) return { ok: false, message: service.tr("service.alreadyHidden") }
    if (service.launching[appId]) return { ok: false, message: service.tr("service.stillLaunching") }
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
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    var win = null
    if (service.adoptable[appId]) win = service.clientByAddress(service.adoptable[appId])
    if (!win) win = service.findUnmanagedWindow(app)
    if (!win) return { ok: false, message: service.tr("service.noWindowOf", [app.name]) }
    if (service.addressManaged(win.address)) return { ok: false, message: service.tr("service.alreadyManaged") }
    var entry = {
      address: win.address,
      class: win.class,
      pid: win.pid,
      hidden: Model.isManagedSpecial(win.workspace),
      special: Model.isManagedSpecial(win.workspace) ? String(win.workspace) : Model.specialWorkspace(appId),
      // A window adopted while already parked has no real workspace to
      // remember; storing the special would send it back there on restore.
      previousWorkspace: Model.isManagedSpecial(win.workspace) ? "" : win.workspace,
      previousMonitor: service.monitorNameForId(win.monitor),
      previousFocus: "",
      since: Date.now()
    }
    service.registryNext(appId, entry)
    service.tagWindow(win.address, entry.hidden)
    service.setAdoptable(appId, "")
    service.setError(appId, "")
    service.lastAppId = appId
    if (entry.hidden) service.notify(service.tr("service.adoptedHidden", [app.name]))
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
    if (!entry) return { ok: false, message: service.tr("service.notManaged", [app ? app.name : appId]) }
    var win = service.clientByAddress(entry.address)
    var address = win ? win.address : ""
    var result = service.releaseApp(appId)
    if (!result.ok) return result
    if (address) {
      service.unfloatWindow(address)
      service.focusWindow(address)
    }
    service.notify(service.tr("service.poppedOut", [app ? app.name : appId]))
    return { ok: true, appId: appId }
  }

  function releaseApp(appId) {
    var app = service.findApp(appId)
    var entry = service.registry[appId]
    if (!entry) return { ok: false, message: service.tr("service.notManaged", [app ? app.name : appId]) }
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
    service.notify(service.tr("service.released", [app ? app.name : appId]))
    return { ok: true, appId: appId }
  }

  // ---- Configuration actions ----------------------------------------------

  function setEnabled(appId, enabled) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    if (enabled && !app.available) return { ok: false, message: service.tr("service.notAvailable", [app.name, service.appNoteText(app)]) }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    var cfg = next.apps[appId]
    if (app.url) cfg.url = app.url
    if (cfg.url && !Model.isSafeUrl(cfg.url)) delete cfg.url
    if (enabled) {
      var system = Model.enabledSystemMap(next)
      if (app.kind === "system") system[app.system] = true
      var reserved = Model.reservedKeys(system)
      var commands = service.config.settings.commands
      var key = String(cfg.key || "")
      if (!key && app.kind === "system") {
        // Prefer the conventional t/i/f key, but never fail activation just
        // because another app already owns it.
        var conventional = Model.SYSTEM_KEYS[app.system]
        if (conventional && Model.validateKey(conventional, appId, service.catalog, system, commands).ok)
          key = conventional
      }
      if (!key) key = Model.firstFreeKey(app.name, service.usedKeys(), reserved)
      if (!key) return { ok: false, message: service.tr("service.noFreeKey", [app.name]) }
      var check = Model.validateKey(key, appId, service.catalog, system, commands)
      if (!check.ok) {
        var fallback = Model.firstFreeKey(app.name, service.usedKeys(), reserved)
        if (fallback && fallback !== key) {
          key = fallback
          check = Model.validateKey(key, appId, service.catalog, system, commands)
        }
      }
      if (!check.ok) return { ok: false, message: service.keyErrorMessage(check) }
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
    if (!next.apps[appId]) return { ok: false, message: service.tr("service.nothingToRemove") }
    delete next.apps[appId]
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.notify(service.tr("service.removedMissing", [appId]))
    return { ok: true, appId: appId }
  }

  function applyAppShortcut(appId, chord) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
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
    bindsCheckTimeout.stop()
    service.pendingShortcut = null
    service.shortcutCheckGeneration++
    bindsCheckProc.cancel()
  }

  function validateShortcut(appId, value) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    if (!app.enabled) return { ok: false, message: service.tr("notice.enableBeforeShortcut", [app.name]) }
    var raw = String(value || "").trim()
    var chord = Model.normalizeShortcut(raw)
    if (raw !== "" && chord === "")
      return { ok: false, message: service.tr("notice.shortcutInvalid") }
    var check = Shortcuts.validateShortcut(service.enabledApps, appId, chord)
    if (!check.ok) return { ok: false, message: service.shortcutMessage(check) }
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
      if (cleared.ok) service.notify(service.tr("service.directShortcutCleared", [app.name]))
      return cleared
    }
    if (app.shortcut === chord) return { ok: true, shortcut: chord }
    if (bindsCheckProc.running || service.pendingShortcut)
      return { ok: false, message: service.tr("service.shortcutCheckRunning") }
    service.shortcutCheckGeneration++
    service.pendingShortcut = {
      appId: appId,
      chord: chord,
      generation: service.shortcutCheckGeneration
    }
    if (!bindsCheckProc.start(["hyprctl", "binds", "-j"], service.shortcutCheckGeneration)) {
      service.pendingShortcut = null
      return { ok: false, message: service.tr("service.shortcutCheckRunning") }
    }
    bindsCheckTimeout.restart()
    return { ok: true, pending: true, shortcut: chord }
  }

  // A missing/failed `hyprctl binds` must not leave the capture UI stuck on
  // "Checking" forever and block every later shortcut assignment. The timer
  // really terminates the helper (SIGTERM, then SIGKILL inside the component).
  // The request generation makes a late or cancelled result from an older
  // request unable to clear a newer pending one; every terminal path emits
  // either `shortcutAssigned` or `shortcutRejected`.
  Timer {
    id: bindsCheckTimeout
    interval: 4000
    onTriggered: {
      var pending = service.pendingShortcut
      service.pendingShortcut = null
      service.shortcutCheckGeneration++
      bindsCheckProc.cancel()
      if (!pending) return
      service.shortcutRejected(pending.appId, service.tr("service.shortcutCheckTimeout"))
    }
  }

  function finishShortcutCheck(raw, generation) {
    bindsCheckTimeout.stop()
    if (generation !== undefined &&
        !Bounds.isCurrentGeneration(generation, service.shortcutCheckGeneration)) return
    var pending = service.pendingShortcut
    service.pendingShortcut = null
    service.shortcutCheckGeneration++
    if (!pending) return
    var app = service.findApp(pending.appId)
    if (!app) {
      service.shortcutRejected(pending.appId, service.tr("service.unknownApplication"))
      return
    }
    var binds = []
    try { binds = JSON.parse(String(raw || "[]")) } catch (e) { binds = [] }
    if (!Array.isArray(binds)) binds = []
    var mask = Model.shortcutModmask(pending.chord)
    var key = Model.hyprBindKey(pending.chord)
    var info = Shortcuts.bindConflictInfo(binds, mask, key, app.name, app.shortcut, pending.chord)
    if (info) {
      var description = info.description || strings.t("shortcut.existingBind")
      var conflict = info.submap
        ? service.tr("shortcut.bindConflictSubmap", [info.chord, description, info.submap])
        : service.tr("shortcut.bindConflict", [info.chord, description])
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
    service.notify(service.tr("service.directShortcut", [app.name, pending.chord]))
    service.shortcutAssigned(pending.appId, pending.chord)
  }

  BoundedProcess {
    id: bindsCheckProc
    producerTimeoutSeconds: 3
    timeoutMs: 3500
    maxOutBytes: Bounds.LIMITS.hyprOutputBytes
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      // Ignore a result that belongs to a superseded request before touching
      // `pendingShortcut` or the watchdog: an old cancelled result must never
      // erase or disarm a newer request.
      if (!Bounds.isCurrentGeneration(result.tag, service.shortcutCheckGeneration)) return
      bindsCheckTimeout.stop()
      if (result.ok) {
        service.finishShortcutCheck(result.out, result.tag)
        return
      }
      var pending = service.pendingShortcut
      if (!pending) return
      service.pendingShortcut = null
      service.shortcutCheckGeneration++
      service.shortcutRejected(pending.appId, service.tr("service.shortcutCheckTimeout"))
    }
  }

  function assignKey(appId, key) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    var check = Model.validateKey(key, appId, service.catalog, Model.enabledSystemMap(service.config), service.config.settings.commands)
    if (!check.ok) {
      check.message = service.keyErrorMessage(check)
      return check
    }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    next.apps[appId].key = Model.normalizeKeyChar(key)
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
    service.scheduleConfigSave(true)
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
    service.notify(service.tr("service.sizeReset"))
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
    service.notify(service.tr("service.sizeOverrideCleared"))
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
      if (next) service.openPalette(next.view, next.monitor, next.force === true)
    }
  }

  function openPalette(view, monitorName, forceMonitor) {
    var requested = String(monitorName || "")
    // Moving the palette between outputs: close the old surface first, then
    // open a fresh one on the requested screen. A layer surface is bound to
    // one output for its lifetime, so re-binding is not reliable.
    if (service.paletteOpen && requested && service.paletteMonitor
        && requested !== service.paletteMonitor) {
      service.pendingPaletteOpen = {
        view: view || "palette",
        monitor: requested,
        force: forceMonitor === true
      }
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
        service.openPalette(view, monitorName, true)
        return
      }
      if (service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
      return
    }
    // The bar widget is per screen: its output wins over the configured one.
    service.openPalette(view, monitorName, monitorName !== "")
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
    if (list.length === 0) return { ok: false, message: service.tr("service.noOpenWindow") }
    if (list.length === 1) return { ok: false, message: service.tr("service.onlyOneWindow") }
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
    service.cancelSlide()
    autoHideTimer.stop()
    launchWatchTimer.stop()
    launchGuardTimer.stop()
    focusRestoreTimer.stop()
    service.focusRestoreAddress = ""
    for (var launchingId in service.launching) service.disarmLaunch(launchingId)
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
      // Never restore a window onto a Dropdown parking workspace.
      var target = Model.isManagedSpecial(entry.previousWorkspace) ? "1" : (entry.previousWorkspace || "1")
      service.hyprDetached(service.moveWorkspaceExpr(entry.address, target, false))
      var siblings = entry.siblings || []
      for (var i = 0; i < siblings.length; i++) {
        if (!Model.validAddress(siblings[i])) continue
        service.hyprDetached(service.moveWorkspaceExpr(siblings[i], target, false))
      }
    }
    service.registry = {}
    service.launching = ({})
    service.closeWatches = ({})
    service.errors = ({})
    service.adoptable = ({})
    service.released = ({})
    service.savedRegistry = {}
    service.cancelShortcutRequest()
    service.currentAppId = ""
    service.lastAppId = ""
    service.paletteOpen = false
    service.paletteTarget = ""
    service.paletteMonitor = ""
    service.paletteWorkspace = ""
    service.palettePreviousFocus = ""
    service.notice = ""
    service.saveStateNow()
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
    service.readConfig()
    service.readState()
    service.readBinds()
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
      service.adoptFocusedVisible()
      service.maybeAutoHide()
    }
    function onFocusedWorkspaceChanged() {
      service.maybeAutoHide()
    }
  }

  // The compositor hook parks a launched window before it is painted. This
  // fallback covers an older ~/.config/hypr/dropdown.lua without the hook, or
  // a window whose class/title does not match the armed entry. Park it on
  // the openwindow event instead of letting it sit tiled and visible until
  // the 35-300 ms client poll adopts it. `follow = false` keeps the special
  // workspace hidden.
  function preemptLaunchedWindow(event) {
    var parts = []
    try {
      if (event && typeof event.parse === "function") parts = event.parse(4)
    } catch (e) {
      parts = []
    }
    if (!parts || parts.length < 3) {
      var text = String(event && event.data ? event.data : "")
      if (!text) return
      parts = text.split(",")
    }
    if (parts.length < 3) return
    var address = Model.normalizeAddress(parts[0])
    if (!address || service.addressManaged(address)) return
    // The compositor hook already moved the window to its parking workspace;
    // the openwindow event reports the workspace it mapped on.
    if (Model.isManagedSpecial(String(parts[1] || ""))) return
    var win = {
      address: address,
      class: String(parts[2] || ""),
      initialClass: String(parts[2] || ""),
      title: parts.slice(3).join(",")
    }
    for (var appId in service.launching) {
      var app = service.findApp(appId)
      if (!app || !Model.windowMatches(app, win)) continue
      var batch = []
      batch.push("dispatch " + service.floatExpr(address))
      batch.push("dispatch " + service.opacityExpr(address, "0"))
      batch.push("dispatch " + service.moveWorkspaceExpr(address, Model.specialWorkspace(appId), false))
      // This fallback must park the window even if the service is torn down
      // while the window is mapping, so it stays detached on purpose. It is
      // the only detached batch and is explicitly bounded: `timeout -k 1 3`
      // stops a hung `hyprctl`. Its output is not captured; the client poll
      // re-parks the window if the dispatch did not apply.
      Quickshell.execDetached(["timeout", "-k", "1", "3", "hyprctl", "--batch",
        batch.join(";")])
      return
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = String(event.name || "")
      if (name === "openwindow") service.preemptLaunchedWindow(event)
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

  // A real left click while a dropdown is visible is reported by the
  // apach-dropdown submap bind in hypr/dropdown.lua. It hides the dropdown
  // immediately, like Escape, when the click lands outside the window; clicks
  // inside it (or on its dialogs) are ignored. Pointer moves and focus changes
  // keep the configured delay.
  property string clickCheckAppId: ""
  property string clickCheckAddress: ""

  function checkOutsideClick() {
    if (service.paletteOpen) return
    if (cursorProc.running) return
    var id = service.currentAppId
    if (!id) return
    var entry = service.registry[id]
    if (!entry || entry.hidden) return
    service.clickCheckAppId = id
    service.clickCheckAddress = entry.address
    cursorProc.start(["hyprctl", "-j", "cursorpos"])
  }

  BoundedProcess {
    id: cursorProc
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: 4096
    maxErrBytes: 4096
    onFinished: function(result) {
      if (result.ok) {
        service.handleClickPointer(result.out)
        return
      }
      // A pointer query that never answers must not leave a stale click check
      // armed and block the next one.
      service.clickCheckAppId = ""
      service.clickCheckAddress = ""
      if (!result.canceled)
        console.warn("omarchy-dropdown: cursor position query failed (" +
          service.helperDetail(result) + ")")
    }
  }

  function handleClickPointer(raw) {
    var id = service.clickCheckAppId
    var address = service.clickCheckAddress
    service.clickCheckAppId = ""
    service.clickCheckAddress = ""
    if (!id || id !== service.currentAppId) return
    if (service.paletteOpen) return
    var entry = service.registry[id]
    if (!entry || entry.hidden) return
    var win = service.clientByAddress(address)
    if (!win) return
    var point = Model.parseCursorPoint(raw)
    if (!point) return
    if (Model.rectContains(win.at, win.size, point)) return
    // A click on a dropdown dialog counts as inside the dropdown.
    var active = Hyprland.activeToplevel
    var activeAddress = active ? Model.normalizeAddress(active.address) : ""
    var activeWin = activeAddress ? service.clientByAddress(activeAddress) : null
    if (activeWin && service.isSibling(win, activeWin)) return
    // The bar and other reserved edges are layer surfaces: a click there is
    // not an outside click for the dropdown (the bar widget opens the palette).
    if (service.pointOverBar(point)) return
    service.parkApp(id, false)
  }

  function pointOverBar(point) {
    for (var i = 0; i < service.monitors.length; i++) {
      var box = Model.monitorBox(service.monitors[i])
      if (!box) continue
      if (!Model.rectContains([box.x, box.y], [box.width, box.height], point)) continue
      var r = box.reserved || [0, 0, 0, 0]
      if (point.x < box.x + (r[0] || 0) || point.x >= box.x + box.width - (r[2] || 0)
          || point.y < box.y + (r[1] || 0) || point.y >= box.y + box.height - (r[3] || 0))
        return true
    }
    return false
  }

  function setLaunchAtLogin(appId, value) {
    var app = service.findApp(appId)
    if (!app) return { ok: false, message: service.tr("service.unknownApplication") }
    var next = Model.clone(service.config)
    if (!next.apps[appId]) next.apps[appId] = {}
    if (!next.apps[appId].key) next.apps[appId].key = app.key || ""
    next.apps[appId].launchAtLogin = value === true
    service.config = next
    service.saveConfigNow()
    service.rebuildCatalog()
    service.notify(service.tr(value ? "service.startAtLogin" : "service.noStartAtLogin", [app.name]))
    return { ok: true, appId: appId }
  }

  function setCommandKey(name, key) {
    var value = Model.normalizeKeyChar(key)
    var commands = service.config.settings.commands || Model.DEFAULT_COMMANDS
    if (!commands[name]) return { ok: false, message: service.tr("service.unknownCommand") }
    if (!value) return { ok: false, message: service.tr("service.invalidCommandKey") }
    for (var other in commands) {
      if (other !== name && String(commands[other]) === value)
        return { ok: false, message: service.tr("service.keyAlreadyUsed", [value, other]) }
    }
    for (var i = 0; i < service.enabledApps.length; i++) {
      if (String(service.enabledApps[i].key) === value)
        return { ok: false, message: service.tr("service.keyAssignedApp", [value, service.enabledApps[i].name]) }
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
    service.notify(service.tr("service.shortcutsReset"))
  }

  function reduceCurrent() {
    if (service.paletteOpen) {
      var target = service.paletteTarget
      if (target) service.hideTarget()
      if (service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
      return { ok: true, message: "" }
    }
    if (!service.currentAppId) {
      // Recover a visible managed window whose current pointer was lost, so
      // Escape always hides the dropdown that is actually in front.
      var active = Hyprland.activeToplevel
      var address = active ? Model.normalizeAddress(active.address) : ""
      if (address) {
        for (var id in service.registry) {
          var entry = service.registry[id]
          if (Model.normalizeAddress(entry.address) !== address) continue
          if (entry.hidden === true) break
          var win = service.clientByAddress(address)
          if (!win || Model.isManagedSpecial(win.workspace)) break
          service.currentAppId = id
          break
        }
      }
    }
    if (service.currentAppId) {
      var app = service.findApp(service.currentAppId)
      service.parkApp(service.currentAppId, true)
      return { ok: true, message: service.tr("service.hidden", [app ? app.name : strings.t("tooltip.idle")]) }
    }
    return { ok: false, message: service.tr("service.noDropdownOpen") }
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
        hyprError: redact ? (service.hyprError ? "an error is recorded" : "") : service.hyprError,
        lastHyprErrorAt: service.lastHyprErrorAt,
        current: redact ? "" : service.currentAppId,
        last: redact ? "" : service.lastAppId,
        palette: service.paletteOpen,
        registry: redact ? registered.map(function() { return "app" }) : registered,
        monitors: service.monitors.map(function(m) { return m.name }),
        clients: service.clients.length,
        launching: redact
          ? Object.keys(service.launching).map(function() { return "app" })
          : Object.keys(service.launching),
        pendingShortcut: redact ? null : service.pendingShortcut,
        errors: redact ? {} : service.errors,
        conflicts: redact ? {} : service.conflicts,
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
    function clicked(): void { service.checkOutsideClick() }
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
          textFormat: Text.PlainText
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
