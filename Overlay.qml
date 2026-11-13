// Omarchy Dropdown palette and menus.
//
// A single compact layer-shell window anchored below the bar on the monitor
// that was focused when the palette was summoned. It is a thin view over
// Service.qml: all window management and persistence live there.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model
import "js/Keymap.js" as Keymap
import "js/Bounds.js" as Bounds
import "components"

Item {
  id: overlay

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function tr(key, args, fallback) {
    var value = strings.t(key, fallback)
    for (var i = 0; i < (args || []).length; i++) value = value.arg(String(args[i]))
    return value
  }

  function number(value) {
    return Commons.I18n.formatNumber(value)
  }

  function enumLabel(prefix, value) {
    return strings.t(prefix + "." + String(value), String(value || ""))
  }

  function appConflictText(app) {
    if (!app || !app.conflict) return ""
    return tr(app.conflictKey, app.conflictArgs, app.conflict)
  }

  function appSecondaryText(app) {
    if (!app) return ""
    if (app.noteKey) return tr(app.noteKey, app.noteArgs, app.note)
    if (app.detailKey) return strings.t(app.detailKey, app.detail)
    return String(app.note || app.detail || "")
  }

  // Translate a row model built by manageRows/helpRows/keyRows. Called from
  // text bindings so a language switch re-renders without rebuilding rows.
  function rowLabel(row) {
    if (!row) return ""
    if (row.headerKey) {
      return strings.tn(row.headerKey, row.count).arg(Commons.I18n.formatNumber(row.count))
    }
    if (row.helpKind === "app") {
      var conflict = row.conflictKey ? tr(row.conflictKey, row.conflictArgs, row.conflict) : String(row.conflict || "")
      return conflict ? strings.t("help.appConflictRow").arg(row.appName).arg(conflict) : String(row.appName || "")
    }
    if (row.helpKind === "system") {
      var detail = row.detailKey ? strings.t(row.detailKey, row.detail) : String(row.detail || "")
      var status = row.enabled ? strings.t("help.enabled") : strings.t("help.disabled")
      return strings.t("help.systemRow").arg(row.appName).arg(status).arg(detail)
    }
    if (row.labelKey) return tr(row.labelKey, row.labelArgs)
    return String(row.label || "")
  }

  property var service: null
  property bool opened: false
  property bool closing: false
  property string screenName: ""
  property string view: "palette"
  property string backView: "palette"
  property string localNotice: ""
  property bool localNoticeUrgent: false
  property bool assigning: false
  property string assignAppId: ""
  property bool assigningShortcut: false
  property bool shortcutChecking: false
  property string shortcutError: ""
  property string shortcutAppId: ""
  property string shortcutSuggestion: ""
  property var shortcutUsed: []
  property string shortcutPendingChord: ""
  property bool quitMode: false
  property bool popoutMode: false
  property string previewReservedFlash: ""
  property string barSection: ""
  property int barIndex: -1
  property var barSizes: ({ left: 0, center: 0, right: 0 })
  property string pendingBarSection: ""
  property int pendingBarIndex: -1
  property bool pendingBarTouched: false
  property bool barMoveRunning: false
  property bool barMoveDirty: false
  readonly property string shellConfigPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/omarchy/shell.json"
  property string assigningCommand: ""
  property string appSizeId: ""
  property string search: ""
  property bool searchFocused: true
  property int sel: 0
  property var rows: []
  property string armedRemoveId: ""

  readonly property var settings: service ? service.config.settings : Model.DEFAULT_CONFIG.settings
  readonly property var geometry: settings.geometry
  readonly property var animations: settings.animations
  readonly property string tabPosition: {
    var tabs = settings && settings.tabs ? settings.tabs : null
    return tabs && String(tabs.position) === "bottom" ? "bottom" : "top"
  }
  readonly property var topApps: service ? service.topApps(settings.topApps) : []
  readonly property var configuredApps: service ? service.enabledApps : []
  readonly property var drawerAppKeys: {
    var out = {}
    for (var i = 0; i < configuredApps.length; i++) {
      var app = configuredApps[i]
      if (app && app.key) out[String(app.key)] = String(app.id)
    }
    return out
  }
  property bool allAppsOpen: false
  property int drawerSel: 0

  readonly property var openTabs: {
    var out = []
    if (!service) return out
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (app.state === "visible" || app.state === "hidden") out.push(app)
    }
    return out
  }
  readonly property int activeTabIndex: {
    for (var i = 0; i < openTabs.length; i++)
      if (String(openTabs[i].id) === (service ? String(service.currentAppId) : "")) return i
    return -1
  }
  readonly property bool reducedMotion: animations.reducedMotion === true
  readonly property int animDuration: reducedMotion ? 0 : Math.max(0, Number(animations.durationMs || 0))
  readonly property int animEasing: animations.easing === "outQuart" ? Easing.OutQuart
    : animations.easing === "outBack" ? Easing.OutBack
    : animations.easing === "linear" ? Easing.Linear
    : Easing.OutCubic
  readonly property string animMode: String(animations.mode || "slide+fade")
  readonly property var animParts: String(animations.mode || "slide+fade").split("+")
  function animHas(part) {
    if (animMode === "slideFade" && (part === "slide" || part === "fade")) return true
    return animParts.indexOf(part) >= 0
  }
  readonly property bool animSlideV: animHas("slide") || animHas("bounce")
  readonly property bool animSlideH: animHas("slideH")
  readonly property bool animFade: animHas("fade") || animHas("scale") || animHas("zoom")
  readonly property real animScaleFrom: animHas("zoom") ? 0.94 : (animHas("scale") ? 0.92 : 1)
  readonly property int animShowEasing: animHas("bounce") ? Easing.OutBack : animEasing
  function animationLabel(mode) {
    var parts = String(mode || "none").split("+")
    for (var i = 0; i < parts.length; i++)
      parts[i] = strings.t("animation." + parts[i], parts[i])
    return parts.join(" + ")
  }
  readonly property string edge: {
    var value = String(geometry.edge || "left")
    return ["top", "bottom", "left", "right"].indexOf(value) >= 0 ? value : "left"
  }
  // The command palette itself is always a top menu; only the managed
  // application window follows the configured slide edge.

  readonly property var targetScreen: {
    var name = overlay.screenName
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++)
      if (String(screens[i].name || "") === name) return screens[i]
    var focused = overlay.service && overlay.service.paletteMonitor
    for (var j = 0; j < screens.length; j++)
      if (String(screens[j].name || "") === focused) return screens[j]
    return screens.length > 0 ? screens[0] : null
  }

  readonly property var focusedMonitor: {
    var list = service ? service.monitors : []
    for (var i = 0; i < list.length; i++) if (list[i].focused) return list[i]
    return list.length > 0 ? list[0] : null
  }
  readonly property var monitorBox: Model.monitorBox(overlay.focusedMonitor)
  readonly property real previewAspect: overlay.monitorBox && overlay.monitorBox.height > 0
    ? overlay.monitorBox.width / overlay.monitorBox.height : 16 / 9
  readonly property real previewReservedTop: overlay.monitorBox ? overlay.monitorBox.reserved[1] : 26

  readonly property int cardWidth: 780

  readonly property string viewTitle: {
    if (view === "help") return strings.t("view.help")
    if (view === "manage") return strings.t("view.manage")
    if (view === "running") return strings.t("view.running")
    if (view === "sizes") return strings.t("view.sizes")
    if (view === "anim") return strings.t("view.anim")
    if (view === "keys") return strings.t("view.keys")
    if (view === "bar") return strings.t("view.bar")
    if (view === "appsize") {
      var app = service ? service.findApp(appSizeId) : null
      return app ? strings.t("view.appsizeFor").arg(app.name) : strings.t("view.appsize")
    }
    return strings.t("tooltip.idle")
  }

  // ---- Animation -----------------------------------------------------------

  property real animY: 0
  property real animX: 0
  property real animOpacity: 1
  property real animScale: 1

  function edgeOffset(distance) {
    return -distance
  }

  function edgeDistance() {
    return Style.bar.sizeHorizontal + Style.space(6)
  }

  function applyStart() {
    var distance = overlay.edgeDistance()
    animX = 0
    animY = 0
    animOpacity = 1
    animScale = 1
    if (animMode === "none" || animDuration === 0) return
    if (animFade) animOpacity = 0
    if (animScaleFrom < 1) animScale = animScaleFrom
    if (animSlideV) animY = overlay.edgeOffset(distance)
    if (animSlideH) {
      var screenWidth = window ? window.width : 1200
      var cardW = card ? card.width : overlay.cardWidth
      animX = -(screenWidth + cardW) / 2
    }
  }

  function animateIn() {
    showAnim.stop()
    hideAnim.stop()
    if (animMode === "none" || animDuration === 0) {
      animY = 0; animX = 0; animOpacity = 1; animScale = 1
      return
    }
    showAnim.duration = animDuration
    showAnim.start()
  }

  function animateOut() {
    showAnim.stop()
    hideAnim.stop()
    if (animMode === "none" || animDuration === 0) {
      closing = false
      return
    }
    hideAnim.duration = animDuration
    hideAnim.start()
  }

  ParallelAnimation {
    id: showAnim
    property int duration: 180
    NumberAnimation { target: overlay; property: "animY"; to: 0; duration: showAnim.duration; easing.type: overlay.animShowEasing }
    NumberAnimation { target: overlay; property: "animX"; to: 0; duration: showAnim.duration; easing.type: overlay.animShowEasing }
    NumberAnimation { target: overlay; property: "animOpacity"; to: 1; duration: showAnim.duration; easing.type: overlay.animShowEasing }
    NumberAnimation { target: overlay; property: "animScale"; to: 1; duration: showAnim.duration; easing.type: overlay.animShowEasing }
  }

  ParallelAnimation {
    id: hideAnim
    property int duration: 180
    onFinished: overlay.closing = false
    NumberAnimation { target: overlay; property: "animY"; to: overlay.animSlideV ? overlay.edgeOffset(overlay.edgeDistance()) : 0; duration: hideAnim.duration; easing.type: Easing.InCubic }
    NumberAnimation { target: overlay; property: "animX"; to: overlay.animSlideH ? -((window ? window.width : 1200) + (card ? card.width : overlay.cardWidth)) / 2 : 0; duration: hideAnim.duration; easing.type: Easing.InCubic }
    NumberAnimation { target: overlay; property: "animOpacity"; to: overlay.animFade ? 0 : 1; duration: hideAnim.duration; easing.type: Easing.InCubic }
    NumberAnimation { target: overlay; property: "animScale"; to: overlay.animScaleFrom; duration: hideAnim.duration; easing.type: Easing.InCubic }
  }

  // ---- Lifecycle -----------------------------------------------------------

  // Every way out of the palette must clear the same transient keyboard
  // modes. Missing one used to leak quit/popout/rebind mode into the next
  // palette session, where the next key could close an app or rebind a command.
  function resetShortcutCapture() {
    if (assigningShortcut && service) service.cancelShortcutRequest()
    assigningShortcut = false
    shortcutChecking = false
    shortcutError = ""
    shortcutAppId = ""
    shortcutSuggestion = ""
    shortcutPendingChord = ""
    shortcutUsed = []
  }

  function resetTransientModes() {
    quitMode = false
    popoutMode = false
    assigning = false
    assignAppId = ""
    assigningCommand = ""
    armedRemoveId = ""
    armedRemoveTimer.stop()
    resetShortcutCapture()
  }

  function open(payloadJson) {
    if (!service) return
    var payload = {}
    try { payload = JSON.parse(String(payloadJson || "{}")) } catch (e) { payload = {} }
    if (opened && view === String(payload.view || "palette")) return
    var hadContext = service.paletteOpen
    service.capturePaletteContext(String(payload.monitor || ""), payload.force === true)
    if (!hadContext || !overlay.screenName) overlay.screenName = String(payload.monitor || service.paletteMonitor)
    opened = true
    closing = false
    showAnim.stop()
    hideAnim.stop()
    search = ""
    searchFocused = true
    resetTransientModes()
    allAppsOpen = false
    appSizeId = ""
    localNotice = ""
    localNoticeUrgent = false
    previewReservedFlash = ""
    view = String(payload.view || "palette")
    if (view !== "palette" && view !== "manage") searchFocused = false
    if (view === "manage") searchFocused = true
    sel = 0
    refreshRows()
    applyStart()
    animateIn()
    if (view === "bar") {
      pendingBarTouched = false
      pendingBarSection = barSection
      pendingBarIndex = barIndex
    }
    if (view === "manage") focusSearch()
    else focusKeys()
  }

  function close() {
    if (!opened) return
    if (view === "bar") {
      barApplyTimer.stop()
      applyBarPlacementNow()
    }
    allAppsOpen = false
    resetTransientModes()
    overlay.cancelPaste()
    // closing must be set before opened: `visible: opened || closing` would
    // otherwise evaluate to false for one property change, unmapping the
    // layer surface and remapping it mid-fade (the close flicker).
    closing = true
    opened = false
    animateOut()
    if (service) service.paletteClosed()
    notifyShellClosed()
  }

  // The shell tracks open panels itself. A close initiated by the overlay
  // (outside click, Esc) must clear that flag; otherwise a stale open state
  // can replay the palette on the next summon. keepLoaded keeps the surface
  // alive, so hide() only calls this close() again (which returns early).
  function notifyShellClosed() {
    if (service && service.shell && service.shell.hide) service.shell.hide("apach.dropdown")
  }

  // Click outside the card: dismiss the palette and hide a visible managed
  // dropdown immediately, exactly like Escape. Keyboard focus returns to the
  // previous window on its own when the layer surface unmaps. Do not call
  // focusWindow(previous) here: focusing a window on another output makes
  // Hyprland warp the pointer (cursor:warp_on_change_workspace).
  function outsideClick() {
    if (!opened || !service) return
    var appId = String(service.currentAppId || "")
    var entry = appId ? service.registry[appId] : null
    var hideApp = service.config.settings.autoHideOnFocusLoss
      && entry !== null && entry.hidden !== true
    // Park before closing: the layer still owns keyboard focus, so the window
    // never flashes into focus behind the fading palette.
    if (hideApp) service.parkApp(appId, false)
    close()
  }

  function bandItems() {
    var items = []
    if (quitMode) return [{ key: "Esc", label: strings.t("band.cancelQuit") }]
    if (popoutMode) return [{ key: "Esc", label: strings.t("band.cancelPopout") }]
    if (view === "palette") {
      items = [
        { key: commandKey("help"), label: strings.t("band.help") },
        { key: commandKey("manage"), label: strings.t("band.manage") },
        { key: commandKey("preview"), label: strings.t("band.preview") },
        { key: commandKey("settings"), label: strings.t("band.settings") },
        { key: commandKey("bar"), label: strings.t("band.bar") },
        { key: commandKey("shortcuts"), label: strings.t("band.keys") },
        { key: commandKey("hide"), label: strings.t("band.hide") },
        { key: commandKey("popout"), label: strings.t("band.popout") },
        { key: commandKey("quit"), label: strings.t("band.quit") },
        { key: "Esc", label: strings.t("band.reduce") }
      ]
    } else if (view === "manage") {
      items = [
        { key: "Enter", label: strings.t("band.toggle") }, { key: "k", label: strings.t("band.key") },
        { key: "s", label: strings.t("band.size") }, { key: "A", label: strings.t("band.startup") },
        { key: "D", label: strings.t("band.direct") }, { key: "o", label: strings.t("band.adopt") },
        { key: "u", label: strings.t("band.release") },
        { key: "r", label: strings.t("band.refresh") }, { key: "Esc", label: strings.t("band.back") }
      ]
    } else if (view === "sizes" || view === "anim") {
      items = [
        { key: "↑↓", label: strings.t("band.row") }, { key: "←→", label: strings.t("band.adjust") },
        { key: "Enter", label: strings.t("band.next") }, { key: "r", label: strings.t("band.reset") },
        { key: "Esc", label: strings.t("band.back") }
      ]
    } else if (view === "bar") {
      items = [
        { key: "↑↓", label: strings.t("band.row") }, { key: "←→", label: strings.t("band.change") },
        { key: "Enter", label: strings.t("band.next") }, { key: "r", label: strings.t("band.reload") },
        { key: "Esc", label: strings.t("band.close") }
      ]
    } else if (view === "keys") {
      items = [
        { key: "↑↓", label: strings.t("band.row") }, { key: "Enter", label: strings.t("band.rebind") },
        { key: "r", label: strings.t("band.reset") }, { key: "Esc", label: strings.t("band.back") }
      ]
    } else if (view === "appsize") {
      items = [
        { key: "↑↓", label: strings.t("band.row") }, { key: "←→", label: strings.t("band.adjust") },
        { key: "i/r", label: strings.t("band.inherit") }, { key: "Esc", label: strings.t("band.back") }
      ]
    } else if (view === "running") {
      items = [
        { key: "↑↓", label: strings.t("band.select") },
        { key: "Enter", label: strings.t("band.open") },
        { key: "app key", label: strings.t("band.open") },
        { key: commandKey("hide"), label: strings.t("band.hide") },
        { key: commandKey("quit"), label: strings.t("band.quit") },
        { key: "Esc", label: strings.t("band.back") }
      ]
    } else if (view === "help") {
      items = [ { key: "Esc", label: strings.t("band.back") } ]
    } else {
      items = [
        { key: "Enter", label: strings.t("band.showHide") }, { key: "s", label: strings.t("band.size") },
        { key: "h", label: strings.t("band.hide") }, { key: "q", label: strings.t("band.quit") },
        { key: "Esc", label: strings.t("band.back") }
      ]
    }
    return items
  }

  function applyBarPlacement(raw) {
    var placement = Model.parseBarPlacement(raw, "apach.dropdown")
    barSection = placement.section
    barIndex = placement.index
    barSizes = placement.sizes
    if (!pendingBarTouched) {
      pendingBarSection = barSection
      pendingBarIndex = barIndex
    }
  }

  function openBarView() {
    pendingBarTouched = false
    pendingBarSection = barSection
    pendingBarIndex = barIndex
    readBarConfig()
    view = "bar"
  }

  function pendingBarTotal(section) {
    var target = String(section || "")
    if (target !== "left" && target !== "center" && target !== "right") return 0
    var size = Number(barSizes[target] || 0)
    if (barSection !== "" && target !== barSection) size += 1
    return Math.max(1, size)
  }

  function setBarSection(section) {
    var target = String(section || "")
    if (["left", "center", "right"].indexOf(target) < 0) return
    if (target === pendingBarSection) return
    pendingBarSection = target
    pendingBarIndex = target === barSection ? Math.max(0, barIndex) : Math.max(0, Number(barSizes[target] || 0))
    pendingBarTouched = true
    scheduleBarApply()
  }

  function cycleBarSection(delta) {
    var sections = ["left", "center", "right"]
    var index = sections.indexOf(pendingBarSection)
    if (index < 0) index = 0
    setBarSection(sections[(index + delta + sections.length) % sections.length])
  }

  function stepBarIndex(delta) {
    var total = pendingBarTotal(pendingBarSection)
    pendingBarIndex = Math.max(0, Math.min(total - 1, pendingBarIndex + delta))
    pendingBarTouched = true
    scheduleBarApply()
  }

  function scheduleBarApply() {
    if (!pendingBarTouched) return
    barApplyTimer.restart()
  }

  function applyBarPlacementNow() {
    if (!pendingBarTouched) return
    if (barMoveRunning) { barMoveDirty = true; return }
    if (["left", "center", "right"].indexOf(pendingBarSection) < 0) return
    barMoveDirty = false
    barMoveRunning = true
    barMoveProc.start(["omarchy", "bar", "move", "apach.dropdown",
      "--section", pendingBarSection, "--index", String(Math.max(0, pendingBarIndex))])
  }

  Timer {
    id: barApplyTimer
    interval: 180
    onTriggered: overlay.applyBarPlacementNow()
  }

  BoundedProcess {
    id: barMoveProc
    producerBound: true
    producerTimeoutSeconds: 5
    timeoutMs: 6000
    maxOutBytes: 4096
    maxErrBytes: Bounds.LIMITS.helperErrBytes
    onFinished: function(result) {
      overlay.barMoveRunning = false
      overlay.readBarConfig()
      if (!result.ok) {
        overlay.pendingBarTouched = false
        var reason = String(result.err || "").trim().split("\n")[0]
        overlay.say(reason ? overlay.tr("notice.barFailed", [reason])
          : overlay.tr("notice.barFailedNoReason"), true)
        return
      }
      if (overlay.barMoveDirty) {
        overlay.barMoveDirty = false
        overlay.applyBarPlacementNow()
        return
      }
      overlay.pendingBarTouched = false
      overlay.say(overlay.tr("notice.barApplied"))
    }
  }

  // FileView is only a change notification; shell.json is read through a
  // bounded helper so a huge or malicious file is never loaded whole.
  FileView {
    id: barConfig
    path: overlay.shellConfigPath
    watchChanges: true
    preload: false
    printErrors: false
    onFileChanged: overlay.readBarConfig()
  }

  BoundedProcess {
    id: barConfigReadProc
    producerBound: false
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.shellConfigBytes
    maxErrBytes: 4096
    onFinished: function(result) {
      var again = overlay.barConfigReadAgain
      overlay.barConfigReadAgain = false
      if (result.overflow) {
        console.warn("omarchy-dropdown: shell.json exceeds " +
          Bounds.LIMITS.shellConfigBytes + " bytes; keeping the current bar placement")
      } else if (result.ok) {
        overlay.applyBarPlacement(result.out)
      }
      if (again && !barConfigReadProc.running) overlay.readBarConfig()
    }
  }

  property bool barConfigReadAgain: false

  function readBarConfig() {
    if (barConfigReadProc.running) {
      overlay.barConfigReadAgain = true
      return
    }
    barConfigReadProc.start(Bounds.fileReadCommand(overlay.shellConfigPath, Bounds.LIMITS.shellConfigBytes))
  }

  Component.onCompleted: overlay.readBarConfig()

  function commandKey(name) {
    return service ? service.commandKey(name) : String(Model.DEFAULT_COMMANDS[name] || "")
  }

  function runningApps() {
    if (!service) return []
    var out = []
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (app.state === "visible" || app.state === "hidden" || app.state === "launching") out.push(app)
    }
    return out
  }

  function switchToTab(appId) {
    if (!service || !appId) return
    if (String(appId) === String(service.currentAppId)) return
    var app = service.findApp(appId)
    if (!app) return
    if (app.state !== "visible" && app.state !== "hidden") return
    service.revealApp(appId, service.captureContext())
    service.paletteTarget = appId
    say(strings.t("notice.appShown").arg(app.name))
  }

  function activateTab(appId) {
    if (!service || !appId) return
    if (String(appId) !== String(service.currentAppId)) switchToTab(appId)
    close()
  }

  function cycleTab(delta, closeAfter) {
    var list = openTabs
    if (list.length === 0) { say(strings.t("notice.noOpenWindow")); return }
    if (list.length === 1) { say(strings.t("notice.onlyOneWindow")); return }
    var index = activeTabIndex
    if (index < 0) index = delta > 0 ? -1 : 0
    var next = list[(index + delta + list.length) % list.length]
    switchToTab(next.id)
    if (closeAfter === true) close()
  }

  function popoutTargets() {
    if (!service) return []
    var out = []
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (app.state === "visible" || app.state === "hidden") out.push(app)
    }
    return out
  }

  function popoutPrompt() {
    var apps = popoutTargets()
    if (apps.length === 0) return strings.t("notice.noManagedRunning")
    var labels = []
    for (var i = 0; i < apps.length; i++) labels.push((apps[i].key || "—") + " " + apps[i].name)
    return strings.t("notice.popoutPrompt").arg(labels.join("   ·   "))
  }

  function beginPopoutMode() {
    if (!service) return
    var apps = popoutTargets()
    if (apps.length === 0) { say(strings.t("notice.noManagedRunning")); return }
    quitMode = false
    popoutMode = true
    say(popoutPrompt())
  }

  function handlePopoutKey(event) {
    var text = printable(event)
    if (!text) return
    event.accepted = true
    var key = text.toLowerCase()
    var matches = service.paletteMatchesKey(key)
    for (var i = 0; i < matches.length; i++) {
      var app = matches[i]
      if (app.state !== "visible" && app.state !== "hidden") continue
      popoutMode = false
      var result = service.popOutApp(app.id)
      if (result.ok) close()
      else say(result.message)
      return
    }
    say(strings.t("notice.noOpenAppUses").arg(key))
  }

  function quitPrompt() {
    var apps = runningApps()
    if (apps.length === 0) return strings.t("notice.noManagedRunning")
    var labels = []
    for (var i = 0; i < apps.length; i++) labels.push((apps[i].key || "—") + " " + apps[i].name)
    return strings.t("notice.quitPrompt").arg(labels.join("   ·   "))
  }

  function beginQuitMode() {
    if (!service) return
    var apps = runningApps()
    if (apps.length === 0) { say(strings.t("notice.noManagedRunning")); return }
    quitMode = true
    say(quitPrompt())
  }

  function handleQuitKey(event) {
    var text = printable(event)
    if (!text) return
    event.accepted = true
    var key = text.toLowerCase()
    var matches = service.paletteMatchesKey(key)
    for (var i = 0; i < matches.length; i++) {
      var app = matches[i]
      if (app.state !== "visible" && app.state !== "hidden" && app.state !== "launching") continue
      quitMode = false
      var result = service.closeApp(app.id, service.captureContext())
      if (result.ok) close()
      else say(result.message)
      return
    }
    say(strings.t("notice.noRunningAppUses").arg(key))
  }

  // Selecting an app hides the palette in the same frame, then starts the
  // window reveal. A fade first left an empty gap and made the window look
  // like it jumped into place.
  function closeImmediate() {
    if (!opened) return
    showAnim.stop()
    hideAnim.stop()
    opened = false
    closing = false
    allAppsOpen = false
    resetTransientModes()
    overlay.cancelPaste()
    animY = 0
    animX = 0
    animOpacity = 1
    animScale = 1
    if (service) service.paletteClosed()
    notifyShellClosed()
  }

  function activateApp(app) {
    if (!app) return
    if (app.conflict) { say(appConflictText(app) + "."); return }
    var context = service.captureContext()
    var wasOpen = opened
    if (wasOpen) closeImmediate()
    var result = service.toggleApp(app.id, context)
    if (!result.ok) {
      if (wasOpen) service.notify(result.message)
      else say(result.message)
    }
  }

  function focusKeys() {
    if (!opened) return
    Qt.callLater(function() { if (overlay.opened) keyCatcher.forceActiveFocus() })
  }

  function focusSearch() {
    if (!opened) return
    Qt.callLater(function() { if (overlay.opened && overlay.view === "manage") searchInput.forceActiveFocus() })
  }

  // ---- Bounded clipboard paste ---------------------------------------------
  //
  // Qt's native paste (Ctrl+V, Shift+Insert, middle-click PRIMARY) is
  // unbounded. The search field intercepts every paste gesture before
  // QQuickTextInput sees it and reads the clipboard through a producer- and
  // receiver-bounded helper. Only an explicit paste starts a read: opening the
  // palette never touches the clipboard.

  property int pasteGeneration: 0

  BoundedProcess {
    id: pasteProc
    producerBound: true
    producerTimeoutSeconds: 2
    timeoutMs: 3000
    maxOutBytes: Bounds.LIMITS.clipboardBytes
    maxErrBytes: Bounds.LIMITS.clipboardErrBytes
    onFinished: function(result) {
      // A result from an older request (new paste, focus loss, close) must
      // never be inserted.
      if (!Bounds.isCurrentGeneration(result.tag, overlay.pasteGeneration)) return
      if (result.canceled) return
      // The producer's own `timeout` exits 124; the component deadline sets
      // timedOut only when the wrapper itself had to be killed.
      if (result.timedOut || result.code === 124) {
        overlay.say(strings.t("notice.clipboardTimeout"))
        return
      }
      if (result.startFailed || result.code === 126 || result.code === 127) {
        overlay.say(strings.t("notice.clipboardUnavailable"))
        return
      }
      if (result.overflow) { overlay.say(strings.t("notice.clipboardTooLarge")); return }
      if (!result.ok) { overlay.say(strings.t("notice.clipboardFailed")); return }
      var verdict = Bounds.insertionVerdict(result.out, searchInput.text.length,
        Bounds.LIMITS.searchChars, Bounds.LIMITS.clipboardBytes)
      if (!verdict.ok) {
        if (verdict.reason === "tooLarge") overlay.say(strings.t("notice.clipboardTooLarge"))
        else overlay.say(strings.t("notice.clipboardTooLong").arg(Bounds.LIMITS.searchChars))
        return
      }
      if (verdict.text === "") return
      searchInput.insert(searchInput.cursorPosition, verdict.text)
    }
  }

  function pasteFromClipboard(primary) {
    overlay.pasteGeneration++
    var tag = overlay.pasteGeneration
    if (!pasteProc.start(Bounds.clipboardCommand(primary === true), tag))
      overlay.say(strings.t("notice.clipboardBusy"))
  }

  function cancelPaste() {
    overlay.pasteGeneration++
    pasteProc.cancel()
  }

  // Note: do not dismiss on the Hyprland `focusedmon` event. Hyprland changes
  // the focused monitor when the pointer crosses to another output, even
  // without a click, so listening to it closed the palette (and parked the
  // visible app) as soon as the mouse left the palette's screen. The
  // full-screen catcher below exists on every output and handles real clicks.

  Connections {
    target: Quickshell
    function onScreensChanged() {
      if (!overlay.opened) return
      var screens = Quickshell.screens || []
      for (var i = 0; i < screens.length; i++)
        if (String(screens[i].name || "") === overlay.screenName) return
      // The output that hosted the palette disappeared. Close cleanly rather
      // than leaving a layer surface bound to a dead screen.
      overlay.close()
    }
  }

  // ---- Notices -------------------------------------------------------------

  function say(message, urgent) {
    localNotice = String(message || "")
    localNoticeUrgent = urgent === true
    localTimer.restart()
  }

  Timer {
    id: localTimer
    interval: 5000
    onTriggered: {
      overlay.localNotice = ""
      overlay.localNoticeUrgent = false
    }
  }

  Timer {
    id: previewFlashTimer
    interval: 1800
    onTriggered: overlay.previewReservedFlash = ""
  }

  function serviceNotice() {
    return localNotice || (service ? service.notice : "")
  }

  // ---- Rows ----------------------------------------------------------------

  function systemApps() {
    if (!service) return []
    var out = []
    for (var i = 0; i < service.catalog.length; i++)
      if (service.catalog[i].kind === "system") out.push(service.catalog[i])
    return out
  }

  function windowTitle(appId) {
    if (!service) return ""
    var entry = service.registry[appId]
    if (!entry) return ""
    var win = service.clientByAddress(entry.address)
    return win ? String(win.title || "") : ""
  }

  function screenChoices() {
    var out = ["auto"]
    var monitors = service ? service.monitors : []
    for (var i = 0; i < monitors.length; i++) {
      var name = String(monitors[i].name || "")
      if (name && out.indexOf(name) < 0) out.push(name)
    }
    return out
  }

  function screenLabel(value) {
    if (!value || String(value) === "auto") return strings.t("settings.auto")
    return String(value)
  }

  function searchScore(app, q) {
    if (!q) return 0
    var best = -1
    var fields = [String(app.name || ""), String(app.id || ""), String(app.detail || "")]
    for (var i = 0; i < fields.length; i++) {
      var score = Model.fuzzyScore(q, fields[i])
      if (score > best) best = score
    }
    return best
  }

  function matchesSearch(app, q) {
    return searchScore(app, q) >= 0
  }

  function filterAppsBySearch(list) {
    var q = search.toLowerCase().trim()
    var scored = []
    for (var i = 0; i < list.length; i++) {
      var app = service.findApp(list[i].id)
      if (!app) continue
      var score = searchScore(app, q)
      if (score < 0) continue
      scored.push({ app: app, score: score })
    }
    scored.sort(function(a, b) { return b.score - a.score })
    return scored.map(function(entry) { return entry.app })
  }

  function filteredWebapps() {
    return service ? overlay.filterAppsBySearch(service.webapps) : []
  }

  function filteredApplications() {
    return service ? overlay.filterAppsBySearch(service.applications) : []
  }

  function isSelectable(row) {
    return row !== undefined && row !== null && row.kind !== "header"
  }

  function firstSelectable() {
    for (var i = 0; i < rows.length; i++) if (isSelectable(rows[i])) return i
    return 0
  }

  function manageRows() {
    var out = []
    var q = search.toLowerCase().trim()
    var systems = systemApps().filter(function(app) { return matchesSearch(app, q) })
    var web = filteredWebapps()
    var apps = filteredApplications()
    var missing = (service ? service.missingApps : []).filter(function(app) { return matchesSearch(app, q) })
    if (systems.length > 0) {
      out.push({ kind: "header", headerKey: "manage.headers.system", count: systems.length })
      for (var s = 0; s < systems.length; s++) out.push(systems[s])
    }
    if (web.length > 0) {
      out.push({ kind: "header", headerKey: "manage.headers.webapps", count: web.length })
      for (var w = 0; w < web.length; w++) out.push(web[w])
    }
    if (apps.length > 0) {
      out.push({ kind: "header", headerKey: "manage.headers.applications", count: apps.length })
      for (var a = 0; a < apps.length; a++) out.push(apps[a])
    }
    if (missing.length > 0) {
      out.push({ kind: "header", headerKey: "manage.headers.missing", count: missing.length })
      for (var m = 0; m < missing.length; m++) out.push(missing[m])
    }
    return out
  }

  function runningRows() {
    if (!service) return []
    var out = []
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (app.state === "visible" || app.state === "hidden" || app.state === "launching" || app.state === "closing")
        out.push(app)
    }
    return out
  }

  // Short labels used by the preview when a command key collides with an app key.
  function commandLabel(name) {
    return strings.t("command." + String(name || ""), String(name || ""))
  }

  // Non-empty when this app's key belongs to a palette command or to the
  // navigation. The key stays reserved and is never used to open the app.
  function previewReservedLabel(app) {
    if (!app || !app.key || !service) return ""
    var action = service.commandForKey(String(app.key).toLowerCase())
    return action === "" ? "" : strings.t("notice.reservedLabel").arg(commandLabel(action))
  }

  function previewAppForKey(key) {
    if (!service) return null
    var value = String(key || "").toLowerCase()
    for (var i = 0; i < service.enabledApps.length; i++) {
      var app = service.enabledApps[i]
      if (String(app.key || "").toLowerCase() === value) return app
    }
    return null
  }

  function previewOpenApp(app) {
    if (!app || !service) return
    var entry = service.registry[app.id]
    var win = entry ? service.clientByAddress(entry.address) : null
    // Already on screen: closing the preview is enough, never hide it.
    if (entry && win && !entry.hidden) { close(); return }
    // An explicit open by id is safe even when the assigned key conflicts.
    var result = service.toggleApp(app.id, service.captureContext(), true)
    if (result.ok) close()
    else say(result.message)
  }

  function runPreviewCommand(action) {
    if (action === "quit") {
      var target = rows[sel]
      if (!target) return
      var closed = service.closeApp(target.id, service.captureContext())
      if (closed.ok) close()
      else say(closed.message)
      return
    }
    if (action === "hide") {
      var hiddenApp = rows[sel]
      if (!hiddenApp) return
      var entry = service.registry[hiddenApp.id]
      if (entry && entry.hidden) { say(strings.t("notice.alreadyHidden").arg(hiddenApp.name)); return }
      service.parkApp(hiddenApp.id, true)
      close()
      return
    }
    if (action === "settings") {
      var sized = rows[sel]
      if (!sized) return
      appSizeId = sized.id
      backView = view
      view = "appsize"
      return
    }
    if (action === "help") { view = "help"; return }
    if (action === "manage") { view = "manage"; return }
    if (action === "motion") { view = "anim"; return }
    if (action === "bar") { openBarView(); return }
    if (action === "shortcuts") { view = "keys"; return }
    // "preview" is the view itself.
  }

  function handlePreviewKey(event) {
    if (event.key === Qt.Key_Up) { event.accepted = true; moveSelection(-1); return }
    if (event.key === Qt.Key_Down) { event.accepted = true; moveSelection(1); return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      previewOpenApp(rows[sel])
      return
    }
    var text = printable(event)
    if (!text) return
    var key = text.toLowerCase()
    var app = previewAppForKey(key)
    var action = service ? service.commandForKey(key) : ""
    if (action !== "") {
      event.accepted = true
      // A reserved key never opens the app that also claimed it. The red
      // label beside its KeyCap explains why, and flashes on the attempt.
      if (app) {
        previewReservedFlash = String(app.id)
        previewFlashTimer.restart()
        say(strings.t("notice.keyReserved").arg(key).arg(commandLabel(action)), true)
        return
      }
      runPreviewCommand(action)
      return
    }
    if (!app) { say(strings.t("notice.noManagedAppUses").arg(key)); return }
    event.accepted = true
    previewOpenApp(app)
  }

  function keyRows() {
    var out = []
    var names = ["help", "manage", "preview", "settings", "motion", "bar", "shortcuts",
      "nextWindow", "popout", "hide", "quit"]
    for (var i = 0; i < names.length; i++) {
      var name = names[i]
      out.push({ command: name, key: commandKey(name), labelKey: "commandHelp." + name, fixed: false })
    }
    out.push({ command: "reduce", key: "Esc", labelKey: "commandHelp.reduce", fixed: true })
    return out
  }

  function helpRows() {
    var out = []
    out.push({ kind: "header", labelKey: "help.commands" })
    var keys = keyRows()
    for (var k = 0; k < keys.length; k++)
      out.push({ kind: "row", key: keys[k].key, labelKey: keys[k].labelKey })
    out.push({ kind: "header", labelKey: "help.appKeys" })
    var enabled = service ? service.enabledApps : []
    if (enabled.length === 0) out.push({ kind: "row", key: "m", labelKey: "help.noApp" })
    for (var i = 0; i < enabled.length; i++) {
      var app = enabled[i]
      out.push({
        kind: "row",
        key: app.key || "—",
        helpKind: "app",
        appName: app.name,
        conflict: app.conflict,
        conflictKey: app.conflictKey,
        conflictArgs: app.conflictArgs
      })
    }
    out.push({ kind: "header", labelKey: "help.systemApps" })
    var systems = systemApps()
    for (var j = 0; j < systems.length; j++) {
      var sys = systems[j]
      out.push({
        kind: "row",
        key: sys.enabled ? (sys.key || "—") : "off",
        helpKind: "system",
        appName: sys.name,
        enabled: sys.enabled,
        detail: sys.detail,
        detailKey: sys.detailKey
      })
    }
    out.push({ kind: "header", labelKey: "help.animationScope" })
    out.push({ kind: "row", key: "", labelKey: "help.animationNote" })
    return out
  }

  Timer {
    id: armedRemoveTimer
    interval: 3000
    onTriggered: overlay.armedRemoveId = ""
  }

  function refreshRows() {
    if (view === "manage") rows = manageRows()
    else if (view === "running") rows = runningRows()
    else if (view === "help") rows = helpRows()
    else if (view === "keys") rows = keyRows()
    else rows = []
    // Views without a row list (sizes, anim, bar, appsize) keep their own
    // selection. Letting a background catalog refresh clamp it to 0 used to
    // jump the highlighted setting while the user was adjusting it.
    if (rows.length === 0) {
      if (view === "manage" || view === "running" || view === "help" || view === "keys") sel = 0
      return
    }
    sel = Math.max(0, Math.min(sel, rows.length - 1))
    if (!isSelectable(rows[sel])) {
      for (var i = 0; i < rows.length; i++)
        if (isSelectable(rows[i])) { sel = i; break }
    }
  }

  onViewChanged: {
    sel = 0
    resetTransientModes()
    allAppsOpen = false
    previewReservedFlash = ""
    if (view === "manage") searchFocused = true
    if (view !== "manage") search = ""
    refreshRows()
    if (view === "bar") {
      pendingBarTouched = false
      pendingBarSection = barSection
      pendingBarIndex = barIndex
    }
    if (view === "manage") focusSearch()
    else focusKeys()
  }

  onSearchChanged: {
    refreshRows()
  }

  onSelChanged: {
    var list = view === "manage" ? manageList : simpleList
    if (list && list.count > 0) list.positionViewAtIndex(sel, ListView.Contain)
  }


  Connections {
    target: overlay.service
    function onCatalogChanged() { overlay.refreshRows() }
    function onMissingAppsChanged() { overlay.refreshRows() }
    function onCurrentAppIdChanged() { overlay.refreshRows() }
    function onShortcutAssigned(appId, shortcut) {
      if (!overlay.assigningShortcut || overlay.shortcutAppId !== appId) return
      overlay.assigningShortcut = false
      overlay.shortcutChecking = false
      overlay.shortcutError = ""
      overlay.shortcutPendingChord = ""
      overlay.shortcutAppId = ""
      overlay.say(strings.t("notice.directShortcutSet").arg(shortcut))
      overlay.refreshRows()
    }
    function onShortcutRejected(appId, message) {
      if (overlay.shortcutAppId !== appId) return
      overlay.shortcutChecking = false
      overlay.shortcutError = message
      // The rejected chord may be owned by Omarchy itself. Drop it from the
      // suggestion pool so Enter proposes a genuinely free chord next.
      if (overlay.shortcutPendingChord) {
        var pool = []
        for (var i = 0; i < overlay.shortcutUsed.length; i++) pool.push(overlay.shortcutUsed[i])
        pool.push(overlay.shortcutPendingChord)
        overlay.shortcutUsed = pool
        var app = overlay.service.findApp(appId)
        overlay.shortcutSuggestion = app
          ? Model.suggestShortcut(app.name, pool) : ""
        overlay.shortcutPendingChord = ""
      }
    }
  }

  // ---- Keyboard ------------------------------------------------------------

  function goBack() {
    if (allAppsOpen) {
      allAppsOpen = false
      return
    }
    if (quitMode) {
      quitMode = false
      say(strings.t("notice.quitCancelled"))
      return
    }
    if (popoutMode) {
      popoutMode = false
      say(strings.t("notice.popoutCancelled"))
      return
    }
    if (assigningShortcut) {
      service.cancelShortcutRequest()
      assigningShortcut = false
      shortcutChecking = false
      shortcutError = ""
      shortcutAppId = ""
      shortcutSuggestion = ""
      say(strings.t("notice.directShortcutCancelled"))
      return
    }
    if (assigningCommand) {
      assigningCommand = ""
      say(strings.t("notice.commandChangeCancelled"))
      return
    }
    if (assigning) {
      assigning = false
      assignAppId = ""
      say(strings.t("notice.keyAssignmentCancelled"))
      return
    }
    if (view === "bar") { close(); return }
    if (view === "appsize") { view = backView; return }
    if (view !== "palette") { view = "palette"; return }
    if (service && service.currentAppId) service.parkApp(service.currentAppId, true)
    close()
  }

  function printable(event) {
    var text = String(event.text || "")
    if (text.length !== 1) return ""
    var code = text.charCodeAt(0)
    if (code < 32 || code === 127) return ""
    return text
  }

  function handleKey(event) {
    // The layer keeps keyboard focus during the close fade so the window
    // behind does not change while the card is still visible. Ignore keys in
    // that short window instead of acting on a palette that is already closed.
    if (!opened) {
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Escape) {
      event.accepted = true
      goBack()
      return
    }
    if (!assigning && !assigningCommand && !assigningShortcut && !quitMode && !popoutMode
        && event.key === Qt.Key_Tab && (event.modifiers & Qt.ControlModifier)) {
      event.accepted = true
      // Each Ctrl+Tab press cycles; Enter closes the palette while the
      // managed window stays visible.
      cycleTab((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
      return
    }
    if (assigningShortcut) { handleShortcutKey(event); return }
    if (assigning) {
      var typed = printable(event)
      if (!typed) return
      event.accepted = true
      var key = typed.toLowerCase()
      var result = service.assignKey(assignAppId, key)
      if (result.ok) {
        var app = service.findApp(assignAppId)
        say(strings.t("notice.keyAssigned").arg(key).arg(app ? app.name : assignAppId))
        assigning = false
        assignAppId = ""
        focusKeys()
      } else {
        say(result.message)
        focusKeys()
      }
      return
    }

    if (assigningCommand) {
      var cmdKey = printable(event)
      if (!cmdKey) return
      event.accepted = true
      var assigned = service.setCommandKey(assigningCommand, cmdKey.toLowerCase())
      if (assigned.ok) {
        say(strings.t("notice.commandAssigned").arg(cmdKey.toLowerCase()))
        assigningCommand = ""
        refreshRows()
        focusKeys()
      } else {
        say(assigned.message)
      }
      return
    }
    if (quitMode) { handleQuitKey(event); return }
    if (popoutMode) { handlePopoutKey(event); return }
    if (view === "bar") { handleBarKey(event); return }
    if (view === "keys") { handleKeysKey(event); return }
    if (view === "sizes") { handleSizesKey(event); return }
    if (view === "anim") { handleAnimKey(event); return }
    if (view === "appsize") { handleAppSizeKey(event); return }
    if (view === "help") { handleHelpKey(event); return }
    if (view === "running") { handlePreviewKey(event); return }
    if (view === "manage") { handleManageKey(event); return }
    handlePaletteKey(event)
  }

  function moveSelection(delta) {
    if (rows.length === 0) return
    var index = sel
    for (var guard = 0; guard < rows.length; guard++) {
      index = (index + delta + rows.length) % rows.length
      if (isSelectable(rows[index])) { sel = index; return }
    }
  }

  function toggleAllApps() {
    allAppsOpen = !allAppsOpen
    drawerSel = 0
  }

  function drawerActivate(index) {
    var app = overlay.configuredApps[Number(index)]
    if (app) overlay.activateApp(app)
  }

  // Palette-view decisions are made by Keymap.js, so the keyboard contract
  // is covered by unit tests. Manage, Keys, Bar, Sizes, Anim and AppSize have
  // their own handlers below.
  function handlePaletteKey(event) {
    var text = printable(event)
    var intent = Keymap.paletteIntent({
      key: Keymap.nameForCode(event.key),
      text: text,
      commands: settings.commands,
      appKeys: drawerAppKeys,
      drawerOpen: allAppsOpen,
      drawerIndex: drawerSel,
      drawerCount: configuredApps.length,
      columns: allAppsDrawer.columns
    })

    if (intent.action === "none") {
      if (event.key === Qt.Key_Up || event.key === Qt.Key_Down
          || event.key === Qt.Key_Left || event.key === Qt.Key_Right) event.accepted = true
      return
    }
    if (intent.action === "commit") {
      event.accepted = true
      // Close the palette; the managed window stays visible.
      close()
      return
    }
    if (intent.action === "drawer-toggle") {
      event.accepted = true
      toggleAllApps()
      return
    }
    if (intent.action === "drawer-open") {
      event.accepted = true
      allAppsOpen = true
      drawerSel = Math.max(0, Number(intent.index) || 0)
      return
    }
    if (intent.action === "drawer-close" || intent.action === "drawer-exit") {
      event.accepted = true
      allAppsOpen = false
      return
    }
    if (intent.action === "drawer-move") {
      event.accepted = true
      drawerSel = Math.max(0, Number(intent.index) || 0)
      return
    }
    if (intent.action === "drawer-activate") {
      event.accepted = true
      drawerActivate(intent.index)
      return
    }
    if (intent.action === "command") {
      event.accepted = true
      var action = intent.name
      var paletteViews = { help: "help", manage: "manage", preview: "running", settings: "sizes", motion: "anim", shortcuts: "keys" }
      if (paletteViews[action]) { view = paletteViews[action]; return }
      if (action === "bar") { openBarView(); return }
      if (action === "nextWindow") { cycleTab(1, true); return }
      if (action === "popout") { beginPopoutMode(); return }
      if (action === "hide") {
        var hidden = service.hideTarget()
        if (hidden.ok) close()
        else say(hidden.message)
        return
      }
      if (action === "quit") { beginQuitMode(); return }
      return
    }
    if (intent.action === "app") {
      event.accepted = true
      var matches = service.paletteMatchesKey(intent.key)
      if (matches.length === 0) {
        say(strings.t("notice.unknownKeyHelp").arg(intent.key).arg(overlay.commandKey("help")))
        return
      }
      if (matches.length > 1) {
        var names = matches.map(function(app) { return app.name }).join(", ")
        say(strings.t("notice.keyUsedBy").arg(intent.key).arg(names))
        return
      }
      var app = matches[0]
      if (app.conflict) { say(appConflictText(app) + "."); return }
      overlay.activateApp(app)
      return
    }
    if (intent.action === "text") {
      event.accepted = true
      say(strings.t("notice.unknownKeyHelp").arg(intent.text).arg(overlay.commandKey("help")))
    }
  }

  function handleHelpKey(event) {
    if (event.key === Qt.Key_Up) { event.accepted = true; moveSelection(-1); return }
    if (event.key === Qt.Key_Down) { event.accepted = true; moveSelection(1); return }
  }

  function handleManageKey(event) {
    if (event.key === Qt.Key_Up) {
      event.accepted = true
      if (searchFocused) { searchFocused = false; sel = firstSelectable(); focusKeys() }
      else moveSelection(-1)
      return
    }
    if (event.key === Qt.Key_Down) {
      event.accepted = true
      if (searchFocused) { searchFocused = false; sel = firstSelectable(); focusKeys() }
      else moveSelection(1)
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      toggleManaged(rows[sel])
      if (!searchFocused) focusKeys()
      return
    }
    var text = printable(event)
    if (searchFocused) {
      if (text === "/") { event.accepted = true; searchFocused = false; return }
      return
    }
    var upper = String(text || "").toUpperCase()
    if (upper === "A") {
      event.accepted = true
      var startupApp = rows[sel]
      if (startupApp && startupApp.kind !== "header" && !startupApp.missing) {
        if (!startupApp.enabled) overlay.say(strings.t("notice.enableBeforeStartup").arg(startupApp.name))
        else {
          var startupResult = service.setLaunchAtLogin(startupApp.id, !startupApp.launchAtLogin)
          if (startupResult.ok) overlay.say(strings.t(startupApp.launchAtLogin ? "notice.startupDisabled" : "notice.startupEnabled").arg(startupApp.name))
          else overlay.say(startupResult.message)
          refreshRows()
        }
      }
      return
    }
    if (upper === "D") {
      event.accepted = true
      beginShortcutAssign(rows[sel])
      return
    }
    if (text === "/") {
      event.accepted = true
      searchFocused = true
      Qt.callLater(function() { searchInput.forceActiveFocus() })
      return
    }
    if (!text) return
    var key = text.toLowerCase()
    if (key === "k") {
      event.accepted = true
      beginAssign(rows[sel])
      return
    }
    if (key === "s") {
      event.accepted = true
      var sized = rows[sel]
      if (!sized || sized.kind === "header" || sized.missing) return
      appSizeId = sized.id
      backView = "manage"
      view = "appsize"
      return
    }
    if (key === "o") {
      event.accepted = true
      var adopted = service.adoptApp(rows[sel] && rows[sel].kind !== "header" ? rows[sel].id : "")
      say(adopted.message || strings.t("notice.windowAdopted"))
      refreshRows()
      return
    }
    if (key === "u") {
      event.accepted = true
      var released = service.releaseApp(rows[sel] && rows[sel].kind !== "header" ? rows[sel].id : "")
      say(released.message || strings.t("notice.appReleased"))
      refreshRows()
      return
    }
    if (key === "r") {
      event.accepted = true
      service.refreshCatalog()
      say(strings.t("notice.catalogRefreshed"))
      refreshRows()
      return
    }
    if (key === "x" && rows[sel] && rows[sel].missing) {
      event.accepted = true
      var missingId = rows[sel].id
      if (overlay.armedRemoveId !== missingId) {
        overlay.armedRemoveId = missingId
        armedRemoveTimer.restart()
        say(strings.t("notice.removeAgain").arg(missingId))
        return
      }
      overlay.armedRemoveId = ""
      var removed = service.removeMissing(missingId)
      say(removed.message || strings.t("notice.missingRemoved"))
      refreshRows()
      return
    }
    // Any other printable key starts a search, so typing does not require
    // aiming at the field first.
    event.accepted = true
    search += text
    searchFocused = true
    Qt.callLater(function() { searchInput.forceActiveFocus() })
  }

  function toggleManaged(app) {
    if (!app || app.kind === "header") return
    if (app.missing) { say(strings.t("notice.missingEntryGone")); return }
    var result = service.setEnabled(app.id, !app.enabled)
    if (result.ok) {
      say(strings.t(app.enabled ? "notice.noLongerManaged" : "notice.nowManaged").arg(app.name))
    } else {
      say(result.message)
    }
    refreshRows()
  }

  function beginShortcutAssign(app) {
    if (!app || app.kind === "header") return
    if (app.missing) { say(strings.t("notice.cannotBindMissing")); return }
    if (!app.enabled) { say(strings.t("notice.enableBeforeShortcut").arg(app.name)); return }
    assigning = false
    assigningCommand = ""
    assigningShortcut = true
    shortcutChecking = false
    shortcutError = ""
    shortcutAppId = app.id
    var used = []
    for (var i = 0; i < service.enabledApps.length; i++)
      if (service.enabledApps[i].shortcut) used.push(service.enabledApps[i].shortcut)
    shortcutUsed = used
    shortcutPendingChord = ""
    shortcutSuggestion = Model.suggestShortcut(app.name, used)
    focusKeys()
  }

  function shortcutKeyName(event) {
    var key = event.key
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F24) return "F" + (key - Qt.Key_F1 + 1)
    var named = {}
    named[Qt.Key_Left] = "LEFT"
    named[Qt.Key_Right] = "RIGHT"
    named[Qt.Key_Up] = "UP"
    named[Qt.Key_Down] = "DOWN"
    named[Qt.Key_Tab] = "TAB"
    named[Qt.Key_Space] = "SPACE"
    named[Qt.Key_Return] = "RETURN"
    named[Qt.Key_Enter] = "RETURN"
    named[Qt.Key_Backspace] = "BACKSPACE"
    named[Qt.Key_Delete] = "DELETE"
    named[Qt.Key_Home] = "HOME"
    named[Qt.Key_End] = "END"
    named[Qt.Key_PageUp] = "PAGEUP"
    named[Qt.Key_PageDown] = "PAGEDOWN"
    named[Qt.Key_Insert] = "INSERT"
    named[Qt.Key_Comma] = "COMMA"
    named[Qt.Key_Period] = "PERIOD"
    named[Qt.Key_Slash] = "SLASH"
    named[Qt.Key_Semicolon] = "SEMICOLON"
    named[Qt.Key_Apostrophe] = "APOSTROPHE"
    named[Qt.Key_Minus] = "MINUS"
    named[Qt.Key_Equal] = "EQUAL"
    named[Qt.Key_Backslash] = "BACKSLASH"
    named[Qt.Key_BraceLeft] = "BRACKETLEFT"
    named[Qt.Key_BraceRight] = "BRACKETRIGHT"
    return named[key] || ""
  }

  function shortcutModifiers(event) {
    var out = []
    if (event.modifiers & Qt.MetaModifier) out.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) out.push("CTRL")
    if (event.modifiers & Qt.AltModifier) out.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) out.push("SHIFT")
    return out
  }

  function handleShortcutKey(event) {
    event.accepted = true
    if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Delete) {
      service.cancelShortcutRequest()
      var cleared = service.applyAppShortcut(shortcutAppId, "")
      assigningShortcut = false
      shortcutChecking = false
      shortcutError = ""
      shortcutAppId = ""
      shortcutSuggestion = ""
      if (!cleared.ok) say(cleared.message)
      else { say(strings.t("notice.directShortcutCleared")); refreshRows() }
      return
    }
    var chord = ""
    var bareCommit = (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
      && shortcutModifiers(event).length === 0
    if (bareCommit && shortcutSuggestion) {
      chord = shortcutSuggestion
    } else {
      var name = shortcutKeyName(event)
      if (!name) {
        var hint = strings.t("notice.shortcutInvalid")
        shortcutError = hint
        say(hint)
        return
      }
      var modifiers = shortcutModifiers(event)
      if (modifiers.length === 0 || (modifiers.length === 1 && modifiers[0] === "SHIFT")) {
        var modHint = strings.t("notice.shortcutModifier")
        shortcutError = modHint
        say(modHint)
        return
      }
      chord = modifiers.join(" + ") + " + " + name
    }
    shortcutError = ""
    shortcutPendingChord = chord
    var result = service.requestAppShortcut(shortcutAppId, chord)
    if (!result.ok) { shortcutError = result.message; say(result.message); return }
    if (result.pending) {
      shortcutChecking = true
      say(strings.t("notice.checkingBinds"))
      return
    }
    assigningShortcut = false
    shortcutChecking = false
    shortcutError = ""
    shortcutAppId = ""
    shortcutSuggestion = ""
    shortcutPendingChord = ""
    shortcutUsed = []
    say(strings.t("notice.directShortcutSet").arg(result.shortcut))
    refreshRows()
  }

  function beginAssign(app) {
    if (!app || app.kind === "header") return
    if (app.missing) { say(strings.t("notice.cannotAssignMissing")); return }
    if (!app.enabled) { say(strings.t("notice.enableBeforeKey").arg(app.name)); return }
    assigning = true
    assignAppId = app.id
    say(strings.t("notice.pressKeyFor").arg(app.name))
    focusKeys()
  }

  function handleBarKey(event) {
    if (event.key === Qt.Key_Up) { event.accepted = true; sel = Math.max(0, sel - 1); return }
    if (event.key === Qt.Key_Down) { event.accepted = true; sel = Math.min(1, sel + 1); return }
    var text = printable(event)
    if (event.key === Qt.Key_Left || text === "-") {
      event.accepted = true
      if (sel === 0) cycleBarSection(-1); else stepBarIndex(-1)
      return
    }
    if (event.key === Qt.Key_Right || text === "+") {
      event.accepted = true
      if (sel === 0) cycleBarSection(1); else stepBarIndex(1)
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      event.accepted = true
      if (sel === 0) cycleBarSection(1); else stepBarIndex(1)
      return
    }
    if (text === "r") {
      event.accepted = true
      barApplyTimer.stop()
      pendingBarSection = barSection
      pendingBarIndex = barIndex
      pendingBarTouched = false
      barMoveDirty = false
      readBarConfig()
      say(strings.t("notice.placementReloaded"))
    }
  }

  function handleKeysKey(event) {
    if (event.key === Qt.Key_Up) { event.accepted = true; sel = Math.max(0, sel - 1); return }
    if (event.key === Qt.Key_Down) { event.accepted = true; sel = Math.min(rows.length - 1, sel + 1); return }
    var text = printable(event)
    if (text === "r") { event.accepted = true; service.resetCommands(); refreshRows(); say(strings.t("notice.shortcutsReset")); return }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || text === "k") {
      event.accepted = true
      var row = rows[sel]
      if (!row) return
      if (row.fixed) { say(strings.t("notice.reduceFixed")); return }
      assigningCommand = row.command
      say(strings.t("notice.pressKeyFor").arg(overlay.rowLabel(row)))
      focusKeys()
    }
  }

  // Up/Down/Left/Right/Enter/R navigation shared by the settings, animation
  // and per-app size views.
  function handleAdjustKeys(event, maxSel, adjust, onReset) {
    if (event.key === Qt.Key_Up) { event.accepted = true; sel = Math.max(0, sel - 1); return true }
    if (event.key === Qt.Key_Down) { event.accepted = true; sel = Math.min(maxSel, sel + 1); return true }
    var text = printable(event)
    if (event.key === Qt.Key_Left || text === "-") { event.accepted = true; adjust(-1); return true }
    if (event.key === Qt.Key_Right || text === "+") { event.accepted = true; adjust(1); return true }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { event.accepted = true; adjust(1); return true }
    if (text === "r" || text === "R") {
      event.accepted = true
      if (onReset) onReset()
      else service.resetSettings()
      return true
    }
    return false
  }

  function handleSizesKey(event) {
    overlay.handleAdjustKeys(event, 11, overlay.adjustSize)
  }

  function adjustSize(delta) {
    var g = geometry
    if (sel === 0) {
      var screens = screenChoices()
      var current = String(service.config.settings.screen || "auto")
      var sidx = screens.indexOf(current)
      if (sidx < 0) sidx = 0
      var nextScreen = screens[(sidx + delta + screens.length) % screens.length]
      service.setSetting("settings.screen", nextScreen)
      // Keep the palette on the current output; the new preference is applied
      // the next time it opens. A settings change must never close the panel.
      return
    }
    if (sel === 1) {
      var presets = ["compact", "medium", "large", "custom"]
      var index = presets.indexOf(g.preset)
      if (index < 0) index = 1
      var next = presets[(index + delta + presets.length) % presets.length]
      if (next === "custom") service.setSetting("settings.geometry.preset", "custom")
      else service.applyPreset(next)
      return
    }
    if (sel === 2) {
      var placements = Model.PLACEMENTS
      var pidx = placements.indexOf(String(g.placement || "center"))
      if (pidx < 0) pidx = 0
      service.setSetting("settings.geometry.placement", placements[(pidx + delta + placements.length) % placements.length])
      return
    }
    if (sel === 3) {
      var edges = Model.EDGES
      var eidx = edges.indexOf(String(g.edge || "top"))
      if (eidx < 0) eidx = 0
      service.setSetting("settings.geometry.edge", edges[(eidx + delta + edges.length) % edges.length])
      return
    }
    if (sel === 4) service.setSetting("settings.geometry.widthPercent", Model.clamp(g.widthPercent + delta * 5, 20, 100))
    else if (sel === 5) service.setSetting("settings.geometry.heightPercent", Model.clamp(g.heightPercent + delta * 5, 20, 100))
    else if (sel === 6) service.setSetting("settings.geometry.topOffset", Model.clamp(g.topOffset + delta * 4, 0, 400))
    else if (sel === 7) service.setSetting("settings.geometry.sideMargin", Model.clamp(g.sideMargin + delta * 4, 0, 400))
    else if (sel === 8) {
      var positions = Model.TABS_POSITIONS
      var pidx = positions.indexOf(overlay.tabPosition)
      if (pidx < 0) pidx = 0
      service.setSetting("settings.tabs.position", positions[(pidx + delta + positions.length) % positions.length])
    }
    else if (sel === 9) service.setSetting("settings.autoHideOnFocusLoss", !service.config.settings.autoHideOnFocusLoss)
    else if (sel === 10) service.setSetting("settings.autoHideDelayMs", Model.clamp(Number(service.config.settings.autoHideDelayMs) + delta * 1000, 0, 30000))
    else if (sel === 11) service.setSetting("settings.topApps", Model.clamp(Number(service.config.settings.topApps || 5) + delta, 3, 7))
  }

  function handleAnimKey(event) {
    overlay.handleAdjustKeys(event, 3, overlay.adjustAnim)
  }

  function adjustAnim(delta) {
    var a = animations
    if (sel === 0) {
      var modes = Model.ANIMATION_MODES
      var index = modes.indexOf(String(a.mode))
      if (index < 0) index = 3
      service.setSetting("settings.animations.mode", modes[(index + delta + modes.length) % modes.length])
      return
    }
    if (sel === 1) {
      service.setSetting("settings.animations.durationMs", Model.clamp(Number(a.durationMs) + delta * 20, 0, 800))
      return
    }
    if (sel === 2) {
      var easings = Model.EASINGS
      var eidx = easings.indexOf(String(a.easing))
      if (eidx < 0) eidx = 0
      service.setSetting("settings.animations.easing", easings[(eidx + delta + easings.length) % easings.length])
      return
    }
    if (sel === 3) service.setSetting("settings.animations.reducedMotion", !a.reducedMotion)
  }

  function handleAppSizeKey(event) {
    if (overlay.handleAdjustKeys(event, 1, overlay.adjustAppSize, function() { service.resetAppGeometry(appSizeId) })) return
    var text = printable(event)
    if (text === "i") { event.accepted = true; service.resetAppGeometry(appSizeId); return }
  }

  function effectiveAppSize() {
    var own = service ? service.appGeometry(appSizeId) : null
    return {
      widthPercent: own && own.widthPercent !== undefined ? own.widthPercent : geometry.widthPercent,
      heightPercent: own && own.heightPercent !== undefined ? own.heightPercent : geometry.heightPercent
    }
  }

  function adjustAppSize(delta) {
    var current = effectiveAppSize()
    if (sel === 0) service.setAppGeometry(appSizeId, Model.clamp(current.widthPercent + delta * 5, 20, 100), current.heightPercent)
    else service.setAppGeometry(appSizeId, current.widthPercent, Model.clamp(current.heightPercent + delta * 5, 20, 100))
  }

  // ---- Layer surface -------------------------------------------------------

  // Full-screen, click-only layer on every output. It is declared before the
  // palette surface so the card stays above it. The main surface can be
  // input-transparent over the bare desktop on some compositors; this catcher
  // still dismisses the palette from anywhere, including another monitor.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      required property var modelData
      visible: overlay.opened || overlay.closing
      screen: modelData
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "apach-dropdown-catcher"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      anchors { top: true; bottom: true; left: true; right: true }
      mask: Region { item: catcher }

      MouseArea {
        id: catcher
        anchors.fill: parent
        onClicked: overlay.outsideClick()
      }
    }
  }

  PanelWindow {
    id: window
    visible: overlay.opened || overlay.closing
    screen: overlay.targetScreen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "apach-dropdown"
    WlrLayershell.layer: WlrLayer.Overlay
    // Keep the layer focused until the close animation has finished. Releasing
    // focus at opened=false made the previous window regain focus (border and
    // stacking change) while the semi-transparent palette was still fading,
    // which looked like the palette flickered.
    WlrLayershell.keyboardFocus: (overlay.opened || overlay.closing)
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    // Make the full transparent layer accept pointer input. Without an
    // explicit mask the empty desktop area can stay click-through, so an
    // outside click on the wallpaper would not dismiss the palette.
    mask: Region {
      Region { x: 0; y: 0; width: 10000; height: 10000 }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) { overlay.handleKey(event) }

      // A modal popover catches the click that dismisses it. The card sits on
      // top of this catcher, so only clicks outside reach it.
      MouseArea {
        anchors.fill: parent
        onClicked: overlay.outsideClick()
      }

      Rectangle {
        id: card
        width: Math.min(overlay.cardWidth, window.screen ? window.screen.width - Style.space(24) : overlay.cardWidth)
        height: content.implicitHeight + Style.space(44)
        x: Math.round((window.width - width) / 2) + overlay.animX
        y: Style.bar.sizeHorizontal + Style.space(6) + overlay.animY
        opacity: overlay.animOpacity
        radius: Style.cornerRadius
        color: Commons.Color.popups.background
        border.width: 1
        border.color: Commons.Color.popups.border
        transform: Scale {
          origin.x: card.width / 2
          origin.y: 0
          xScale: overlay.animScale
          yScale: overlay.animScale
        }

        // Swallow clicks on the card's empty surface so they do not fall
        // through to the dismissal catcher.
        MouseArea {
          anchors.fill: parent
          onClicked: {}
        }

        Column {
          id: content
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          spacing: Style.space(8)

          TabBar {
            visible: overlay.tabPosition === "top" && overlay.openTabs.length > 0
            width: parent.width
            apps: overlay.openTabs
            activeId: overlay.service ? overlay.service.currentAppId : ""
            motionEnabled: !overlay.reducedMotion
            onActivated: function(appId) { overlay.activateTab(appId) }
          }

          // ---- header ----
          Item {
            width: parent.width
            height: 28

            Text {
              textFormat: Text.PlainText
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(100)
              horizontalAlignment: Text.AlignHCenter
              text: overlay.viewTitle
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            CommandChip {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              key: "esc"
              label: (overlay.view === "palette" || overlay.view === "bar")
                ? strings.t("manage.buttonClose") : strings.t("manage.buttonBack")
              onTriggered: overlay.goBack()
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Qt.rgba(1, 1, 1, 0.08)
          }

          // ---- palette ----
          Column {
            visible: overlay.view === "palette"
            width: parent.width
            spacing: 8

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: overlay.service && overlay.service.currentApp
                ? (overlay.service.currentApp.state === "hidden"
                  ? strings.t("palette.currentHidden").arg(overlay.service.currentApp.name)
                  : strings.t("palette.currentVisible").arg(overlay.service.currentApp.name))
                : ""
              visible: text !== ""
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: overlay.popoutMode
                ? overlay.popoutPrompt()
                : (overlay.quitMode
                  ? overlay.quitPrompt()
                  : (overlay.service && overlay.service.enabledApps.length === 0
                    ? strings.t("palette.chooseApps")
                    : strings.t("palette.hint")))
              color: (overlay.quitMode || overlay.popoutMode) ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.3)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }

            SectionTitle {
              visible: overlay.service && overlay.service.enabledApps.length > 0
              title: strings.t("palette.mostUsed")
            }

            Row {
              id: topAppsRow
              visible: overlay.service && overlay.service.enabledApps.length > 0
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: 8
              readonly property int count: overlay.topApps.length
              readonly property real slotWidth: count > 0
                ? (parent.width - (count - 1) * spacing) / count : 0
              width: parent.width

              Repeater {
                model: overlay.topApps
                delegate: AppTile {
                  required property var modelData
                  required property int index
                  app: modelData
                  rank: index + 1
                  motionEnabled: !overlay.reducedMotion
                  width: topAppsRow.slotWidth
                  onActivated: overlay.activateApp(modelData)
                }
              }
            }

            AllAppsDrawer {
              id: allAppsDrawer
              apps: overlay.configuredApps
              open: overlay.allAppsOpen
              selected: overlay.drawerSel
              motionEnabled: !overlay.reducedMotion
              maxHeight: Math.max(110, Math.min(300, window.height * 0.28))
              onToggled: overlay.toggleAllApps()
              onActivated: function(app) { overlay.activateApp(app) }
            }

            // Running windows now live in the tab strip, so the base surface
            // stays to the five pinned applications plus the shortcut band.
            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              visible: text !== ""
              text: overlay.serviceNotice()
              color: localNotice !== ""
                ? (localNoticeUrgent ? Commons.Color.urgent : Commons.Color.accent)
                : Qt.darker(Commons.Color.popups.text, 1.35)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: overlay.view === "running" && overlay.rows.length > 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: overlay.localNoticeUrgent && overlay.localNotice !== ""
              ? overlay.localNotice
              : strings.t("palette.runningHint")
            color: overlay.localNoticeUrgent && overlay.localNotice !== ""
              ? Commons.Color.urgent
              : Qt.darker(Commons.Color.popups.text, 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ---- list / running / help ----
          ListView {
            id: simpleList
            visible: overlay.view === "running" || overlay.view === "help"
            width: parent.width
            height: overlay.view === "running"
              ? Math.min(430, Math.max(108, overlay.rows.length * 108))
              : Math.min(380, Math.max(42, overlay.rows.length * 42))
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: overlay.rows
            spacing: 2
            rightMargin: 10
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: 4 }
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Item {
              required property var modelData
              required property int index
              readonly property string reservedLabel: overlay.previewReservedLabel(modelData)
              width: simpleList.width
              height: modelData.kind === "header" ? 26 : (overlay.view === "running" ? 108 : 42)

              Text {
                textFormat: Text.PlainText
                visible: modelData.kind === "header"
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.kind === "header" ? overlay.rowLabel(modelData) : ""
                color: Qt.darker(Commons.Color.popups.text, 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Rectangle {
                id: previewCard
                visible: overlay.view === "running" && modelData.kind !== "header"
                anchors.fill: parent
                radius: 10
                property real shiftX: 0
                property real shiftY: 0
                readonly property bool depth: runHover.hovered && !overlay.reducedMotion
                z: runHover.hovered ? 2 : 0
                scale: depth ? 1.006 : 1
                Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                color: index === overlay.sel ? Qt.rgba(1, 1, 1, 0.12)
                  : (overlay.previewReservedFlash === modelData.id
                    ? Qt.rgba(0.85, 0.24, 0.24, 0.20)
                    : (runHover.hovered ? Qt.rgba(1, 1, 1, 0.06) : Qt.rgba(1, 1, 1, 0.03)))
                border.width: 1
                border.color: index === overlay.sel ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.08)

                Rectangle {
                  id: shotFrame
                  x: 8; y: 8
                  width: 150; height: 92
                  radius: 7
                  transform: Translate { x: previewCard.shiftX; y: previewCard.shiftY }
                  color: Qt.darker(Commons.Color.popups.background, 1.28)
                  border.width: 1
                  border.color: modelData.state === "error" ? Commons.Color.urgent : Qt.rgba(1, 1, 1, 0.08)

                  // Stylised window chrome: the preview is an overview card,
                  // not a screen capture, so it never exposes another window
                  // or stale compositor content.
                  Rectangle {
                    anchors.left: parent.left; anchors.leftMargin: 8; anchors.top: parent.top; anchors.topMargin: 7
                    width: 5; height: 5; radius: 3; color: Qt.rgba(1, 1, 1, 0.18)
                  }
                  Rectangle {
                    anchors.left: parent.left; anchors.leftMargin: 17; anchors.top: parent.top; anchors.topMargin: 7
                    width: 5; height: 5; radius: 3; color: Qt.rgba(1, 1, 1, 0.12)
                  }
                  Rectangle {
                    anchors.left: parent.left; anchors.leftMargin: 26; anchors.top: parent.top; anchors.topMargin: 7
                    width: 5; height: 5; radius: 3; color: Qt.rgba(1, 1, 1, 0.08)
                  }

                  Image {
                    anchors.centerIn: parent
                    width: 40; height: 40
                    source: modelData.icon ? Quickshell.iconPath(String(modelData.icon), true) : ""
                    fillMode: Image.PreserveAspectFit
                    opacity: 0.9
                  }
                }

                Column {
                  anchors.left: shotFrame.right
                  anchors.leftMargin: 14
                  anchors.right: stateChip.left
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 4

                  Row {
                    spacing: 8
                    KeyCap { label: modelData.key || "—"; active: true }
                    Text {
                      textFormat: Text.PlainText
                      visible: reservedLabel !== ""
                      anchors.verticalCenter: parent.verticalCenter
                      text: reservedLabel
                      color: Commons.Color.urgent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(modelData.name || modelData.id || "")
                      color: Commons.Color.popups.text
                      font.family: Style.font.family
                      font.pixelSize: Style.font.title
                      font.bold: true
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, 200)
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: overlay.windowTitle(modelData.id) || overlay.appSecondaryText(modelData)
                    color: Qt.darker(Commons.Color.popups.text, 1.35)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                Rectangle {
                  id: stateChip
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.top: parent.top
                  anchors.topMargin: 10
                  width: stateText.implicitWidth + 14
                  height: 20
                  radius: 6
                  color: Qt.rgba(1, 1, 1, 0.06)
                  border.width: 1
                  border.color: modelData.state === "error" ? Commons.Color.urgent : Qt.rgba(1, 1, 1, 0.10)
                  Text {
                    textFormat: Text.PlainText
                    id: stateText
                    anchors.centerIn: parent
                    text: strings.t(Model.stateKey(modelData.state), Model.stateLabel(modelData.state))
                    color: modelData.state === "error" ? Commons.Color.urgent : Qt.darker(Commons.Color.popups.text, 1.2)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                HoverHandler { id: runHover }
                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    overlay.sel = index
                    overlay.previewOpenApp(modelData)
                  }
                  onPositionChanged: {
                    if (overlay.reducedMotion) return
                    previewCard.shiftX = (mouseX / Math.max(1, width) - 0.5) * 6
                    previewCard.shiftY = (mouseY / Math.max(1, height) - 0.5) * 4
                  }
                  onExited: {
                    previewCard.shiftX = 0
                    previewCard.shiftY = 0
                  }
                }
              }

              Row {
                visible: modelData.kind === "row" && overlay.view === "help"
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10

                KeyCap {
                  anchors.verticalCenter: parent.verticalCenter
                  label: modelData.key || ""
                  visible: (modelData.key || "") !== ""
                  active: index === overlay.sel
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width - 50
                  anchors.verticalCenter: parent.verticalCenter
                  text: overlay.rowLabel(modelData)
                  color: Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
              height: contentHeight + 4
                  elide: Text.ElideRight
                  maximumLineCount: 2
                }
              }

              Rectangle {
                visible: index === overlay.sel && overlay.view === "help"
                anchors.fill: parent
                radius: 8
                color: Qt.rgba(1, 1, 1, 0.06)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: overlay.view === "running" && overlay.rows.length === 0
            width: parent.width
            text: strings.t("palette.runningEmpty")
            color: Qt.darker(Commons.Color.popups.text, 1.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          // ---- bar placement ----
          Column {
            visible: overlay.view === "bar"
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("bar.help")
              color: Qt.darker(Commons.Color.popups.text, 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }

            SettingRow {
              label: strings.t("bar.section")
              value: overlay.pendingBarSection === ""
                ? strings.t("bar.notOnBar")
                : overlay.enumLabel("barSection", overlay.pendingBarSection)
              selected: overlay.sel === 0
              onAdjust: function(delta) { overlay.sel = 0; overlay.cycleBarSection(delta) }
              onActivate: { overlay.sel = 0; overlay.cycleBarSection(1) }
            }
            SettingRow {
              label: strings.t("bar.positionInSection")
              value: overlay.pendingBarSection === ""
                ? "—"
                : strings.t("bar.positionValue")
                  .arg(overlay.number(overlay.pendingBarIndex + 1))
                  .arg(overlay.number(overlay.pendingBarTotal(overlay.pendingBarSection)))
              selected: overlay.sel === 1
              disabled: overlay.pendingBarSection === ""
              onAdjust: function(delta) { overlay.sel = 1; overlay.stepBarIndex(delta) }
              onActivate: { overlay.sel = 1; overlay.stepBarIndex(1) }
            }

            Row {
              width: parent.width
              spacing: 8

              Repeater {
                model: ["left", "center", "right"]
                delegate: Rectangle {
                  id: barCard
                  required property string modelData
                  property bool hovered: false
                  readonly property int items: Number(overlay.barSizes[modelData] || 0)
                  readonly property bool active: overlay.pendingBarSection === modelData
                  width: (parent.width - 16) / 3
                  height: 46
                  radius: 8
                  color: active ? Qt.rgba(1, 1, 1, 0.12)
                    : (barCard.hovered ? Qt.rgba(1, 1, 1, 0.07) : Qt.rgba(1, 1, 1, 0.035))
                  border.width: 1
                  border.color: active ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.08)

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: strings.t("bar.card")
                      .arg(overlay.enumLabel("barSection", modelData))
                      .arg(strings.tn("bar.items", barCard.items).arg(overlay.number(barCard.items)))
                    horizontalAlignment: Text.AlignHCenter
                    color: active ? Commons.Color.accent : Qt.darker(Commons.Color.popups.text, 1.3)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }

                  HoverHandler {
                    onHoveredChanged: card.hovered = hovered
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { overlay.sel = 0; overlay.setBarSection(modelData) }
                  }
                }
              }
            }
          }

          // ---- shortcuts ----
          Column {
            visible: overlay.view === "keys"
            width: parent.width
            spacing: Style.space(4)

            SectionTitle { title: strings.t("keys.paletteCommands") }

            Repeater {
              model: overlay.view === "keys" ? overlay.rows : []
              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: 38

                Rectangle {
                  anchors.fill: parent
                  radius: 8
                  color: index === overlay.sel ? Qt.rgba(1, 1, 1, 0.12) : "transparent"
                }
                Text {
                  textFormat: Text.PlainText
                  anchors.left: parent.left
                  anchors.leftMargin: 10
                  anchors.right: keyCap.left
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  text: overlay.rowLabel(modelData)
                  color: modelData.fixed ? Qt.darker(Commons.Color.popups.text, 1.7) : Commons.Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                KeyCap {
                  id: keyCap
                  anchors.right: parent.right
                  anchors.rightMargin: 12
                  anchors.verticalCenter: parent.verticalCenter
                  label: modelData.key || "—"
                  active: index === overlay.sel
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: modelData.fixed ? Qt.ArrowCursor : Qt.PointingHandCursor
                  onClicked: {
                    overlay.sel = index
                    if (modelData.fixed) {
                      overlay.say(strings.t("notice.reduceFixed"))
                      return
                    }
                    overlay.assigningCommand = modelData.command
                    overlay.say(strings.t("notice.pressKeyFor").arg(overlay.rowLabel(modelData)))
                    overlay.focusKeys()
                  }
                }
              }
            }


            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("keys.openHelp")
              color: Qt.darker(Commons.Color.popups.text, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }
          }

          // ---- manage ----
          Column {
            visible: overlay.view === "manage"
            width: parent.width
            spacing: 6

            Rectangle {
              width: parent.width
              height: 32
              radius: 8
              color: Qt.rgba(1, 1, 1, 0.05)
              border.width: 1
              border.color: overlay.searchFocused ? Commons.Color.accent : Qt.rgba(1, 1, 1, 0.10)

              TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                verticalAlignment: TextInput.AlignVCenter
                text: overlay.search
                focus: overlay.view === "manage" && overlay.searchFocused
                color: Commons.Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                clip: true
                // Defense in depth: no unbounded paste can be inserted even if
                // a path below is bypassed.
                maximumLength: Bounds.LIMITS.searchChars
                onTextChanged: if (text !== overlay.search) overlay.search = text
                onActiveFocusChanged: {
                  if (activeFocus) overlay.searchFocused = true
                  else overlay.cancelPaste()
                }

                // Intercept every keyboard paste gesture before QQuickTextInput
                // runs its native, unbounded paste. BeforeItem is explicit so a
                // future default change cannot silently restore native paste.
                Keys.priority: Keys.BeforeItem
                Keys.onPressed: function(event) {
                  var pasteGesture = event.matches(StandardKey.Paste) ||
                    (event.key === Qt.Key_V && (event.modifiers & Qt.ControlModifier)) ||
                    (event.key === Qt.Key_Insert && (event.modifiers & Qt.ShiftModifier))
                  if (!pasteGesture) return
                  event.accepted = true
                  overlay.pasteFromClipboard(false)
                }
              }

              // PRIMARY selection pastes on middle click inside
              // QQuickTextInput::mouseReleaseEvent and cannot be intercepted
              // with Keys. This area accepts only the middle button; left
              // clicks pass through to the TextInput for placement and cursor
              // movement.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton
                onPressed: function(mouse) {
                  mouse.accepted = true
                  overlay.searchFocused = true
                  searchInput.forceActiveFocus()
                  overlay.pasteFromClipboard(true)
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: overlay.search === ""
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t("manage.filter")
                color: Qt.darker(Commons.Color.popups.text, 1.5)
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            ListView {
              id: manageList
              width: parent.width
              height: Math.min(430, Math.max(42, overlay.rows.length * 42))
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: overlay.rows
              spacing: 2
              rightMargin: 10
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOn; width: 4 }
              onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: Item {
                required property var modelData
                required property int index
                width: manageList.width
                height: modelData.kind === "header" ? 28 : 42

                SectionTitle {
                  visible: modelData.kind === "header"
                  anchors.fill: parent
                  title: modelData.kind === "header" ? overlay.rowLabel(modelData) : ""
                }

                AppRow {
                  visible: modelData.kind !== "header"
                  anchors.fill: parent
                  app: modelData
                  selected: index === overlay.sel && !overlay.searchFocused
                  showCheckbox: true
                  onActivated: {
                    overlay.sel = index
                    overlay.toggleManaged(modelData)
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: overlay.view === "manage" && overlay.rows.length === 0
              width: parent.width
              text: strings.t("manage.noMatch")
              color: Qt.darker(Commons.Color.popups.text, 1.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: text !== ""
              text: overlay.serviceNotice()
              color: overlay.localNotice !== "" ? Commons.Color.accent : Commons.Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: overlay.assigning
              text: overlay.assigning
                ? strings.t("notice.pressKeyFor")
                  .arg(overlay.service.findApp(overlay.assignAppId) ? overlay.service.findApp(overlay.assignAppId).name : "")
                : ""
              color: Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: overlay.assigningShortcut
              text: !overlay.assigningShortcut ? ""
                : overlay.shortcutChecking
                  ? strings.t("notice.checkingBinds")
                  : overlay.shortcutError !== ""
                    ? strings.t("notice.shortcutErrorSuffix").arg(overlay.shortcutError)
                    : (overlay.shortcutSuggestion
                      ? strings.t("notice.shortcutPromptSuggestion")
                        .arg(overlay.service.findApp(overlay.shortcutAppId) ? overlay.service.findApp(overlay.shortcutAppId).name : "")
                        .arg(overlay.shortcutSuggestion)
                      : strings.t("notice.shortcutPrompt")
                        .arg(overlay.service.findApp(overlay.shortcutAppId) ? overlay.service.findApp(overlay.shortcutAppId).name : ""))
              color: overlay.shortcutError !== "" ? Commons.Color.urgent : Commons.Color.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }

          }

          // ---- sizes ----
          Column {
            visible: overlay.view === "sizes"
            width: parent.width
            spacing: Style.space(4)

            GeometryPreview {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              monitorAspect: overlay.previewAspect
              widthPercent: overlay.geometry.widthPercent
              heightPercent: overlay.geometry.heightPercent
              topOffset: overlay.geometry.topOffset
              reservedTop: overlay.previewReservedTop
              placement: String(overlay.geometry.placement || "center")
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("settings.positionSummary")
                .arg(overlay.enumLabel("placement", overlay.geometry.placement || "center"))
                .arg(overlay.enumLabel("edge", overlay.edge))
              color: Qt.darker(Commons.Color.popups.text, 1.45)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            SectionTitle { title: strings.t("settings.display") }

            SettingRow {
              label: strings.t("settings.screen")
              value: overlay.screenLabel(overlay.service ? overlay.service.config.settings.screen : "auto")
              selected: overlay.sel === 0
              onAdjust: function(delta) { overlay.sel = 0; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 0; overlay.adjustSize(1) }
            }

            SectionTitle { title: strings.t("settings.placement") }

            SettingRow {
              label: strings.t("settings.preset")
              value: overlay.enumLabel("preset", overlay.geometry.preset || "custom")
              selected: overlay.sel === 1
              onAdjust: function(delta) { overlay.sel = 1; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 1; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.position")
              value: overlay.enumLabel("placement", overlay.geometry.placement || "center")
              selected: overlay.sel === 2
              onAdjust: function(delta) { overlay.sel = 2; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 2; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.slideFrom")
              value: overlay.enumLabel("edge", overlay.edge)
              selected: overlay.sel === 3
              onAdjust: function(delta) { overlay.sel = 3; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 3; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.width")
              value: strings.t("value.percent").arg(overlay.number(Math.round(overlay.geometry.widthPercent)))
              selected: overlay.sel === 4
              onAdjust: function(delta) { overlay.sel = 4; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 4; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.height")
              value: strings.t("value.percent").arg(overlay.number(Math.round(overlay.geometry.heightPercent)))
              selected: overlay.sel === 5
              onAdjust: function(delta) { overlay.sel = 5; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 5; overlay.adjustSize(1) }
            }

            SectionTitle { title: strings.t("settings.offsets") }

            SettingRow {
              label: strings.t("settings.topOffset")
              value: strings.t("value.px").arg(overlay.number(Math.round(overlay.geometry.topOffset)))
              selected: overlay.sel === 6
              onAdjust: function(delta) { overlay.sel = 6; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 6; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.sideMargin")
              value: strings.t("value.px").arg(overlay.number(Math.round(overlay.geometry.sideMargin)))
              selected: overlay.sel === 7
              onAdjust: function(delta) { overlay.sel = 7; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 7; overlay.adjustSize(1) }
            }

            SectionTitle { title: strings.t("settings.tabs") }

            SettingRow {
              label: strings.t("settings.tabBar")
              value: overlay.enumLabel("tabPosition", overlay.tabPosition)
              selected: overlay.sel === 8
              onAdjust: function(delta) { overlay.sel = 8; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 8; overlay.adjustSize(1) }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("settings.tabsHint")
              color: Qt.darker(Commons.Color.popups.text, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }


            SectionTitle { title: strings.t("settings.behaviour") }

            SettingRow {
              label: strings.t("settings.hideOnFocusLoss")
              value: overlay.service && overlay.service.config.settings.autoHideOnFocusLoss ? strings.t("settings.on") : strings.t("settings.off")
              selected: overlay.sel === 9
              onAdjust: function(delta) { overlay.sel = 9; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 9; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.hideAfterFocusLoss")
              value: strings.t("value.seconds").arg(overlay.number(Math.round(Number(overlay.service ? overlay.service.config.settings.autoHideDelayMs : 5000) / 1000)))
              selected: overlay.sel === 10
              onAdjust: function(delta) { overlay.sel = 10; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 10; overlay.adjustSize(1) }
            }
            SettingRow {
              label: strings.t("settings.topCards")
              value: overlay.number(overlay.service ? overlay.service.config.settings.topApps : 5)
              selected: overlay.sel === 11
              onAdjust: function(delta) { overlay.sel = 11; overlay.adjustSize(delta) }
              onActivate: { overlay.sel = 11; overlay.adjustSize(1) }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("settings.monitorHint")
              color: Qt.darker(Commons.Color.popups.text, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }
          }

          // ---- animations ----
          Column {
            visible: overlay.view === "anim"
            width: parent.width
            spacing: Style.space(4)

            SectionTitle { title: strings.t("settings.palette") }

            SettingRow {
              label: strings.t("settings.paletteInOut")
              value: overlay.animationLabel(overlay.animations.mode)
              selected: overlay.sel === 0
              onAdjust: function(delta) { overlay.sel = 0; overlay.adjustAnim(delta) }
              onActivate: { overlay.sel = 0; overlay.adjustAnim(1) }
            }
            SettingRow {
              label: strings.t("settings.duration")
              value: strings.t("value.ms").arg(overlay.number(Math.round(overlay.animations.durationMs)))
              selected: overlay.sel === 1
              onAdjust: function(delta) { overlay.sel = 1; overlay.adjustAnim(delta) }
              onActivate: { overlay.sel = 1; overlay.adjustAnim(1) }
            }
            SettingRow {
              label: strings.t("settings.easing")
              value: overlay.enumLabel("easing", overlay.animations.easing || "outCubic")
              selected: overlay.sel === 2
              onAdjust: function(delta) { overlay.sel = 2; overlay.adjustAnim(delta) }
              onActivate: { overlay.sel = 2; overlay.adjustAnim(1) }
            }
            SettingRow {
              label: strings.t("settings.reducedMotion")
              value: overlay.animations.reducedMotion ? strings.t("settings.on") : strings.t("settings.off")
              selected: overlay.sel === 3
              onAdjust: function(delta) { overlay.sel = 3; overlay.adjustAnim(delta) }
              onActivate: { overlay.sel = 3; overlay.adjustAnim(1) }
            }


            Text {
              textFormat: Text.PlainText
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: strings.t("settings.animationHint")
              color: Qt.darker(Commons.Color.popups.text, 1.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              height: contentHeight + 4
            }
          }

          // ---- per-app size ----
          Column {
            visible: overlay.view === "appsize"
            width: parent.width
            spacing: 4

            GeometryPreview {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              monitorAspect: overlay.previewAspect
              widthPercent: overlay.effectiveAppSize().widthPercent
              heightPercent: overlay.effectiveAppSize().heightPercent
              topOffset: overlay.geometry.topOffset
              reservedTop: overlay.previewReservedTop
              placement: String(overlay.geometry.placement || "center")
            }

            SectionTitle { title: strings.t("settings.applicationSize") }

            SettingRow {
              label: strings.t("settings.width")
              value: strings.t("value.percent").arg(overlay.number(Math.round(overlay.effectiveAppSize().widthPercent)))
              selected: overlay.sel === 0
              onAdjust: function(delta) { overlay.sel = 0; overlay.adjustAppSize(delta) }
              onActivate: { overlay.sel = 0; overlay.adjustAppSize(1) }
            }
            SettingRow {
              label: strings.t("settings.height")
              value: strings.t("value.percent").arg(overlay.number(Math.round(overlay.effectiveAppSize().heightPercent)))
              selected: overlay.sel === 1
              onAdjust: function(delta) { overlay.sel = 1; overlay.adjustAppSize(delta) }
              onActivate: { overlay.sel = 1; overlay.adjustAppSize(1) }
            }

          }

          TabBar {
            visible: overlay.tabPosition === "bottom" && overlay.openTabs.length > 0
            width: parent.width
            apps: overlay.openTabs
            activeId: overlay.service ? overlay.service.currentAppId : ""
            motionEnabled: !overlay.reducedMotion
            onActivated: function(appId) { overlay.activateTab(appId) }
          }

          ShortcutBand {
            width: parent.width
            items: overlay.bandItems()
          }
        }
      }
    }
  }
}
