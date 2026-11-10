// Pure managed-window state derivation. Service.qml feeds it the live maps and
// renders the result; the tests exercise every transition without Hyprland.

// states: error | launching | stopped | hidden | visible
function appState(entry, hasWindow, error, launching, closing) {
  if (error) return "error"
  if (launching) return "launching"
  if (!entry) return "stopped"
  if (!hasWindow) return "stopped"
  if (closing) return "closing"
  return entry.hidden === true ? "hidden" : "visible"
}

// The secondary line in Manage, the drawer card and the preview list.
function stateNote(app, entry, window, error) {
  var source = app || {}
  if (source.available === false) return "Not configured"
  if (error) return String(error)
  var startup = source.launchAtLogin ? " · starts at login" : ""
  if (!entry) return startup ? String(startup).slice(3) : ""
  if (entry.hidden) return "Parked on " + String(entry.special || "") + startup
  if (!window) return "Window closed"
  return (window.workspace !== undefined ? "On workspace " + window.workspace : "") + startup
}

// Catalog form of stateNote: a key plus the data to interpolate, or null when
// there is nothing to show. Whole strings carry the "starts at login" suffix so
// the UI never glues translated fragments together.
function stateNoteKey(app, entry, window, error) {
  var source = app || {}
  if (source.available === false) return { key: "note.notConfigured", args: [] }
  if (error) return { key: "note.error", args: [String(error)] }
  if (!entry) return source.launchAtLogin ? { key: "note.startsAtLogin", args: [] } : null
  if (entry.hidden) {
    return {
      key: source.launchAtLogin ? "note.parkedLogin" : "note.parked",
      args: [String(entry.special || "")]
    }
  }
  if (!window) return { key: "note.windowClosed", args: [] }
  if (window.workspace !== undefined) {
    return {
      key: source.launchAtLogin ? "note.workspaceLogin" : "note.workspace",
      args: [String(window.workspace)]
    }
  }
  return source.launchAtLogin ? { key: "note.startsAtLogin", args: [] } : null
}


// Pure focus-loss decision. Returns "" when the visible window still owns
// focus, otherwise "workspace" (user switched to another workspace) or
// "focus" (another window or the desktop has focus).
//
// The active-window checks must come first: Hyprland updates the focused
// monitor/workspace when the pointer crosses to another output even with
// follow_mouse disabled, while `activeToplevel` still points at the managed
// window. That is a pointer move, not a focus loss, so it must not hide it.
function autoHideReason(input) {
  var value = input || {}
  if (value.enabled !== true) return ""
  if (!value.entry) return ""
  if (value.paletteOpen) return ""
  if (!value.activeAddress) return "focus"
  if (value.activeAddress === value.entryAddress) return ""
  if (value.activeIsSibling) return ""
  if (value.focusedName && value.windowWs && value.focusedName !== value.windowWs) return "workspace"
  return "focus"
}

if (typeof module !== "undefined") {
  module.exports = {
    appState: appState,
    stateNote: stateNote,
    stateNoteKey: stateNoteKey,
    autoHideReason: autoHideReason
  }
}
